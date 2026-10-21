import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart' as svg;
import 'package:photo_manager/photo_manager.dart';

import '../models/chat_annotation.dart';
import '../models/home_chat_attachment.dart';
import '../pages/drawing_board_page.dart';
import '../services/home_chat_drawing_draft_store.dart';
import 'app_toast.dart';
import 'chat_annotation_controls.dart';

class ChatImageSource {
  const ChatImageSource({
    required this.id,
    required this.name,
    required this.loadOriginal,
    this.loadImage,
    this.attachment,
    this.pending = false,
  });
  final String id;
  final String name;
  final Future<Uint8List> Function() loadOriginal;
  final Future<Uint8List> Function()? loadImage;
  final HomeChatAttachment? attachment;
  final bool pending;

  factory ChatImageSource.fromAttachment(
    HomeChatAttachment a, {
    bool pending = false,
  }) => ChatImageSource(
    id: a.id,
    name: a.originalImageName ?? a.name,
    attachment: a,
    pending: pending,
    loadOriginal: () => File(a.originalImagePath ?? a.path).readAsBytes(),
    loadImage: () => File(a.annotationImagePath ?? a.path).readAsBytes(),
  );
}

class ChatImageEdit {
  const ChatImageEdit({
    required this.source,
    required this.originalBytes,
    required this.imageBytes,
    required this.annotations,
    this.drawingDraftPath,
  });
  final ChatImageSource source;
  final Uint8List originalBytes;
  final Uint8List imageBytes;
  final List<ChatAnnotation> annotations;
  final String? drawingDraftPath;
}

/// Export only content and numbered anchors, never viewer controls or editors.
Future<Uint8List> renderChatAnnotatedImage(
  Uint8List bytes,
  List<ChatAnnotation> annotations,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  ui.Picture? picture;
  ui.Image? result;
  svg.PictureInfo? pin;
  try {
    final scale = math.min(1.0, 2048 / math.max(image.width, image.height));
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint(),
    );
    if (annotations.isNotEmpty) {
      pin = await svg.vg.loadPicture(
        const svg.SvgAssetLoader('assets/icons/chat_annotations/pin.svg'),
        null,
      );
      final pinWidth = math
          .min(
            width.toDouble(),
            math.min(height * 40 / 54, (width / 20).clamp(26.0, 56.0)),
          )
          .toDouble();
      final pinHeight = pinWidth * 54 / 40;
      for (var i = 0; i < annotations.length; i++) {
        final a = annotations[i];
        final left = (a.x * width - pinWidth / 2).clamp(0.0, width - pinWidth);
        final top = (a.y * height - pinHeight + pinWidth / 10)
            .clamp(0.0, math.max(0.0, height - pinHeight))
            .toDouble();
        canvas.save();
        canvas.translate(left, top);
        canvas.scale(pinWidth / 40);
        canvas.drawPicture(pin.picture);
        canvas.restore();
        final text = TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: TextStyle(
              color: Colors.white,
              fontSize: pinWidth * .42,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          Offset(left + (pinWidth - text.width) / 2, top + pinWidth * .19),
        );
        text.dispose();
      }
    }
    picture = recorder.endRecording();
    result = await picture.toImage(width, height);
    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const FormatException('图片导出失败');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    result?.dispose();
    picture?.dispose();
    pin?.picture.dispose();
  }
}

class ChatImageGallery extends StatefulWidget {
  const ChatImageGallery({
    required this.images,
    required this.initialIndex,
    required this.conversationId,
    required this.accountScope,
    required this.onComplete,
    super.key,
  });
  final List<ChatImageSource> images;
  final int initialIndex;
  final String conversationId;
  final String accountScope;
  final Future<void> Function(List<ChatImageEdit>) onComplete;
  @override
  State<ChatImageGallery> createState() => _ChatImageGalleryState();
}

class _ImageEditState {
  _ImageEditState(
    this.original,
    this.image,
    this.size,
    this.annotations,
    this.draftPath,
  ) : baseline = jsonEncode(annotations.map((a) => a.toJson()).toList());
  final Uint8List original;
  Uint8List image;
  Size size;
  List<ChatAnnotation> annotations;
  String? draftPath;
  final String baseline;
  bool drawn = false;
  int drawingRevision = 0;
  bool get changed =>
      drawn ||
      baseline != jsonEncode(annotations.map((a) => a.toJson()).toList());
}

