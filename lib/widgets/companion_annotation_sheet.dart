import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
const _micAsset = 'assets/icons/chat_note_editor/microphone.svg';
const _companionAnnotationPlusSize = 27.0;

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
  Future<void> Function()? onDeleted,
  ValueChanged<double>? onViewportChanged,
}) {
  final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
  return showAnnotationSheet<CompanionAnnotation>(
    context,
    editing: true,
    barrierDismissible: true,
    matchReferenceProportions: true,
    sheetAnimationStyle: const AnimationStyle(reverseDuration: Duration.zero),
    barrierColor: initial == null
        ? const Color(0x38000000)
        : Colors.transparent,
    onViewportChanged: onViewportChanged,
    builder: (_) => _AnnotationAccountGuard(
      revision: revision,
      child: _CompanionAnnotationEditor(
        scope: scope,
        selection: selection,
        initial: initial,
        onDeleted: onDeleted,
        guardContent: (child) =>
            _AnnotationAccountGuard(revision: revision, child: child),
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

class _AnnotationPrivacy extends StatefulWidget {
  const _AnnotationPrivacy();

  @override
  State<_AnnotationPrivacy> createState() => _AnnotationPrivacyState();
}

class _AnnotationPrivacyState extends State<_AnnotationPrivacy> {
  bool _showing = false;

  Future<void> _showMenu(BuildContext context) async {
    if (_showing) return;
    _showing = true;
    try {
      final view = View.of(context);
      FocusManager.instance.primaryFocus?.unfocus();
      // Measure the trigger after the system keyboard has moved the editor.
      // Popup routes otherwise keep the coordinates from the opening frame.
      if (view.viewInsets.bottom > 0) {
        final deadline = DateTime.now().add(const Duration(milliseconds: 600));
        while (mounted &&
            view.viewInsets.bottom > 0 &&
            DateTime.now().isBefore(deadline)) {
          await WidgetsBinding.instance.endOfFrame;
        }
        if (!context.mounted) return;
      }
      await _showAnchoredMenu(context);
    } finally {
      _showing = false;
    }
  }

  Future<void> _showAnchoredMenu(BuildContext context) async {
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      1.0,
      2.0,
    );
    final headerHeight = 28.0 * textScale;
    final privateHeight = 48.0 * textScale;
    final disabledHeight = 34.0 * textScale;
    final menuHeight = 16 + headerHeight + privateHeight + disabledHeight * 3;
    final itemPadding = EdgeInsets.symmetric(horizontal: 14 * textScale);
    await showMenu<String>(
      context: context,
      useRootNavigator: true,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      constraints: BoxConstraints.tightFor(width: 184 * textScale),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
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
          topLeft.dy - menuHeight - 8,
          overlay.size.width - bottomRight.dx,
          overlay.size.height - topLeft.dy + 8,
        );
      },
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: headerHeight,
          padding: itemPadding,
          child: Text(
            '可见范围',
            style: const TextStyle(
              color: _ink,
              fontSize: 14,
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
                    style: const TextStyle(color: _ink, fontSize: 14),
                  ),
                ),
                annotationAsset(
                  'assets/icons/drawing/check.svg',
                  color: _ink,
                  size: 20,
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _quiet, fontSize: 14),
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      '暂未开放',
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _quiet, fontSize: 13),
                    ),
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
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: ListenableBuilder(
      listenable: CompanionAnnotationSync.instance.changes,
      builder: (context, _) => _buildPlayer(context),
    ),
  );

  Widget _buildPlayer(BuildContext context) => StreamBuilder<PlayerState>(
    stream: _player.onPlayerStateChanged,
    initialData: _player.state,
    builder: (context, snapshot) {
      final playing = snapshot.data == PlayerState.playing;
      final pending = !File(widget.path).existsSync();
      return Material(
        color: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              top: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F1F3),
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            Row(
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
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
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
                        fontSize: 14,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                if (widget.onRemove != null)
                  IconButton(
                    tooltip: '移除录音',
                    onPressed: widget.onRemove,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    padding: EdgeInsets.zero,
                    icon: annotationAsset(
                      'assets/icons/chat_note_editor/x.svg',
                      size: 15,
                    ),
                  ),
              ],
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
    this.onDeleted,
  });

  final String scope;
  final CompanionAnnotationSelection selection;
  final CompanionAnnotation? initial;
  final Future<void> Function()? onDeleted;
  final Widget Function(Widget) guardContent;

  @override
  State<_CompanionAnnotationEditor> createState() =>
      _CompanionAnnotationEditorState();
}

