import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../services/companion_annotation_library.dart';
import '../services/companion_annotation_store.dart';
import '../services/companion_annotation_sync.dart';
import '../services/speech_recognition_service.dart';
import 'annotation_sheet.dart';
import 'app_toast.dart';

const _ink = Color(0xFF232427);
const _quiet = Color(0xFF5D626A);
const _rule = Color(0xFFE6E7E9);
const _plusAsset = 'assets/images/reading_task_plus.svg';
const _pencilAsset = 'assets/icons/extension_market/detail/pencil.svg';
const _micAsset = 'assets/icons/chat_note_editor/microphone.svg';

String _audioTime(Duration duration) {
  final seconds = (duration.inMilliseconds / 1000).ceil();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

Future<void> _fetchMissingAnnotationMedia(
  BuildContext context,
  String path,
) async {
  try {
    await CompanionAnnotationSync.instance.fetchMedia(path);
  } catch (_) {
    if (context.mounted) AppToast.show(context, '附件暂未下载，请联网后重试');
  }
}

Widget guardPrivateAnnotationContent(int revision, Widget child) =>
    _AnnotationAccountGuard(revision: revision, child: child);

Future<CompanionAnnotation?> editCompanionAnnotation(
  BuildContext context, {
  required String scope,
  required CompanionAnnotationSelection selection,
  CompanionAnnotation? initial,
  ValueChanged<double>? onViewportChanged,
}) {
  final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
  return showAnnotationSheet(
    context,
    editing: true,
    onViewportChanged: onViewportChanged,
    builder: (_) => _AnnotationAccountGuard(
      revision: revision,
      child: _CompanionAnnotationEditor(
        scope: scope,
        selection: selection,
        initial: initial,
        guardContent: (child) =>
            _AnnotationAccountGuard(revision: revision, child: child),
      ),
    ),
  );
}

Future<void> viewCompanionAnnotation(
  BuildContext context, {
  required CompanionAnnotation initial,
  required Future<CompanionAnnotation?> Function(CompanionAnnotation) onEdit,
}) async {
  final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
  Widget guard(Widget child) =>
      _AnnotationAccountGuard(revision: revision, child: child);
  var annotation = initial;
  var addingToLibrary = false;
  await showAnnotationSheet<void>(
    context,
    builder: (_) => guard(
      StatefulBuilder(
        builder: (context, update) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnnotationQuoteLine(
                annotation.selection.quote,
                guardContent: guard,
              ),
              _AnnotationBody(text: annotation.text, audio: annotation.audio),
              if (annotation.images.isNotEmpty) ...[
                const SizedBox(height: 10),
                AnnotationThumbnails(
                  paths: annotation.images,
                  guardContent: guard,
                  mediaChanges: CompanionAnnotationSync.instance.changes,
                  onMissing: (path) =>
                      unawaited(_fetchMissingAnnotationMedia(context, path)),
                ),
              ],
              const SizedBox(height: 8),
              const Divider(height: 1, color: _rule),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const _AnnotationPrivacy(),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '编辑注释',
                        onPressed: addingToLibrary
                            ? null
                            : () async {
                                final revised = await onEdit(annotation);
                                if (revised != null && context.mounted) {
                                  update(() => annotation = revised);
                                }
                              },
                        icon: annotationAsset(_pencilAsset, color: _ink),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: _ink,
                          disabledForegroundColor: _quiet,
                        ),
                        onPressed: addingToLibrary
                            ? null
                            : () async {
                                update(() => addingToLibrary = true);
                                final version = annotation;
                                try {
                                  final scope =
                                      await const CompanionAnnotationStore()
                                          .accountScope();
                                  if (!context.mounted ||
                                      revision !=
                                          CapabilityCloudSync
                                              .instance
                                              .emailSessionRevision
                                              .value) {
                                    return;
                                  }
                                  await const CompanionAnnotationLibrary()
                                      .copyToLibrary(version, scope: scope);
                                  if (context.mounted &&
                                      revision ==
                                          CapabilityCloudSync
                                              .instance
                                              .emailSessionRevision
                                              .value) {
                                    AppToast.show(context, '已加入笔记库');
                                  }
                                } on FormatException catch (error) {
                                  if (context.mounted)
                                    AppToast.show(context, error.message);
                                } catch (_) {
                                  if (context.mounted)
                                    AppToast.show(context, '加入笔记库失败，请重试');
                                } finally {
                                  if (context.mounted)
                                    update(() => addingToLibrary = false);
                                }
                              },
                        child: Text(addingToLibrary ? '正在加入' : '加入笔记库'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AnnotationAccountGuard extends StatefulWidget {
  const _AnnotationAccountGuard({required this.revision, required this.child});

  final int revision;
  final Widget child;

  @override
  State<_AnnotationAccountGuard> createState() =>
      _AnnotationAccountGuardState();
}

class _AnnotationAccountGuardState extends State<_AnnotationAccountGuard> {
  final _revision = CapabilityCloudSync.instance.emailSessionRevision;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _visible = _revision.value == widget.revision;
    _revision.addListener(_sessionChanged);
    if (!_visible) _dismissAfterFrame();
  }

  void _sessionChanged() {
    setState(() => _visible = false);
    _dismissAfterFrame();
  }

  void _dismissAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.isActive == true) {
        Navigator.of(context).removeRoute(route!);
      }
    });
  }

  @override
  void dispose() {
    _revision.removeListener(_sessionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _visible
      ? widget.child
      : const Padding(padding: EdgeInsets.all(16), child: Text('账号已切换'));
}

class _AnnotationPrivacy extends StatelessWidget {
  const _AnnotationPrivacy();

  Future<void> _showMenu(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    final visualScale = annotationVisualScaleOf(context);
    final scale =
        visualScale *
        (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
          1.0,
          double.infinity,
        );
    final headerHeight = 32.0 * scale;
    final privateHeight = 44.0 * scale;
    final disabledHeight = 36.0 * scale;
    final menuHeight =
        16 * visualScale + headerHeight + privateHeight + disabledHeight * 3;
    final itemPadding = EdgeInsets.symmetric(horizontal: 16 * visualScale);
    await showMenu<String>(
      context: context,
      useRootNavigator: true,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      menuPadding: EdgeInsets.symmetric(vertical: 8 * visualScale),
      constraints: BoxConstraints.tightFor(width: 208 * visualScale),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12 * visualScale),
        side: const BorderSide(color: _rule),
      ),
      positionBuilder: (context, constraints) {
        final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
        final bottomRight = anchor.localToGlobal(
          anchor.size.bottomRight(Offset.zero),
          ancestor: overlay,
        );
        return RelativeRect.fromLTRB(
          topLeft.dx,
          topLeft.dy - menuHeight - 8 * visualScale,
          overlay.size.width - bottomRight.dx,
          overlay.size.height - topLeft.dy + 8 * visualScale,
        );
      },
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: headerHeight,
          padding: itemPadding,
          child: Text(
            '可见范围',
            style: TextStyle(
              color: _ink,
              fontSize: 14 * visualScale,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        PopupMenuItem<String>(
          value: 'private',
          height: privateHeight,
          padding: itemPadding,
          child: Semantics(
            selected: true,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '私密',
                    style: TextStyle(color: _ink, fontSize: 14 * visualScale),
                  ),
                ),
                annotationAsset(
                  'assets/icons/drawing/check.svg',
                  color: _ink,
                  size: 20 * visualScale,
                ),
              ],
            ),
          ),
        ),
        for (final label in ['公开', '好友', '共读小组'])
          PopupMenuItem<String>(
            enabled: false,
            height: disabledHeight,
            padding: EdgeInsets.zero,
            child: Container(
              height: disabledHeight,
              padding: itemPadding,
              color: const Color(0xFFF7F7F8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: _quiet,
                        fontSize: 14 * visualScale,
                      ),
                    ),
                  ),
                  Text(
                    '暂未开放',
                    style: TextStyle(color: _quiet, fontSize: 13 * visualScale),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '可见范围，当前私密',
    child: InkWell(
      onTap: () => _showMenu(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            annotationAsset(
              'assets/icons/chat_annotations/lock-outline.svg',
              size: 17,
              color: _quiet,
            ),
            const SizedBox(width: 5),
            const Text('私密', style: TextStyle(color: _quiet)),
          ],
        ),
      ),
    ),
  );
}