class _ChatImageGalleryState extends State<ChatImageGallery> {
  late int _index;
  late final PageController _pages;
  late final HomeChatDrawingDraftStore _store;
  final _states = <String, _ImageEditState>{};
  final _errors = <String, Object>{};
  final _loading = <String>{};
  final _preparingDrawings = <String>{};
  final _drawingPreparationErrors = <String, Object>{};
  final _drawingSnapshots = <String, Future<void>>{};
  final _drawingSnapshotsAgain = <String>{};
  final _failedDrawingSnapshots = <String>{};
  final _transforms = <String, TransformationController>{};
  final _scratchPaths = <String>{};
  final _keptPaths = <String>{};
  final _comment = TextEditingController();
  String? _activeComment;
  Offset? _newPoint;
  bool _commentMode = false;
  bool _saving = false;
  bool _drawing = false;
  final _drawingController = DrawingSurfaceController();
  bool _downloading = false;
  bool _zoomed = false;
  bool _closing = false;

  ChatImageSource get _source => widget.images[_index];
  _ImageEditState? get _current => _states[_source.id];
  bool get _hasChanges {
    final active = _current?.annotations
        .where((a) => a.id == _activeComment)
        .firstOrNull;
    final typing = _newPoint != null
        ? _comment.text.trim().isNotEmpty
        : active != null && _comment.text.trim() != active.comment;
    return _drawingController.hasChanges ||
        _states.values.any((v) => v.changed) ||
        typing;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
    _store = HomeChatDrawingDraftStore(accountScope: widget.accountScope);
    _comment.addListener(_commentChanged);
    unawaited(_load(_source));
  }