class _CompanionAnnotationEditorState extends State<_CompanionAnnotationEditor>
    with WidgetsBindingObserver {
  static const _store = CompanionAnnotationStore();
  static const _runtimeConfig = MethodChannel('xiaoqi_app/runtime_config');
  final _speech = SpeechRecognitionService.instance;
  final _recordingOwner = Object();
  final _textFieldKey = GlobalKey();
  late final _controller = TextEditingController(text: widget.initial?.text);
  late final _commitInputGuard = TextInputFormatter.withFunction(
    (oldValue, newValue) => _committing ? oldValue : newValue,
  );
  late final _images = [...?widget.initial?.images];
  late final _audio = [...?widget.initial?.audio];
  late final _committed = widget.initial;
  final _newPaths = <String>{};
  final _recordingClock = Stopwatch();
  Timer? _recordingTicker;
  String? _recording;
  bool _busy = false;
  bool _committing = false;
  bool _handlesAndroidBack = false;
  bool _copyingToLibrary = false;
  Future<CompanionAnnotation>? _pendingSave;

  bool get _compactNew =>
      widget.initial == null &&
      _audio.isEmpty &&
      _images.isEmpty &&
      _recording == null;

  bool _hasChanges(String text) {
    final committed = _committed;
    return committed == null ||
        text.trim() != committed.text ||
        !listEquals(_images, committed.images) ||
        !listEquals(_audio, committed.audio);
  }

  bool _hasContent(String text) =>
      text.trim().isNotEmpty || _images.isNotEmpty || _audio.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setAndroidBackEnabled(ModalRoute.isCurrentOf(context) == true);
  }

  void _setAndroidBackEnabled(bool enabled) {
    if (!Platform.isAndroid || enabled == _handlesAndroidBack) return;
    _handlesAndroidBack = enabled;
    unawaited(_sendAndroidBackState(enabled));
  }

  Future<void> _sendAndroidBackState(bool enabled) async {
    try {
      await _runtimeConfig.invokeMethod<void>(
        'setAnnotationEditorBackEnabled',
        {'enabled': enabled},
      );
    } on MissingPluginException {
      // The regular Flutter back handler remains available.
    } on PlatformException catch (error) {
      debugPrint('Unable to update annotation back handling: ${error.code}');
    }
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

  Future<void> _runMediaAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await withAnnotationKeyboard(_textFieldKey, action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImages() async {
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
    if (_busy || _recording != null) return;
    setState(() {
      _busy = true;
      _committing = true;
    });
    try {
      final pending = _pendingSave = _store.save(
        scope: widget.scope,
        selection: widget.selection,
        text: _controller.text,
        images: _images,
        audio: _audio,
        initial: _committed,
      );
      final record = await pending;
      _newPaths.removeAll([...record.images, ...record.audio]);
      if (!mounted) return;
      _closeEditor(record);
    } catch (_) {
      if (mounted) AppToast.show(context, '注释保存失败，请重试');
    } finally {
      _pendingSave = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _deleteCurrentAnnotation() async {
    final committed = _committed;
    if (committed == null || _busy || _recording != null) return;
    setState(() {
      _busy = true;
      _committing = true;
    });
    try {
      await _store.remove(widget.scope, committed);
      if (!mounted) return;
      unawaited(widget.onDeleted?.call());
      _closeEditor();
    } catch (_) {
      if (mounted) AppToast.show(context, '注释删除失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _exitEditor() async {
    if (!mounted || _busy || _recording != null) return;
    final text = _controller.text;
    if (_committed == null || !_hasChanges(text)) {
      _closeEditor();
    } else if (_hasContent(text)) {
      await _save();
    } else {
      await _deleteCurrentAnnotation();
    }
  }

  void _closeEditor([CompanionAnnotation? saved]) {
    final route = ModalRoute.of<CompanionAnnotation>(context);
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop(saved);
    } else {
      navigator.removeRoute(route, saved);
    }
  }

  Future<void> _copyToLibrary(CompanionAnnotation annotation) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _copyingToLibrary = true;
    });
    try {
      final scope = await _store.accountScope();
      if (!mounted || scope != widget.scope) return;
      await const CompanionAnnotationLibrary().copyToLibrary(
        annotation,
        scope: scope,
      );
      final currentScope = await _store.accountScope();
      if (!mounted || currentScope != scope) return;
      AppToast.show(
        context,
        '已加入笔记库',
        leading: annotationAsset(
          'assets/icons/drawing/check.svg',
          color: Colors.white,
          size: 18,
        ),
      );
    } on FormatException catch (error) {
      if (mounted) AppToast.show(context, error.message);
    } catch (_) {
      if (mounted) AppToast.show(context, '加入笔记库失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _copyingToLibrary = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _setAndroidBackEnabled(false);
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

  Widget _textField({TextStyle? style}) => AnnotationTextField(
    key: _textFieldKey,
    controller: _controller,
    style: style,
    autofocus: widget.initial == null,
    inputFormatters: [_commitInputGuard],
  );

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
              child: _textField(style: style),
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

  Widget _saveButton({bool compact = false}) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final hasContent = _hasContent(value.text);
          final deleting =
              _committed != null && !hasContent && _hasChanges(value.text);
          final canCommit = (hasContent || deleting) && _hasChanges(value.text);
          final size = compact ? const Size(52, 26) : const Size(56, 30);
          return TextFieldTapRegion(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: Colors.white,
                minimumSize: size,
                fixedSize: size,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 14),
              ),
              onPressed: _busy || _recording != null || !canCommit
                  ? null
                  : deleting
                  ? _deleteCurrentAnnotation
                  : _save,
              child: Text(deleting ? '删除' : '保存'),
            ),
          );
        },
      );

  Widget _libraryButton(CompanionAnnotation annotation) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) => TextButton(
          onPressed: _busy || _hasChanges(value.text)
              ? null
              : () => _copyToLibrary(annotation),
          style: TextButton.styleFrom(
            foregroundColor: _ink,
            disabledForegroundColor: _quiet,
          ),
          child: Text(_copyingToLibrary ? '正在加入' : '加入笔记库'),
        ),
      );

  Widget _plusButton() {
    final enabled = !_busy && _recording == null;
    return TextFieldTapRegion(
      child: IconButton(
        tooltip: '添加图片',
        constraints: const BoxConstraints.tightFor(
          width: annotationComposerActionSize,
          height: annotationComposerActionSize,
        ),
        style: annotationComposerActionStyle,
        padding: EdgeInsets.zero,
        onPressed: enabled ? () => _runMediaAction(_pickImages) : null,
        icon: annotationAsset(
          _plusAsset,
          size: _companionAnnotationPlusSize,
          color: enabled ? _ink : const Color(0xFF9B9DA1),
        ),
      ),
    );
  }

  Widget _micButton() => TextFieldTapRegion(
    child: IconButton(
      tooltip: '开始录音',
      onPressed: _busy ? null : () => _runMediaAction(_toggleRecording),
      icon: annotationAsset(_micAsset, color: _quiet),
    ),
  );

  Widget _recordingControl() {
    const blue = Color(0xFF0863E8);
    final duration = Duration(seconds: _recordingClock.elapsed.inSeconds);
    final elapsed = _audioTime(duration).padLeft(5, '0');
    return Stack(
      alignment: Alignment.center,
      children: [
        const Positioned.fill(
          top: 6,
          bottom: 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFEBF3FF),
              borderRadius: BorderRadius.all(Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x10085FCE),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 14),
            Flexible(
              child: Text(
                '录音中 $elapsed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: blue,
                  fontSize: 13,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
            TextFieldTapRegion(
              child: IconButton(
                tooltip: '停止录音',
                constraints: const BoxConstraints.tightFor(
                  width: annotationComposerActionSize,
                  height: annotationComposerActionSize,
                ),
                style: annotationComposerActionStyle,
                padding: EdgeInsets.zero,
                onPressed: _busy
                    ? null
                    : () => _runMediaAction(_toggleRecording),
                icon: annotationAsset(
                  'assets/icons/note_format/stop.svg',
                  size: 20,
                  color: blue,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _compactComposer() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      _plusButton(),
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: _textField(),
        ),
      ),
      _micButton(),
      _saveButton(compact: true),
    ],
  );

  Widget _editorActions() {
    final committed = _committed;
    return Row(
      children: [
        _plusButton(),
        const _AnnotationPrivacy(),
        const SizedBox(width: 8),
        if (_recording != null) ...[
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _recordingControl(),
            ),
          ),
          const SizedBox(width: 12),
          _saveButton(),
        ] else
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _micButton(),
                if (committed != null) _libraryButton(committed),
                _saveButton(),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<CompanionAnnotation>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_exitEditor());
    },
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        annotationComposerInset,
        5,
        annotationComposerInset,
        1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_compactNew)
            _compactComposer()
          else ...[
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: annotationQuoteInset,
              ),
              child: _editableBody(),
            ),
            if (_images.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: annotationQuoteInset,
                  top: 9,
                  bottom: 4,
                ),
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
            _editorActions(),
          ],
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: annotationQuoteInset,
            ),
            child: Row(
              children: [
                Expanded(
                  child: AnnotationQuoteLine(
                    widget.selection.quote,
                    guardContent: widget.guardContent,
                  ),
                ),
                if (_compactNew) ...[
                  const SizedBox(width: 8),
                  const _AnnotationPrivacy(),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