class _AnnotationBody extends StatelessWidget {
  const _AnnotationBody({required this.text, required this.audio});

  final String text;
  final List<String> audio;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (text.isNotEmpty)
        Text(
          text,
          style: const TextStyle(color: _ink, fontSize: 16, height: 1.5),
        ),
      for (final path in audio)
        _AnnotationAudio(key: ValueKey(path), path: path),
    ],
  );
}

class _AnnotationAudio extends StatefulWidget {
  const _AnnotationAudio({required this.path, this.onRemove, super.key});

  final String path;
  final VoidCallback? onRemove;

  @override
  State<_AnnotationAudio> createState() => _AnnotationAudioState();
}

class _AnnotationAudioState extends State<_AnnotationAudio> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _durationSubscription;
  Future<void>? _preparingDuration;
  Duration? _duration;
  bool _durationPrepared = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    CompanionAnnotationSync.instance.changes.addListener(_mediaChanged);
    _mediaChanged();
  }

  void _mediaChanged() {
    if (!_durationPrepared && File(widget.path).existsSync()) {
      unawaited(_prepareDuration());
    }
  }

  Future<void> _prepareDuration() {
    if (_durationPrepared) return Future.value();
    return _preparingDuration ??= () async {
      try {
        await _player.setSourceDeviceFile(widget.path);
        final duration = await _player.getDuration();
        if (mounted) {
          setState(() {
            _duration = duration ?? _duration;
            _durationPrepared = true;
          });
        }
      } catch (_) {
        // Playback still retries the file if reading its metadata failed.
      } finally {
        _preparingDuration = null;
      }
    }();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!await File(widget.path).exists()) {
        if (mounted) await _fetchMissingAnnotationMedia(context, widget.path);
        if (!mounted || !await File(widget.path).exists()) return;
      }
      await _prepareDuration();
      if (!mounted) return;
      switch (_player.state) {
        case PlayerState.playing:
          await _player.pause();
        case PlayerState.paused:
          await _player.resume();
        default:
          await _player.play(DeviceFileSource(widget.path));
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '录音暂时无法播放');
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    CompanionAnnotationSync.instance.changes.removeListener(_mediaChanged);
    unawaited(_durationSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CompanionAnnotationSync.instance.changes,
    builder: (context, _) => _buildPlayer(context),
  );

  Widget _buildPlayer(BuildContext context) => StreamBuilder<PlayerState>(
    stream: _player.onPlayerStateChanged,
    initialData: _player.state,
    builder: (context, snapshot) {
      final playing = snapshot.data == PlayerState.playing;
      final pending = !File(widget.path).existsSync();
      return Material(
        color: const Color(0xFFF0F1F3),
        borderRadius: BorderRadius.circular(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: pending
                  ? '下载并播放录音'
                  : playing
                  ? '暂停录音'
                  : '播放录音',
              child: TextButton.icon(
                onPressed: _toggle,
                icon: annotationAsset(
                  'assets/icons/note_format/${playing ? 'pause' : 'play_arrow'}.svg',
                  size: 16,
                  color: _ink,
                ),
                label: Text(
                  pending
                      ? '录音待下载'
                      : _duration == null
                      ? '录音'
                      : _audioTime(_duration!),
                  style: const TextStyle(
                    color: _ink,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            if (widget.onRemove != null)
              IconButton(
                tooltip: '移除录音',
                onPressed: widget.onRemove,
                icon: annotationAsset(
                  'assets/icons/chat_note_editor/x.svg',
                  size: 15,
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _CompanionAnnotationEditor extends StatefulWidget {
  const _CompanionAnnotationEditor({
    required this.scope,
    required this.selection,
    required this.guardContent,
    this.initial,
  });

  final String scope;
  final CompanionAnnotationSelection selection;
  final CompanionAnnotation? initial;
  final Widget Function(Widget) guardContent;

  @override
  State<_CompanionAnnotationEditor> createState() =>
      _CompanionAnnotationEditorState();
}

class _CompanionAnnotationEditorState extends State<_CompanionAnnotationEditor>
    with WidgetsBindingObserver {
  static const _store = CompanionAnnotationStore();
  final _speech = SpeechRecognitionService.instance;
  final _recordingOwner = Object();
  late final _controller = TextEditingController(text: widget.initial?.text);
  late final _images = [...?widget.initial?.images];
  late final _audio = [...?widget.initial?.audio];
  final _newPaths = <String>{};
  final _recordingClock = Stopwatch();
  Timer? _recordingTicker;
  String? _recording;
  bool _busy = false;
  bool _saved = false;
  Future<CompanionAnnotation>? _pendingSave;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused || _recording == null || _busy) {
      return;
    }
    final failedPath = _recording!;
    _stopRecordingClock();
    setState(() {
      _recording = null;
      _busy = true;
    });
    unawaited(() async {
      await _speech.cancelSession(_recordingOwner);
      await _discard(failedPath);
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, '录音已中断，可重新录制');
    }());
  }

  Future<void> _discard(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      _newPaths.remove(path);
    } on FileSystemException {
      // Keep the path for a subsequent cleanup attempt.
    }
  }

  Future<void> _pickImages() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      final files = await ImagePicker().pickMultiImage();
      for (final file in files) {
        if (!mounted) break;
        final extension = file.name.split('.').last.toLowerCase();
        if (!const {
              'png',
              'jpg',
              'jpeg',
              'webp',
              'heic',
              'heif',
              'gif',
            }.contains(extension) ||
            await file.length() > 50 * 1024 * 1024 ||
            await file.length() == 0) {
          if (mounted) AppToast.show(context, '这张图片的格式或大小暂不支持');
          continue;
        }
        final path = await _store.allocateMediaPath(widget.scope, extension);
        _newPaths.add(path);
        try {
          await file.saveTo(path);
          await _validateImage(path);
          if (!mounted) {
            await _discard(path);
            return;
          }
          setState(() => _images.add(path));
        } catch (_) {
          await _discard(path);
          if (mounted) AppToast.show(context, '图片保存失败，请重试');
        }
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '无法打开图片，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _validateImage(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final codec = await descriptor.instantiateCodec(
          targetWidth: descriptor.width.clamp(1, 192),
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<void> _toggleRecording() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    var path = _recording;
    try {
      if (path != null) {
        _stopRecordingClock();
        final output = await _speech.stopAudioFileRecording(_recordingOwner);
        if (output != path || await File(path).length() <= 0) {
          throw StateError('录音未保存');
        }
        _speech.releaseSession(_recordingOwner);
        if (!mounted) {
          await _discard(path);
          return;
        }
        final savedPath = path;
        setState(() {
          _recording = null;
          _audio.add(savedPath);
        });
      } else {
        if (!_speech.acquireSession(_recordingOwner)) {
          throw StateError('麦克风正在使用');
        }
        await _speech.initialize(owner: _recordingOwner);
        if (!mounted) return;
        path = await _store.allocateMediaPath(widget.scope, 'm4a');
        _newPaths.add(path);
        await _speech.startAudioFileRecording(
          owner: _recordingOwner,
          path: path,
        );
        if (!mounted ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.paused) {
          throw StateError('录音已中断');
        }
        setState(() => _recording = path);
        _startRecordingClock();
      }
    } catch (_) {
      _stopRecordingClock();
      await _speech.cancelSession(_recordingOwner);
      if (path != null) await _discard(path);
      if (mounted) {
        setState(() => _recording = null);
        AppToast.show(context, '录音未保存，请检查麦克风权限后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startRecordingClock() {
    _recordingClock
      ..reset()
      ..start();
    _recordingTicker?.cancel();
    _recordingTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _recording != null) setState(() {});
    });
  }

  void _stopRecordingClock() {
    _recordingTicker?.cancel();
    _recordingTicker = null;
    _recordingClock.stop();
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      final pending = _pendingSave = _store.save(
        scope: widget.scope,
        selection: widget.selection,
        text: _controller.text,
        images: _images,
        audio: _audio,
        initial: widget.initial,
      );
      final record = await pending;
      _saved = true;
      _newPaths.removeAll([...record.images, ...record.audio]);
      if (mounted) Navigator.pop(context, record);
    } catch (_) {
      if (mounted) AppToast.show(context, '注释保存失败，请重试');
    } finally {
      _pendingSave = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRecordingClock();
    _controller.dispose();
    if (_recording != null || _speech.ownsSession(_recordingOwner)) {
      unawaited(
        _speech.cancelSession(_recordingOwner).whenComplete(_discardNewPaths),
      );
    } else {
      unawaited(_discardNewPaths());
    }
    super.dispose();
  }

  Future<void> _discardNewPaths() async {
    final pending = _pendingSave;
    if (pending != null) {
      try {
        final saved = await pending;
        _newPaths.removeAll([...saved.images, ...saved.audio]);
      } catch (_) {
        // The transaction failed, so the staged files are still disposable.
      }
    }
    for (final path in _newPaths.toList()) {
      await _discard(path);
    }
  }

  Widget _editableBody() => LayoutBuilder(
    builder: (context, constraints) => ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        const style = TextStyle(color: _ink, fontSize: 16, height: 1.45);
        var textWidth = constraints.maxWidth;
        if (_audio.isNotEmpty && !value.text.contains('\n')) {
          final painter = TextPainter(
            text: TextSpan(
              text: value.text.isEmpty ? '写下注释…' : value.text,
              style: style,
            ),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          if (!painter.didExceedMaxLines) {
            textWidth = math.min(
              constraints.maxWidth,
              math.max(72, painter.width + 16),
            );
          }
          painter.dispose();
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: textWidth,
              child: AnnotationTextField(controller: _controller, style: style),
            ),
            for (final path in _audio)
              _AnnotationAudio(
                key: ValueKey(path),
                path: path,
                onRemove: _busy
                    ? null
                    : () => setState(() => _audio.remove(path)),
              ),
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && _recording == null,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(color: _quiet)),
            ),
          ),
          _editableBody(),
          if (_images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 9, bottom: 4),
              child: AnnotationThumbnails(
                paths: _images,
                guardContent: widget.guardContent,
                mediaChanges: CompanionAnnotationSync.instance.changes,
                onMissing: (path) =>
                    unawaited(_fetchMissingAnnotationMedia(context, path)),
                onRemove: _busy
                    ? null
                    : (index) => setState(() => _images.removeAt(index)),
              ),
            ),
          const Divider(height: 1, color: _rule),
          Row(
            children: [
              IconButton(
                tooltip: '添加图片',
                onPressed: _busy || _recording != null ? null : _pickImages,
                icon: annotationAsset(_plusAsset),
              ),
              if (_recording != null) ...[
                Expanded(
                  child: Text(
                    '录音中 ${_audioTime(_recordingClock.elapsed)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF9D3A35),
                      fontSize: 13,
                      fontFeatures: [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _toggleRecording,
                  style: TextButton.styleFrom(foregroundColor: _ink),
                  icon: annotationAsset(
                    'assets/icons/note_format/stop.svg',
                    size: 18,
                    color: const Color(0xFF9D3A35),
                  ),
                  label: const Text('停止'),
                ),
              ] else ...[
                const Spacer(),
                IconButton(
                  tooltip: '开始录音',
                  onPressed: _busy ? null : _toggleRecording,
                  icon: annotationAsset(_micAsset, color: _quiet),
                ),
              ],
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final hasContent =
                      value.text.trim().isNotEmpty ||
                      _images.isNotEmpty ||
                      _audio.isNotEmpty;
                  return FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _ink),
                    onPressed:
                        _saved || _busy || _recording != null || !hasContent
                        ? null
                        : _save,
                    child: const Text('保存'),
                  );
                },
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: AnnotationQuoteLine(
                  widget.selection.quote,
                  guardContent: widget.guardContent,
                ),
              ),
              const SizedBox(width: 8),
              const _AnnotationPrivacy(),
            ],
          ),
        ],
      ),
    ),
  );
}