  void _commentChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pages.dispose();
    _comment.removeListener(_commentChanged);
    _comment.dispose();
    for (final controller in _transforms.values) {
      controller.dispose();
    }
    for (final path in _scratchPaths.difference(_keptPaths)) {
      unawaited(
        _store.delete(widget.conversationId, path).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  Future<void> _load(ChatImageSource source) async {
    final existing = _states[source.id];
    if (existing != null) {
      _prepareDrawing(source, existing);
      return;
    }
    if (!_loading.add(source.id)) return;
    try {
      final original = await source.loadOriginal();
      final image = source.loadImage == null
          ? original
          : await source.loadImage!();
      final codec = await ui.instantiateImageCodec(image);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      if (!mounted) return;
      final state = _ImageEditState(
        original,
        image,
        size,
        List<ChatAnnotation>.of(
          source.attachment?.imageAnnotations ?? const [],
        ),
        source.attachment?.drawingDraftPath,
      );
      _states[source.id] = state;
      _errors.remove(source.id);
      _prepareDrawing(source, state);
    } catch (error) {
      if (mounted) _errors[source.id] = error;
    } finally {
      _loading.remove(source.id);
      if (mounted) setState(() {});
    }
  }

  void _prepareDrawing(ChatImageSource source, _ImageEditState state) {
    final sourcePath = state.draftPath;
    if (sourcePath != null && _scratchPaths.contains(sourcePath)) return;
    if (!_preparingDrawings.add(source.id)) return;
    unawaited(() async {
      try {
        final draft = await _store.fork(
          widget.conversationId,
          sourcePath: sourcePath,
          backgroundBytes: state.image,
        );
        if (!mounted || !identical(_states[source.id], state)) {
          await _store.delete(widget.conversationId, draft.path);
          return;
        }
        state.draftPath = draft.path;
        _scratchPaths.add(draft.path);
        _drawingPreparationErrors.remove(source.id);
        setState(() {});
      } catch (error) {
        _drawingPreparationErrors[source.id] = error;
        if (mounted && _source.id == source.id && _drawing) {
          setState(() {
            _drawing = false;
            _commentMode = false;
          });
          AppToast.show(context, '打开标注失败，请重试');
        }
      } finally {
        _preparingDrawings.remove(source.id);
      }
    }());
  }

  void _commitComment() {
    final state = _current;
    if (state == null) return;
    final text = _comment.text.trim();
    if (_activeComment != null) {
      if (text.isNotEmpty) {
        state.annotations = state.annotations
            .map((a) => a.id == _activeComment ? a.copyWith(comment: text) : a)
            .toList();
      }
    } else if (_newPoint != null && text.isNotEmpty) {
      state.annotations = [
        ...state.annotations,
        ChatAnnotation(
          id: 'image_comment_${DateTime.now().microsecondsSinceEpoch}',
          attachmentId: _source.id,
          comment: text,
          x: _newPoint!.dx,
          y: _newPoint!.dy,
        ),
      ];
    }
    _activeComment = null;
    _newPoint = null;
    _comment.clear();
  }

  void _exitEmptyCommentMode() {
    if (!_commentMode || _comment.text.trim().isNotEmpty) return;
    _commitComment();
    FocusScope.of(context).unfocus();
    if (mounted) setState(() => _commentMode = false);
  }

  void _draw() {
    final state = _current;
    if (state == null || _drawing || _saving) return;
    if (_drawingPreparationErrors.containsKey(_source.id)) {
      _drawingPreparationErrors.remove(_source.id);
      _prepareDrawing(_source, state);
      AppToast.show(context, '打开标注失败，正在重试');
      return;
    }
    _commitComment();
    FocusScope.of(context).unfocus();
    _failedDrawingSnapshots.remove(_source.id);
    setState(() {
      state.drawingRevision++;
      _drawing = true;
      _commentMode = false;
    });
  }

  void _toggleCommentMode() {
    final state = _current;
    if (state == null || _saving) return;
    if (_commentMode) {
      _commitComment();
      setState(() => _commentMode = false);
      return;
    }
    final wasDrawing = _drawing;
    if (wasDrawing) _drawingController.suspendTools();
    _commitComment();
    setState(() {
      _drawing = false;
      _commentMode = true;
    });
    if (wasDrawing) _scheduleDrawingSnapshot(_source, state);
  }

  void _scheduleDrawingSnapshot(ChatImageSource source, _ImageEditState state) {
    if (!_drawingController.hasChanges) return;
    if (_drawingSnapshots.containsKey(source.id)) {
      _drawingSnapshotsAgain.add(source.id);
      return;
    }
    final revision = state.drawingRevision;
    final pending = _captureDrawingSnapshot(source, state, revision);
    _drawingSnapshots[source.id] = pending;
    unawaited(
      pending.whenComplete(() {
        if (!identical(_drawingSnapshots[source.id], pending)) return;
        _drawingSnapshots.remove(source.id);
        final repeat = _drawingSnapshotsAgain.remove(source.id);
        if (!mounted) return;
        setState(() {});
        if (repeat && !_drawing && _source.id == source.id) {
          _scheduleDrawingSnapshot(source, state);
        }
      }),
    );
  }

  Future<void> _captureDrawingSnapshot(
    ChatImageSource source,
    _ImageEditState state,
    int revision,
  ) async {
    try {
      final image = await _drawingController.snapshot();
      if (image == null) throw const FormatException('图片预览更新失败');
      if (!mounted || state.drawingRevision != revision) return;
      state.image = image;
      state.drawn = true;
      _failedDrawingSnapshots.remove(source.id);
    } catch (_) {
      if (!mounted || state.drawingRevision != revision) return;
      _failedDrawingSnapshots.add(source.id);
      AppToast.show(context, '标注仍保留，请切回标注模式后重试');
    }
  }

  Future<bool> _finishDrawing() async {
    if (!_drawingController.hasChanges) return true;
    final changed = _drawingController.hasChanges;
    final result = await _drawingController.export();
    if (result == null || !mounted) return false;
    final state = _current!;
    state.image = result.pngBytes;
    state.draftPath = result.draftPath;
    state.drawn = state.drawn || changed;
    final codec = await ui.instantiateImageCodec(result.pngBytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    state.size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    if (mounted) setState(() => _drawing = false);
    return mounted;
  }

  Future<void> _finish() async {
    if (_saving) return;
    _commitComment();
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _commentMode = false;
    });
    while (_drawingSnapshots.isNotEmpty) {
      await Future.wait(_drawingSnapshots.values.toList());
    }
    if (!await _finishDrawing() || !mounted) {
      if (mounted) {
        setState(() {
          _saving = false;
          _drawing = true;
          _commentMode = false;
        });
      }
      return;
    }
    _commitComment();
    FocusScope.of(context).unfocus();
    final edits = <ChatImageEdit>[
      for (final source in widget.images)
        if (_states[source.id] case final state? when state.changed)
          ChatImageEdit(
            source: source,
            originalBytes: state.original,
            imageBytes: state.image,
            annotations: List.of(state.annotations),
            drawingDraftPath: state.draftPath,
          ),
    ];
    if (edits.isEmpty) {
      Navigator.pop(context);
      if (mounted) setState(() => _saving = false);
      return;
    }
    try {
      await widget.onComplete(edits);
      for (final edit in edits) {
        if (edit.drawingDraftPath case final path?
            when _scratchPaths.contains(path)) {
          _keptPaths.add(path);
          try {
            await _store.finish(widget.conversationId, path);
          } catch (_) {
            /* The saved scene remains readable. */
          }
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          error is StateError ? error.message.toString() : '保存失败，编辑内容已保留，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving || _closing) return;
    _closing = true;
    try {
      final discard =
          !_hasChanges ||
          await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('放弃更改？'),
                  content: const Text('尚未完成的标注和评论将不会加入输入框。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('继续编辑'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('放弃更改'),
                    ),
                  ],
                ),
              ) ==
              true;
      if (discard && mounted) Navigator.pop(context);
    } finally {
      _closing = false;
    }
  }

  Future<void> _download() async {
    if (_current == null || _downloading) return;
    final source = _source;
    final original = _current!.original;
    setState(() => _downloading = true);
    try {
      const permissionRequest = PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.addOnly,
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      );
      var permission = await PhotoManager.getPermissionState(
        requestOption: permissionRequest,
      );
      if (!permission.hasAccess) {
        permission = await PhotoManager.requestPermissionExtend(
          requestOption: permissionRequest,
        );
      }
      if (!permission.hasAccess) {
        if (mounted) AppToast.show(context, '请在系统设置中允许小七保存图片到相册');
        return;
      }

      final name = source.name.replaceAll(
        RegExp(r'[\\/:*?"<>|\u0000-\u001F]'),
        '_',
      );
      final filename = name.trim().isEmpty
          ? 'xiaoqi-image-${DateTime.now().millisecondsSinceEpoch}'
          : name;
      await PhotoManager.editor.saveImage(
        original,
        filename: filename,
        title: filename,
        relativePath: Platform.isAndroid ? 'Pictures/Xiaoqi' : null,
      );
      if (mounted) AppToast.show(context, '原图已保存到相册');
    } catch (_) {
      if (mounted) AppToast.show(context, '原图保存失败，请重试');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.fold<int>(
      0,
      (n, s) =>
          n +
          (_states[s.id]?.annotations.length ??
              s.attachment?.imageAnnotations.length ??
              0),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0F),
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _exitEmptyCommentMode,
          child: SafeArea(
            maintainBottomViewPadding: true,
            child: Column(
              children: [
                if (widget.images.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${_index + 1} / ${widget.images.length}',
                      style: const TextStyle(
                        color: Color(0xFF969696),
                        fontSize: 14,
                      ),
                    ),
                  ),
                SizedBox(
                  height: 68,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
                    opacity: _commentMode ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_commentMode,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Container(
                            padding: const EdgeInsets.only(left: 18, right: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF303032),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: const Color(0xFF48484A),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    total == 0 ? '点击图片以添加注释点位' : '$total 条注释',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: _saving ? null : _finish,
                                  style: TextButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: const Color(0xFF252525),
                                    minimumSize: const Size(64, 40),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: Text(_saving ? '保存中…' : '完成'),
                                ),
                                IconButton(
                                  tooltip: '关闭预览',
                                  onPressed: _saving ? null : _close,
                                  icon: svg.SvgPicture.asset(
                                    'assets/icons/chat_note_editor/x.svg',
                                    width: 22,
                                    height: 22,
                                    colorFilter: const ColorFilter.mode(
                                      Colors.white,
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: widget.images.length,
                    physics:
                        _zoomed ||
                            _saving ||
                            _drawing ||
                            _drawingSnapshots.containsKey(_source.id) ||
                            _failedDrawingSnapshots.contains(_source.id)
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    onPageChanged: (index) {
                      _commitComment();
                      FocusScope.of(context).unfocus();
                      setState(() {
                        _index = index;
                        _zoomed = false;
                      });
                      unawaited(_load(_source));
                    },
                    itemBuilder: (context, index) =>
                        _imagePage(widget.images[index]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF28282A),
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: _saving || _current == null ? null : _draw,
                          style: TextButton.styleFrom(
                            foregroundColor: _drawing
                                ? const Color(0xFF252525)
                                : Colors.white,
                            backgroundColor: _drawing
                                ? Colors.white
                                : Colors.transparent,
                            shape: const StadiumBorder(),
                            minimumSize: const Size(88, 48),
                          ),
                          child: const Text('标注'),
                        ),
                        TextButton(
                          onPressed: _saving || _current == null
                              ? null
                              : _toggleCommentMode,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(88, 48),
                            shape: const StadiumBorder(),
                            backgroundColor: _commentMode
                                ? Colors.white
                                : Colors.transparent,
                            foregroundColor: _commentMode
                                ? const Color(0xFF252525)
                                : Colors.white,
                          ),
                          child: const Text('注释'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _imagePage(ChatImageSource source) {
    final state = _states[source.id];
    if (state == null) {
      return Center(
        child: _errors.containsKey(source.id)
            ? TextButton(
                onPressed: () => _load(source),
                child: const Text('图片加载失败，点击重试'),
              )
            : const SizedBox(
                width: 180,
                height: 240,
                child: ColoredBox(color: Color(0xFF202022)),
              ),
      );
    }
    final transform = _transforms.putIfAbsent(
      source.id,
      TransformationController.new,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final fitted = applyBoxFit(
          BoxFit.contain,
          state.size,
          size,
        ).destination;
        final rect = Alignment.center.inscribe(fitted, Offset.zero & size);
        return AnimatedBuilder(
          animation: transform,
          builder: (context, _) {
            Offset point(ChatAnnotation a) => MatrixUtils.transformPoint(
              transform.value,
              Offset(
                rect.left + a.x * rect.width,
                rect.top + a.y * rect.height,
              ),
            );
            Offset pinTopLeft(Offset position) => Offset(
              (position.dx - 24)
                  .clamp(0.0, math.max(0.0, size.width - 48))
                  .toDouble(),
              (position.dy - 48)
                  .clamp(0.0, math.max(0.0, size.height - 54))
                  .toDouble(),
            );
            final visible = MatrixUtils.transformRect(
              transform.value,
              rect,
            ).intersect(Offset.zero & size);
            final active = state.annotations
                .where((a) => a.id == _activeComment)
                .firstOrNull;
            final anchor = active != null
                ? point(active)
                : _newPoint == null
                ? null
                : MatrixUtils.transformPoint(
                    transform.value,
                    Offset(
                      rect.left + _newPoint!.dx * rect.width,
                      rect.top + _newPoint!.dy * rect.height,
                    ),
                  );
            final fieldWidth = math.min(320.0, math.max(0.0, size.width - 64));
            var fieldLeft = anchor == null ? 0.0 : anchor.dx + 26;
            if (fieldLeft + fieldWidth > size.width - 12) {
              fieldLeft = (anchor?.dx ?? 0) - fieldWidth - 26;
            }
            fieldLeft = fieldLeft.clamp(
              12.0,
              math.max(12.0, size.width - fieldWidth - 12),
            );
            final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
            final inputMaxTop = math.max(
              8.0,
              math.min(size.height - 140, size.height - keyboardInset - 100),
            );
            var fieldTop = ((anchor?.dy ?? 0.0) - 40)
                .clamp(8.0, inputMaxTop)
                .toDouble();
            final downloadRect = Rect.fromLTWH(
              visible.right - 64,
              visible.bottom - 64,
              48,
              48,
            );
            if (Rect.fromLTWH(
              fieldLeft,
              fieldTop,
              fieldWidth,
              100,
            ).overlaps(downloadRect)) {
              fieldTop = math.max(8.0, downloadRect.top - 112);
            }
            final editorReady =
                source.id == _source.id &&
                state.draftPath != null &&
                _scratchPaths.contains(state.draftPath);
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _commentMode || _drawing
                      ? null
                      : () {
                          transform.value =
                              transform.value.getMaxScaleOnAxis() > 1.01
                              ? Matrix4.identity()
                              : (Matrix4.identity()
                                  ..translateByDouble(
                                    -size.width * .75,
                                    -size.height * .75,
                                    0,
                                    1,
                                  )
                                  ..scaleByDouble(2.5, 2.5, 1, 1));
                          setState(
                            () => _zoomed =
                                transform.value.getMaxScaleOnAxis() > 1.01,
                          );
                        },
                  onTapUp: !_commentMode || _saving || _drawing
                      ? null
                      : (tap) {
                          final local = transform.toScene(tap.localPosition);
                          if (!rect.contains(local)) {
                            _exitEmptyCommentMode();
                            return;
                          }
                          _commitComment();
                          setState(
                            () => _newPoint = Offset(
                              (local.dx - rect.left) / rect.width,
                              (local.dy - rect.top) / rect.height,
                            ),
                          );
                        },
                  child: InteractiveViewer(
                    key: ValueKey('gallery-viewer:${source.id}'),
                    transformationController: transform,
                    minScale: 1,
                    maxScale: 5,
                    scaleEnabled: !_drawing,
                    panEnabled: !_drawing && _zoomed,
                    onInteractionEnd: (_) {
                      if (source.id != _source.id) return;
                      final zoomed = transform.value.getMaxScaleOnAxis() > 1.01;
                      if (zoomed != _zoomed && mounted) {
                        setState(() => _zoomed = zoomed);
                      }
                    },
                    child: SizedBox.fromSize(
                      size: size,
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: rect,
                            child: Image.memory(
                              state.image,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
                          if (editorReady)
                            Positioned.fromRect(
                              rect: rect,
                              child: IgnorePointer(
                                ignoring: !_drawing,
                                child: DrawingBoardPage(
                                  key: ValueKey('inline-drawing:${source.id}'),
                                  conversationId: widget.conversationId,
                                  accountScope: widget.accountScope,
                                  draftStore: _store,
                                  draftPath: state.draftPath,
                                  embedded: true,
                                  surfaceController: _drawingController,
                                  imageAspectRatio: state.size.aspectRatio,
                                  showToolbar: _drawing,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!_drawing)
                  for (var i = 0; i < state.annotations.length; i++)
                    if ((Offset.zero & size).contains(
                      point(state.annotations[i]),
                    ))
                      Positioned(
                        left: pinTopLeft(point(state.annotations[i])).dx,
                        top: pinTopLeft(point(state.annotations[i])).dy,
                        child: ChatAnnotationPin(
                          number: i + 1,
                          onTap: () {
                            _commitComment();
                            final a = state.annotations[i];
                            setState(() {
                              _commentMode = true;
                              _activeComment = a.id;
                              _comment.text = a.comment;
                            });
                          },
                        ),
                      ),
                if (_newPoint != null &&
                    source.id == _source.id &&
                    anchor != null &&
                    (Offset.zero & size).contains(anchor))
                  Positioned(
                    left: pinTopLeft(anchor).dx,
                    top: pinTopLeft(anchor).dy,
                    child: ChatAnnotationPin(
                      number: state.annotations.length + 1,
                      onTap: () {},
                    ),
                  ),
                if (!_drawing &&
                    !visible.isEmpty &&
                    visible.width >= 64 &&
                    visible.height >= 64)
                  Positioned.fromRect(
                    rect: downloadRect,
                    child: Semantics(
                      button: true,
                      label: '下载原图',
                      child: Tooltip(
                        message: '下载原图',
                        child: GestureDetector(
                          onTap: _downloading
                              ? null
                              : () {
                                  _exitEmptyCommentMode();
                                  _download();
                                },
                          child: ClipOval(
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  svg.SvgPicture.asset(
                                    'assets/icons/chat_annotations/glass-disc.svg',
                                    width: 48,
                                    height: 48,
                                  ),
                                  chatAnnotationIcon('download', size: 24),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!_drawing && source.id == _source.id && anchor != null)
                  Positioned(
                    left: fieldLeft,
                    top: fieldTop,
                    width: fieldWidth,
                    child: ChatAnnotationInput(
                      controller: _comment,
                      optional: true,
                      onSubmit: () {
                        if (_comment.text.trim().isEmpty) {
                          AppToast.show(context, '请输入评论');
                          return;
                        }
                        setState(_commitComment);
                        FocusScope.of(context).unfocus();
                      },
                      onDelete: _activeComment == null
                          ? null
                          : () {
                              setState(() {
                                state.annotations = state.annotations
                                    .where((a) => a.id != _activeComment)
                                    .toList();
                                _activeComment = null;
                                _newPoint = null;
                                _comment.clear();
                              });
                              FocusScope.of(context).unfocus();
                            },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
