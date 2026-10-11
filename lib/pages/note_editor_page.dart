import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        kDoubleTapSlop,
        kDoubleTapTimeout,
        kLongPressTimeout,
        kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/notebook_theme.dart';
import '../models/note.dart';
import '../models/note_attachment.dart';
import '../models/chat_note_capture.dart';
import '../models/note_editor_result.dart';
import '../models/notebook.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/note_actions.dart';
import '../services/speech_recognition_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/message_selection_action_card.dart';

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.notebookId,
    this.existingNote,
    this.bookId,
    this.bookName = '',
    this.chatSource,
    this.isBottomSheet = false,
  });

  final int notebookId;
  final Note? existingNote;
  final int? bookId;
  final String bookName;
  final ChatNoteSourceRecord? chatSource;
  final bool isBottomSheet;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

enum _SaveState { pending, saved, saving, failed }

enum _EditorToolPanel { format, voice, add }

const _formatMenuAccent = Color(0xFFE1B617);

class _NoteEditorPageState extends State<NoteEditorPage>
    with WidgetsBindingObserver {
  static const _fontSizes = <int>[30, 24, 20, 18, 16, 14, 12];

  final _db = DatabaseService();
  final _ai = AiService();
  final _picker = ImagePicker();
  final _speechService = SpeechRecognitionService.instance;
  final _inlineAudioPlayer = AudioPlayer();
  final _titleController = TextEditingController();
  final _titleFocus = FocusNode();
  final _editorFocus = FocusNode();
  final GlobalKey<quill.EditorState> _quillEditorKey =
      GlobalKey<quill.EditorState>();
  final _editorScroll = ScrollController();
  final _pageScroll = ScrollController();
  final _fontSizeAnchorKey = GlobalKey();
  final _textColorAnchorKey = GlobalKey();

  late quill.QuillController _quillController;
  late int _notebookId;
  Note? _note;
  Notebook? _notebook;
  List<Notebook> _notebooks = const [];
  Timer? _saveTimer;
  Future<Note?>? _pendingSave;
  Timer? _voiceTimer;
  Timer? _chatSourcePromptTimer;
  Timer? _chatSourceDoubleTapTimer;
  StreamSubscription<PlayerState>? _inlineAudioStateSubscription;
  StreamSubscription<Duration>? _inlineAudioPositionSubscription;
  StreamSubscription<Duration>? _inlineAudioDurationSubscription;
  String _lastSavedSignature = '';
  String _lastObservedSignature = '';
  String _initialBodySignature = '';
  String _sourcePhotoPath = '';
  String _sourceType = 'text_note';
  List<NoteAttachment> _attachments = const [];
  final List<NoteAttachment> _pendingAttachments = [];
  _EditorToolPanel? _activeToolPanel;
  TextSelection? _mediaInsertionSelection;
  String? _activeVoiceRecordingPath;
  String? _activeInlineAudioPath;
  PlayerState _inlineAudioState = PlayerState.stopped;
  Duration _inlineAudioPosition = Duration.zero;
  Duration _inlineAudioDuration = Duration.zero;
  ChatNoteSourceRecord? _pendingChatSource;
  _SaveState _saveState = _SaveState.saved;
  bool _nightMode = false;
  bool _isListening = false;
  bool _isVoicePaused = false;
  bool _isStartingVoice = false;
  bool _isTranscribing = false;
  bool _isSavingVoice = false;
  bool _voiceNeedsRetry = false;
  bool _voiceHasInsertedAudio = false;
  bool _isProcessing = false;
  bool _fontSizeMenuOpen = false;
  bool _textColorMenuOpen = false;
  bool _allowPop = false;
  bool _finishInProgress = false;
  bool _didChange = false;
  int _voiceSeconds = 0;
  int _voiceInsertionStart = 0;
  String? _voiceFailureMessage;
  List<double> _voiceLevels = List<double>.filled(24, 0.16);
  int _editorFocusRequestRevision = 0;
  double _lastKeyboardInset = 0;
  bool _initialChatSourcePromptPending = false;
  bool _allowDoubleTapChatSourcePrompt = false;
  bool _chatSourcePromptRequested = false;
  bool _chatSourcePromptShowing = false;
  bool _chatSourceDoubleTapPending = false;
  bool _chatSourcePromptWaitingForKeyboard = false;
  int? _chatSourcePromptInsertionOffset;
  int? _activeEditorPointer;
  Duration? _activeEditorPointerDownAt;
  Offset? _activeEditorPointerDownPosition;
  Duration? _lastEditorTapUpAt;
  Offset? _lastEditorTapPosition;
  TextSelection? _lastObservedEditorSelection;

  int? get _bookId => _note?.bookId ?? widget.bookId;

  String get _bookName =>
      _note?.bookName.isNotEmpty == true ? _note!.bookName : widget.bookName;

  Color get _background => widget.isBottomSheet && !_nightMode
      ? Colors.white
      : _nightMode
      ? NotebookTheme.nightBackground
      : NotebookTheme.lightBackground;
  Color get _surface => widget.isBottomSheet && !_nightMode
      ? Colors.white
      : _nightMode
      ? NotebookTheme.nightSurface
      : NotebookTheme.lightSurface;
  Color get _ink => widget.isBottomSheet && !_nightMode
      ? const Color(0xFF202124)
      : _nightMode
      ? NotebookTheme.nightInk
      : NotebookTheme.lightInk;
  Color get _muted => widget.isBottomSheet && !_nightMode
      ? const Color(0xFF7B8087)
      : _nightMode
      ? NotebookTheme.nightMuted
      : NotebookTheme.lightMuted;
  Color get _divider => widget.isBottomSheet && !_nightMode
      ? const Color(0xFFE6E8EB)
      : _nightMode
      ? NotebookTheme.nightDivider
      : NotebookTheme.lightDivider;
  Color get _accent => widget.isBottomSheet && !_nightMode
      ? const Color(0xFF202124)
      : _nightMode
      ? NotebookTheme.nightAccent
      : NotebookTheme.accent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastKeyboardInset = _currentKeyboardInset;
    _note = widget.existingNote;
    _notebookId = widget.existingNote?.notebookId ?? widget.notebookId;
    _sourcePhotoPath = widget.existingNote?.sourcePhotoPath.isNotEmpty == true
        ? widget.existingNote!.sourcePhotoPath
        : widget.existingNote?.photoPath ?? '';
    _sourceType = widget.existingNote?.sourceType ?? 'text_note';
    _titleController.text = widget.existingNote?.title ?? '';
    _pendingChatSource = widget.chatSource;
    _initialChatSourcePromptPending =
        widget.isBottomSheet &&
        (widget.chatSource?.sourceText.trim().isNotEmpty ?? false);
    final initialDocument = _initialDocument(widget.existingNote);
    _quillController = quill.QuillController(
      document: initialDocument,
      selection: const TextSelection.collapsed(offset: 0),
      onSelectionChanged: _onEditorSelectionChanged,
    );
    _lastObservedEditorSelection = _quillController.selection;
    _initialBodySignature = jsonEncode(
      _quillController.document.toDelta().toJson(),
    );
    _lastSavedSignature = _signature();
    _lastObservedSignature = _lastSavedSignature;
    _titleController.addListener(_onContentChanged);
    _quillController.addListener(_onContentChanged);
    _inlineAudioStateSubscription = _inlineAudioPlayer.onPlayerStateChanged
        .listen((playerState) {
          if (!mounted) return;
          setState(() {
            _inlineAudioState = playerState;
            if (playerState == PlayerState.completed) {
              _activeInlineAudioPath = null;
              _inlineAudioPosition = Duration.zero;
            }
          });
        });
    _inlineAudioPositionSubscription = _inlineAudioPlayer.onPositionChanged
        .listen((position) {
          if (mounted) setState(() => _inlineAudioPosition = position);
        });
    _inlineAudioDurationSubscription = _inlineAudioPlayer.onDurationChanged
        .listen((duration) {
          if (mounted) setState(() => _inlineAudioDuration = duration);
        });
    _titleFocus.addListener(_onChatInputFocusChanged);
    _editorFocus.addListener(_onChatInputFocusChanged);
    _loadNotebookContext();
    unawaited(_loadNoteAttachments());
    if (widget.chatSource != null) {
      _saveState = _SaveState.pending;
    }
  }

  void _onEditorSelectionChanged(TextSelection selection) {
    if (!widget.isBottomSheet || selection.isCollapsed) return;
    _quillController.skipRequestKeyboard = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_quillController.skipRequestKeyboard) return;
      _quillController.skipRequestKeyboard = false;
    });
  }

  Future<void> _loadNoteAttachments() async {
    final noteId = _note?.id;
    if (noteId == null) return;
    try {
      final attachments = await _db.queryNoteAttachments(noteId);
      if (!mounted) return;
      setState(() => _attachments = attachments);
      if (!_didChange && _pendingSave == null) {
        _lastSavedSignature = _signature();
        _lastObservedSignature = _lastSavedSignature;
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '附件读取失败，请重新打开笔记');
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final keyboardInset = _currentKeyboardInset;
    final keyboardWasVisible = _lastKeyboardInset > 0;
    _lastKeyboardInset = keyboardInset;
    if (keyboardInset > 0) {
      _showChatNoteToolbarIfNeeded();
      if (_activeToolPanel != null) {
        unawaited(_closeToolPanel());
      }
    }
    if (keyboardWasVisible &&
        keyboardInset <= 0 &&
        (_titleFocus.hasFocus || _editorFocus.hasFocus)) {
      if (!_editorFocus.hasFocus || _quillController.selection.isCollapsed) {
        _dismissChatSourcePromptForOtherAction();
        _unfocusEditorInputs();
      }
    }
  }

  double get _currentKeyboardInset {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    final view = views.first;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  quill.Document _initialDocument(Note? note) {
    final delta = note?.contentDelta.trim() ?? '';
    late quill.Document document;
    if (delta.isNotEmpty) {
      try {
        final decoded = jsonDecode(delta);
        if (decoded is List<dynamic>) {
          document = quill.Document.fromJson(decoded);
        } else {
          document = _plainTextDocument(note?.content ?? '');
        }
      } catch (_) {
        // 兼容旧版本纯文本笔记。
        document = _plainTextDocument(note?.content ?? '');
      }
    } else {
      document = _plainTextDocument(note?.content ?? '');
    }
    return document;
  }

  void _onChatInputFocusChanged() {
    if (!mounted) return;
    setState(() {});
    if (_editorFocus.hasFocus) {
      _showChatNoteToolbarIfNeeded();
    } else if (_chatSourcePromptShowing ||
        _chatSourcePromptRequested ||
        _chatSourcePromptWaitingForKeyboard) {
      _dismissChatSourcePromptForOtherAction();
    }
  }

  bool get _hasChatSourceText =>
      widget.chatSource?.sourceText.trim().isNotEmpty ?? false;

  bool get _canShowChatSourceActions =>
      widget.isBottomSheet &&
      _editorFocus.hasFocus &&
      MediaQuery.viewInsetsOf(context).bottom > 0 &&
      _hasChatSourceText;

  void _showChatNoteToolbarIfNeeded() {
    if ((!_initialChatSourcePromptPending &&
            !_chatSourcePromptWaitingForKeyboard) ||
        !_editorFocus.hasFocus ||
        _currentKeyboardInset <= 0 ||
        !_hasChatSourceText) {
      return;
    }
    _chatSourcePromptTimer?.cancel();
    // Wait until the IME inset stops changing so the caret toolbar is built
    // against the final keyboard layout.
    _chatSourcePromptTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted ||
          (!_initialChatSourcePromptPending &&
              !_chatSourcePromptWaitingForKeyboard) ||
          !_editorFocus.hasFocus ||
          _currentKeyboardInset <= 0) {
        return;
      }
      if (!_canShowChatSourceActions) {
        _showChatNoteToolbarIfNeeded();
        return;
      }
      if (_activeEditorPointer != null) {
        _showChatNoteToolbarIfNeeded();
        return;
      }

      final editorState = _quillEditorKey.currentState;
      if (editorState == null) {
        _showChatNoteToolbarIfNeeded();
        return;
      }
      if (_initialChatSourcePromptPending &&
          editorState.selectionOverlay?.toolbar != null) {
        // A native selection menu already owns the editor overlay.
        _initialChatSourcePromptPending = false;
        _allowDoubleTapChatSourcePrompt = true;
        return;
      }

      _initialChatSourcePromptPending = false;
      if (_chatSourcePromptWaitingForKeyboard) {
        final overlay = editorState.selectionOverlay;
        if (overlay?.toolbar != null) overlay!.hideToolbar();
      } else {
        _chatSourcePromptInsertionOffset =
            _quillController.selection.extentOffset;
      }
      _chatSourcePromptWaitingForKeyboard = false;
      _chatSourcePromptRequested = true;
      _lastEditorTapUpAt = null;
      _lastEditorTapPosition = null;
      if (!editorState.showToolbar()) {
        _chatSourcePromptRequested = false;
        _allowDoubleTapChatSourcePrompt = true;
      }
    });
  }

  Widget _buildChatNoteContextMenu(
    BuildContext context,
    quill.QuillRawEditorState editorState,
  ) {
    if (_chatSourceDoubleTapPending || _chatSourcePromptWaitingForKeyboard) {
      return const SizedBox.shrink();
    }
    if (!_canShowChatSourceActions || !_chatSourcePromptRequested) {
      return quill.QuillRawEditorConfig.defaultContextMenuBuilder(
        context,
        editorState,
      );
    }

    final insertionOffset =
        _chatSourcePromptInsertionOffset ??
        _quillController.selection.extentOffset;
    final caretRect = editorState.renderEditor.getLocalRectForCaret(
      TextPosition(offset: insertionOffset),
    );
    final caretGlobalTop = editorState.renderEditor.localToGlobal(
      caretRect.topLeft,
    );
    final caretGlobalBottom = editorState.renderEditor.localToGlobal(
      caretRect.bottomLeft,
    );
    _chatSourcePromptShowing = true;
    return TextSelectionToolbar(
      anchorAbove: caretGlobalTop,
      anchorBelow: caretGlobalBottom,
      toolbarBuilder: (context, child) => child,
      children: [
        MessageSelectionActionCard(
          primaryLabel: '插入笔记',
          primaryAsset: 'assets/images/home_reply_note.svg',
          onPrimaryAction: () {
            editorState.hideToolbar();
            _chatSourcePromptShowing = false;
            _chatSourcePromptRequested = false;
            _chatSourceDoubleTapPending = false;
            _chatSourcePromptWaitingForKeyboard = false;
            _allowDoubleTapChatSourcePrompt = false;
            _initialChatSourcePromptPending = false;
            final offset =
                (_chatSourcePromptInsertionOffset ??
                        _quillController.selection.extentOffset)
                    .clamp(0, _quillController.document.length - 1);
            _quillController.updateSelection(
              TextSelection.collapsed(offset: offset),
              quill.ChangeSource.local,
            );
            _insertChatSource();
          },
        ),
      ],
    );
  }

  void _closeChatSourcePrompt() {
    _chatSourcePromptTimer?.cancel();
    _chatSourceDoubleTapTimer?.cancel();
    final ownsToolbar =
        _chatSourcePromptRequested ||
        _chatSourcePromptShowing ||
        _chatSourceDoubleTapPending ||
        _chatSourcePromptWaitingForKeyboard;
    if (ownsToolbar) {
      final overlay = _quillEditorKey.currentState?.selectionOverlay;
      if (overlay?.toolbar != null) overlay!.hideToolbar();
    }
    _chatSourcePromptRequested = false;
    _chatSourceDoubleTapPending = false;
    _chatSourcePromptWaitingForKeyboard = false;
    _chatSourcePromptShowing = false;
  }

  void _dismissChatSourcePromptForOtherAction({bool preserveTap = false}) {
    if (!_hasChatSourceText) return;
    final initialOpportunityPassed =
        _initialChatSourcePromptPending &&
        _editorFocus.hasFocus &&
        _currentKeyboardInset > 0;
    final promptWasVisible =
        _chatSourcePromptRequested ||
        _chatSourcePromptShowing ||
        _chatSourcePromptWaitingForKeyboard;
    if (initialOpportunityPassed || promptWasVisible) {
      _initialChatSourcePromptPending = false;
      _allowDoubleTapChatSourcePrompt = true;
    }
    _closeChatSourcePrompt();
    if (!preserveTap) {
      _lastEditorTapUpAt = null;
      _lastEditorTapPosition = null;
    }
  }

  void _handleChatNoteEditorPointerDown(PointerDownEvent event) {
    if (!widget.isBottomSheet || !_hasChatSourceText) return;
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus) {
      _dismissChatSourcePromptForOtherAction();
      return;
    }

    _dismissChatSourcePromptForOtherAction(preserveTap: true);
    final elapsed = _lastEditorTapUpAt == null
        ? null
        : event.timeStamp - _lastEditorTapUpAt!;
    final isDoubleTap =
        _allowDoubleTapChatSourcePrompt &&
        elapsed != null &&
        elapsed > Duration.zero &&
        elapsed <= kDoubleTapTimeout &&
        _lastEditorTapPosition != null &&
        (event.position - _lastEditorTapPosition!).distance <= kDoubleTapSlop;

    _lastEditorTapUpAt = null;
    _lastEditorTapPosition = null;
    _activeEditorPointer = event.pointer;
    _activeEditorPointerDownAt = event.timeStamp;
    _activeEditorPointerDownPosition = event.position;
    if (!isDoubleTap) {
      _chatSourcePromptRequested = false;
      _chatSourcePromptWaitingForKeyboard = false;
      return;
    }

    final renderEditor = _quillEditorKey.currentState?.renderEditor;
    if (renderEditor == null) return;
    final localPosition = renderEditor.globalToLocal(event.position);
    final textPosition = renderEditor.getPositionForOffset(localPosition);
    _chatSourcePromptInsertionOffset = textPosition.offset.clamp(
      0,
      _quillController.document.length - 1,
    );
    _chatSourceDoubleTapPending = true;
    _chatSourcePromptRequested = false;
    _chatSourcePromptWaitingForKeyboard = false;
    _chatSourceDoubleTapTimer?.cancel();
    _chatSourceDoubleTapTimer = Timer(kLongPressTimeout, () {
      if (_activeEditorPointer != event.pointer ||
          !_chatSourceDoubleTapPending) {
        return;
      }
      _chatSourceDoubleTapPending = false;
      final overlay = _quillEditorKey.currentState?.selectionOverlay;
      if (overlay?.toolbar != null) overlay!.hideToolbar();
    });
  }

  void _handleChatNoteEditorPointerMove(PointerMoveEvent event) {
    if (_activeEditorPointer != event.pointer ||
        !_chatSourceDoubleTapPending ||
        _activeEditorPointerDownPosition == null) {
      return;
    }
    if ((event.position - _activeEditorPointerDownPosition!).distance >
        kTouchSlop) {
      _chatSourceDoubleTapTimer?.cancel();
      _chatSourceDoubleTapPending = false;
      final overlay = _quillEditorKey.currentState?.selectionOverlay;
      if (overlay?.toolbar != null) overlay!.hideToolbar();
    }
  }

  void _handleChatNoteEditorPointerUp(PointerUpEvent event) {
    if (_activeEditorPointer != event.pointer) return;
    final downAt = _activeEditorPointerDownAt;
    final downPosition = _activeEditorPointerDownPosition;
    final heldFor = downAt == null
        ? kLongPressTimeout
        : event.timeStamp - downAt;
    final stayedNearStart =
        downPosition != null &&
        (event.position - downPosition).distance <= kTouchSlop;
    final shouldShowDoubleTapPrompt =
        _chatSourceDoubleTapPending &&
        heldFor < kLongPressTimeout &&
        stayedNearStart;

    _activeEditorPointer = null;
    _activeEditorPointerDownAt = null;
    _activeEditorPointerDownPosition = null;
    _chatSourceDoubleTapTimer?.cancel();
    if (shouldShowDoubleTapPrompt) {
      _chatSourceDoubleTapPending = false;
      final overlay = _quillEditorKey.currentState?.selectionOverlay;
      if (overlay?.toolbar != null) overlay!.hideToolbar();
      _chatSourcePromptRequested = true;
      if (!_canShowChatSourceActions) {
        _chatSourcePromptRequested = false;
        _chatSourcePromptWaitingForKeyboard = true;
        _showChatNoteToolbarIfNeeded();
      } else {
        // Let Quill finish this pointer sequence before replacing its menu.
        Timer.run(() {
          if (!mounted || !_chatSourcePromptRequested) return;
          if (!_canShowChatSourceActions) {
            _chatSourcePromptRequested = false;
            _chatSourcePromptWaitingForKeyboard = true;
            _showChatNoteToolbarIfNeeded();
            return;
          }
          final editorState = _quillEditorKey.currentState;
          if (editorState == null) {
            _chatSourcePromptRequested = false;
            _chatSourcePromptWaitingForKeyboard = true;
            _showChatNoteToolbarIfNeeded();
          } else if (editorState.selectionOverlay?.toolbar == null &&
              !editorState.showToolbar()) {
            _chatSourcePromptRequested = false;
            _chatSourcePromptWaitingForKeyboard = true;
            _showChatNoteToolbarIfNeeded();
          }
        });
      }
      return;
    }

    if (_chatSourceDoubleTapPending || heldFor >= kLongPressTimeout) {
      if (_chatSourceDoubleTapPending) {
        final overlay = _quillEditorKey.currentState?.selectionOverlay;
        if (overlay?.toolbar != null) overlay!.hideToolbar();
      }
      _chatSourceDoubleTapPending = false;
      _lastEditorTapUpAt = null;
      _lastEditorTapPosition = null;
      if (heldFor >= kLongPressTimeout) {
        _dismissChatSourcePromptForOtherAction();
      }
    } else if (heldFor < kLongPressTimeout && stayedNearStart) {
      _lastEditorTapUpAt = event.timeStamp;
      _lastEditorTapPosition = event.position;
    }
    if (_initialChatSourcePromptPending) _showChatNoteToolbarIfNeeded();
  }

  void _handleChatNoteEditorPointerCancel(PointerCancelEvent event) {
    if (_activeEditorPointer != event.pointer) return;
    if (_chatSourceDoubleTapPending) {
      final overlay = _quillEditorKey.currentState?.selectionOverlay;
      if (overlay?.toolbar != null) overlay!.hideToolbar();
    }
    _activeEditorPointer = null;
    _activeEditorPointerDownAt = null;
    _activeEditorPointerDownPosition = null;
    _chatSourceDoubleTapTimer?.cancel();
    _chatSourceDoubleTapPending = false;
    _chatSourcePromptRequested = false;
    _chatSourcePromptWaitingForKeyboard = false;
    _lastEditorTapUpAt = null;
    _lastEditorTapPosition = null;
  }

  void _unfocusEditorInputs() {
    _dismissChatSourcePromptForOtherAction();
    _editorFocusRequestRevision++;
    _titleFocus.unfocus();
    _editorFocus.unfocus();
    FocusScope.of(context).unfocus();
  }

  void _hideKeyboardForBack() {
    if (_editorFocus.hasFocus && !_quillController.selection.isCollapsed) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return;
    }
    _unfocusEditorInputs();
  }

  void _handleEditorSurfaceTap() {
    if (_isProcessing) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _unfocusEditorInputs();
      return;
    }

    final endOffset = _quillController.document.length - 1;
    _quillController.updateSelection(
      TextSelection.collapsed(offset: endOffset),
      quill.ChangeSource.local,
    );
    _unfocusEditorInputs();
    final focusRevision = _editorFocusRequestRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusRevision == _editorFocusRequestRevision) {
        _editorFocus.requestFocus();
      }
    });
  }

  Future<void> _runChatEditorTool(Future<void> Function() action) async {
    if (!mounted) return;
    _unfocusEditorInputs();
    try {
      if (widget.isBottomSheet) {
        while (mounted && _currentKeyboardInset > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
      if (!mounted) return;
      await action();
    } finally {
      if (mounted) _unfocusEditorInputs();
    }
  }

  void _invokeChatEditorTool(Future<void> Function() action) {
    unawaited(_runChatEditorTool(action));
  }

  quill.Document _plainTextDocument(String text) {
    return quill.Document.fromJson([
      {
        'insert': text.isEmpty
            ? '\n'
            : text.endsWith('\n')
            ? text
            : '$text\n',
      },
    ]);
  }

  Future<void> _loadNotebookContext() async {
    try {
      final notebooks = await _db.queryNotebooks();
      final notebook = await _db.getNotebookById(_notebookId);
      if (!mounted) return;
      setState(() {
        _notebooks = notebooks;
        _notebook = notebook;
      });
    } catch (error) {
      if (mounted) AppToast.show(context, '笔记本信息加载失败');
    }
  }

  void _onContentChanged() {
    if (!mounted) return;
    final selection = _quillController.selection;
    final selectionChanged = selection != _lastObservedEditorSelection;
    _lastObservedEditorSelection = selection;
    final signature = _signature();
    final guideActive =
        _chatSourcePromptRequested ||
        _chatSourcePromptShowing ||
        _chatSourcePromptWaitingForKeyboard;
    if (selectionChanged && _editorFocus.hasFocus && guideActive) {
      _dismissChatSourcePromptForOtherAction();
    }
    if (signature == _lastObservedSignature) {
      if (selectionChanged && _activeToolPanel == _EditorToolPanel.format) {
        setState(() {});
      }
      return;
    }
    _lastObservedSignature = signature;
    if (_editorFocus.hasFocus &&
        _currentKeyboardInset > 0 &&
        (_initialChatSourcePromptPending ||
            _chatSourcePromptShowing ||
            _chatSourcePromptWaitingForKeyboard)) {
      _dismissChatSourcePromptForOtherAction();
    }
    if (signature == _lastSavedSignature) return;
    _didChange = true;
    _saveTimer?.cancel();
    setState(() => _saveState = _SaveState.saving);
    _saveTimer = Timer(const Duration(milliseconds: 620), _save);
  }

  String _plainText() {
    final value = _quillController.document.toPlainText().replaceAll(
      '\uFFFC',
      '',
    );
    return value.endsWith('\n') ? value.substring(0, value.length - 1) : value;
  }

  bool _hasBodyContent() {
    if (_plainText().trim().isNotEmpty) return true;
    return _quillController.document.toDelta().toJson().any((operation) {
      if (operation is! Map) return true;
      return operation['insert'] is! String;
    });
  }

  bool get _isEmptyChatNote {
    if (!widget.isBottomSheet ||
        _titleController.text.trim().isNotEmpty ||
        _sourcePhotoPath.trim().isNotEmpty ||
        _attachments.isNotEmpty ||
        _pendingAttachments.isNotEmpty ||
        _hasBodyContent()) {
      return false;
    }

    final note = _note;
    if (note == null) return true;
    if (note.type != 'text' ||
        note.photoPath.trim().isNotEmpty ||
        note.originalPhotoPath.trim().isNotEmpty ||
        note.pdfPath.trim().isNotEmpty ||
        (note.annotationsJson?.trim().isNotEmpty ?? false)) {
      return false;
    }

    final currentBodySignature = jsonEncode(
      _quillController.document.toDelta().toJson(),
    );
    return note.content.trim().isEmpty ||
        currentBodySignature != _initialBodySignature;
  }

  String _signature() {
    return jsonEncode({
      'title': _titleController.text.trim(),
      'delta': _quillController.document.toDelta().toJson(),
      'notebook': _notebookId,
      'source': _sourceType,
      'photo': _sourcePhotoPath,
      'book': _bookId,
      'attachments': [
        ..._attachments.map((item) => item.relativePath),
        ..._pendingAttachments.map((item) => item.relativePath),
      ],
    });
  }

  Future<Note?> _save({bool force = false}) {
    final pending = _pendingSave;
    if (pending != null) return pending;
    final save = _saveOnce(force: force);
    _pendingSave = save;
    return save.whenComplete(() {
      if (identical(_pendingSave, save)) _pendingSave = null;
    });
  }

  Future<Note?> _saveOnce({required bool force}) async {
    _saveTimer?.cancel();
    final title = _titleController.text.trim();
    final content = _plainText().trim();
    final delta = _quillController.document.toDelta().toJson();
    final signature = jsonEncode({
      'title': title,
      'delta': delta,
      'notebook': _notebookId,
      'source': _sourceType,
      'photo': _sourcePhotoPath,
      'book': _bookId,
      'attachments': [
        ..._attachments.map((item) => item.relativePath),
        ..._pendingAttachments.map((item) => item.relativePath),
      ],
    });
    if (!force && signature == _lastSavedSignature) {
      if (mounted && _saveState != _SaveState.saved) {
        setState(() => _saveState = _SaveState.saved);
      }
      return _note;
    }
    if (_note == null &&
        title.isEmpty &&
        content.isEmpty &&
        _sourcePhotoPath.isEmpty &&
        _attachments.isEmpty &&
        _pendingAttachments.isEmpty &&
        !_hasBodyContent()) {
      if (mounted) setState(() => _saveState = _SaveState.saved);
      _lastSavedSignature = signature;
      return null;
    }

    if (mounted) setState(() => _saveState = _SaveState.saving);
    final now = DateTime.now().toIso8601String();
    final safeTitle = title.length > 40 ? title.substring(0, 40) : title;
    final value =
        (_note ??
                Note(
                  notebookId: _notebookId,
                  bookId: _bookId,
                  bookName: _bookName,
                  type: 'text',
                  createdAt: now,
                  updatedAt: now,
                ))
            .copyWith(
              notebookId: _notebookId,
              bookId: _bookId,
              bookName: _bookName,
              title: safeTitle,
              content: content,
              contentDelta: jsonEncode(delta),
              sourceType: _sourceType,
              sourcePhotoPath: _sourcePhotoPath,
              updatedAt: now,
            );
    try {
      final attachmentsToSave = List<NoteAttachment>.of(_pendingAttachments);
      final result = await _db.saveNoteEditorSnapshot(
        value,
        source: _pendingChatSource,
        newAttachments: attachmentsToSave,
      );
      final id = result.$1;
      _note = value.copyWith(id: id);
      _pendingChatSource = null;
      if (attachmentsToSave.isNotEmpty) {
        final savedPaths = attachmentsToSave
            .map((item) => item.relativePath)
            .toSet();
        _pendingAttachments.removeWhere(
          (item) => savedPaths.contains(item.relativePath),
        );
        _attachments = [..._attachments, ...result.$2]
          ..sort((first, second) => first.position.compareTo(second.position));
      }
      _lastSavedSignature = signature;
      final changedWhileSaving = _signature() != signature;
      if (mounted) {
        setState(
          () => _saveState = changedWhileSaving
              ? _SaveState.saving
              : _SaveState.saved,
        );
      }
      if (changedWhileSaving) {
        _saveTimer?.cancel();
        _saveTimer = Timer(const Duration(milliseconds: 80), _save);
      }
      return _note;
    } catch (error) {
      if (mounted) {
        setState(() => _saveState = _SaveState.failed);
        AppToast.show(context, '自动保存失败，请检查存储空间后重试');
      }
      return null;
    }
  }

  Future<void> _finish() async {
    if (_finishInProgress) return;
    _finishInProgress = true;
    if (_activeToolPanel != null) await _closeToolPanel();
    _unfocusEditorInputs();
    Note? saved = _note;
    if (_isEmptyChatNote) {
      _saveTimer?.cancel();
      final pendingSave = _pendingSave;
      if (pendingSave != null) {
        await pendingSave;
        if (!mounted) return;
      }
      if (_signature() != _lastSavedSignature) {
        saved = await _save(force: true);
        if (!mounted) return;
        if (_saveState == _SaveState.failed && _note?.id != null) {
          _finishInProgress = false;
          return;
        }
      }

      final noteId = _note?.id ?? saved?.id;
      if (noteId != null) {
        try {
          await _db.softDelete(noteId);
        } catch (_) {
          if (!mounted) return;
          _finishInProgress = false;
          setState(() => _saveState = _SaveState.failed);
          AppToast.show(context, '删除空白笔记失败，请重试');
          return;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop(const NoteEditorResult.unchanged());
      return;
    }

    if (_signature() != _lastSavedSignature) {
      saved = await _save(force: true);
      if (!mounted) return;
      if (_saveState == _SaveState.failed) {
        _finishInProgress = false;
        return;
      }
    }
    setState(() => _allowPop = true);
    final result = saved == null || !_didChange
        ? const NoteEditorResult.unchanged()
        : NoteEditorResult.saved(saved);
    Navigator.of(context).pop(result);
  }

  void _toggleAttribute(quill.Attribute<dynamic> attribute) {
    final active = _quillController.getSelectionStyle().attributes.containsKey(
      attribute.key,
    );
    _quillController.formatSelection(
      active ? quill.Attribute.clone(attribute, null) : attribute,
    );
  }

  void _applyBlock(quill.Attribute<dynamic>? attribute) {
    if (attribute == null) {
      for (final item in <quill.Attribute<dynamic>>[
        quill.Attribute.header,
        quill.Attribute.blockQuote,
        quill.Attribute.list,
      ]) {
        _quillController.formatSelection(quill.Attribute.clone(item, null));
      }
    } else {
      _quillController.formatSelection(attribute);
    }
  }

  void _insertText(String text) {
    final selection = _quillController.selection;
    final start = selection.start.clamp(
      0,
      _quillController.document.length - 1,
    );
    final length = selection.isValid ? selection.end - selection.start : 0;
    _quillController.replaceText(
      start,
      length,
      text,
      TextSelection.collapsed(offset: start + text.length),
    );
  }

  void _insertChatSource() {
    final text = widget.chatSource?.sourceText;
    if (text == null || text.trim().isEmpty) return;
    _insertText(text);
    _editorFocus.requestFocus();
  }

  TextSelection _captureMediaInsertionSelection() {
    final maximum = max(0, _quillController.document.length - 1);
    final offset = _quillController.selection.extentOffset.clamp(0, maximum);
    return TextSelection.collapsed(offset: offset);
  }

  void _showToolPanel(_EditorToolPanel panel) {
    final previous = _activeToolPanel;
    if (previous == panel) {
      unawaited(_closeToolPanel());
      return;
    }
    if (previous == _EditorToolPanel.voice) {
      unawaited(_cancelVoiceSession());
    }
    if (panel == _EditorToolPanel.add || panel == _EditorToolPanel.voice) {
      _mediaInsertionSelection = _captureMediaInsertionSelection();
    }
    _unfocusEditorInputs();
    setState(() => _activeToolPanel = panel);
  }

  Future<void> _closeToolPanel() async {
    final previous = _activeToolPanel;
    if (previous == null) return;
    setState(() => _activeToolPanel = null);
    if (previous == _EditorToolPanel.voice) await _cancelVoiceSession();
  }

  Future<void> _cancelVoiceSession() async {
    _voiceTimer?.cancel();
    await _speechService.cancelSession(this);
    final partialPath = _activeVoiceRecordingPath;
    _activeVoiceRecordingPath = null;
    if (partialPath != null) await _deleteStoredAttachment(partialPath);
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _isVoicePaused = false;
      _isStartingVoice = false;
      _isTranscribing = false;
      _isSavingVoice = false;
      _voiceNeedsRetry = false;
      _voiceHasInsertedAudio = false;
      _voiceFailureMessage = null;
      _voiceSeconds = 0;
      _voiceLevels = List<double>.filled(24, 0.16);
    });
  }

  Future<void> _startChatVoice() async {
    if (_isStartingVoice || _isListening || _isSavingVoice) return;
    if (_speechService.ownsSession(this)) {
      await _speechService.cancelSession(this);
    }
    if (!_speechService.acquireSession(this)) {
      AppToast.show(context, '上一轮语音识别仍在结束，请稍后重试');
      return;
    }
    setState(() {
      _isStartingVoice = true;
      _voiceNeedsRetry = false;
      _voiceFailureMessage = null;
    });
    try {
      await _speechService.initialize(owner: this);
      if (!mounted) {
        unawaited(_speechService.cancelSession(this));
        return;
      }
      final recording = await _createVoiceRecordingFile();
      if (!mounted || !_speechService.ownsSession(this)) {
        await _deleteStoredAttachment(recording.$1);
        return;
      }
      _activeVoiceRecordingPath = recording.$1;
      _voiceInsertionStart =
          _mediaInsertionSelection?.extentOffset ??
          _quillController.selection.extentOffset;
      await _speechService.startAudioFileRecording(
        owner: this,
        path: recording.$2,
        onSoundLevel: _onVoiceSoundLevel,
      );
      if (!mounted || !_speechService.ownsSession(this)) return;
      setState(() {
        _isStartingVoice = false;
        _isListening = true;
        _isVoicePaused = false;
        _voiceSeconds = 0;
      });
      _startVoiceTimer();
    } catch (error) {
      await _speechService.cancelSession(this);
      if (!mounted) return;
      setState(() {
        _isStartingVoice = false;
        _isListening = false;
        _isVoicePaused = false;
      });
      final partialPath = _activeVoiceRecordingPath;
      _activeVoiceRecordingPath = null;
      if (partialPath != null) await _deleteStoredAttachment(partialPath);
      AppToast.show(context, '录音无法启动，请检查麦克风权限后重试');
    }
  }

  void _onVoiceSoundLevel(double decibels) {
    if (!mounted || !_isListening || _isVoicePaused) return;
    final level = ((decibels + 58) / 58).clamp(0.08, 1.0).toDouble();
    setState(() {
      _voiceLevels = [..._voiceLevels.skip(1), level];
    });
  }

  void _startVoiceTimer() {
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isListening && !_isVoicePaused) {
        setState(() => _voiceSeconds++);
      }
    });
  }

  Future<void> _pauseOrResumeChatVoice() async {
    if (!_isListening || _isStartingVoice || _isSavingVoice) return;
    try {
      if (_isVoicePaused) {
        await _speechService.resumeRecording(this);
        if (!mounted) return;
        setState(() => _isVoicePaused = false);
        _startVoiceTimer();
      } else {
        await _speechService.pauseRecording(this);
        _voiceTimer?.cancel();
        if (mounted) setState(() => _isVoicePaused = true);
      }
    } catch (error) {
      if (mounted) AppToast.show(context, '录音状态切换失败，请重试');
    }
  }

  Future<void> _stopChatVoice() async {
    if (!_isListening || _isSavingVoice) return;
    _voiceTimer?.cancel();
    setState(() {
      _isListening = false;
      _isVoicePaused = false;
      _isSavingVoice = true;
      _voiceFailureMessage = null;
    });
    try {
      final outputPath = await _speechService.stopAudioFileRecording(this);
      if (!mounted || !_speechService.ownsSession(this)) return;
      final relativePath = _activeVoiceRecordingPath;
      final path =
          outputPath ??
          (relativePath == null
              ? null
              : await _attachmentAbsolutePath(relativePath));
      if (path == null ||
          !await File(path).exists() ||
          await File(path).length() == 0) {
        setState(() {
          _isSavingVoice = false;
          _voiceNeedsRetry = true;
          _voiceFailureMessage = '录音没有保存成功，请重新录制';
        });
        return;
      }
      final attachmentPath =
          relativePath ??
          p.relative(
            path,
            from: (await getApplicationDocumentsDirectory()).path,
          );
      final attachment = NoteAttachment(
        name: '语音录音.m4a',
        relativePath: attachmentPath,
        kind: 'audio',
        mimeType: 'audio/mp4',
        position: [..._attachments, ..._pendingAttachments].length,
        createdAt: DateTime.now().toIso8601String(),
      );
      _pendingAttachments.add(attachment);
      if (_sourceType == 'text_note') _sourceType = 'voice';
      _insertAttachmentEmbed(attachment, durationSeconds: _voiceSeconds);
      _activeVoiceRecordingPath = null;
      _speechService.releaseSession(this);
      setState(() {
        _isSavingVoice = false;
        _voiceNeedsRetry = false;
        _voiceHasInsertedAudio = true;
        _voiceFailureMessage = null;
      });
      _onContentChanged();
    } catch (error) {
      _speechService.reportException(this, error);
      if (!mounted || !_speechService.ownsSession(this)) return;
      setState(() {
        _isSavingVoice = false;
        _voiceNeedsRetry = true;
        _voiceFailureMessage = '录音保存失败，请重试';
      });
    }
  }

  bool _selectionHasAttribute(String key) =>
      _quillController.getSelectionStyle().attributes.containsKey(key);

  bool _selectionHasBlockValue(String key, String? value) =>
      _quillController.getSelectionStyle().attributes[key]?.value == value;

  void _applyPanelFormat(VoidCallback action) {
    final selection = _quillController.selection;
    final previousIgnoreFocus = _quillController.ignoreFocusOnTextChange;
    final previousSkipKeyboard = _quillController.skipRequestKeyboard;
    _quillController
      ..ignoreFocusOnTextChange = true
      ..skipRequestKeyboard = true;
    try {
      action();
      if (!selection.isCollapsed &&
          selection.end <= _quillController.document.length - 1) {
        _quillController.skipRequestKeyboard = true;
        _quillController.updateSelection(selection, quill.ChangeSource.local);
      }
    } finally {
      _quillController
        ..ignoreFocusOnTextChange = previousIgnoreFocus
        ..skipRequestKeyboard = previousSkipKeyboard;
    }
    if (_activeToolPanel == _EditorToolPanel.format) setState(() {});
  }

  Widget _toolPanelShell({required String title, required Widget content}) {
    return Material(
      key: ValueKey(_activeToolPanel),
      color: _surface,
      elevation: 0,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: Container(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          border: Border.all(color: const Color(0xFFF0F0F1)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x18000000),
              blurRadius: 20,
              offset: Offset(0, -5),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFFD8D9DC),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              const SizedBox(height: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: _closeToolPanel,
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 48,
                          ),
                          icon: SvgPicture.asset(
                            'assets/icons/note_format/close.svg',
                            width: 24,
                            height: 24,
                            colorFilter: ColorFilter.mode(
                              _ink,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ],
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.56,
                      ),
                      child: SingleChildScrollView(child: content),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormatPanel() {
    final styles = <({String label, double size, String? header, bool quote})>[
      (label: '标题', size: 27, header: '1', quote: false),
      (label: '副标题', size: 19, header: '2', quote: false),
      (label: '小标题', size: 17, header: '3', quote: false),
      (label: '正文', size: 17, header: null, quote: false),
      (label: '注释', size: 15, header: null, quote: true),
    ];
    final currentHeader = _quillController
        .getSelectionStyle()
        .attributes[quill.Attribute.header.key]
        ?.value
        ?.toString();
    return _toolPanelShell(
      title: '格式',
      content: Column(
        children: [
          SizedBox(
            height: 64,
            child: Row(
              children: [
                for (final style in styles)
                  Expanded(
                    child: _StyleChoice(
                      label: style.label,
                      fontSize: style.size,
                      selected: style.quote
                          ? _selectionHasAttribute(
                              quill.Attribute.blockQuote.key,
                            )
                          : currentHeader == style.header &&
                                !_selectionHasAttribute(
                                  quill.Attribute.blockQuote.key,
                                ),
                      onTap: () => _applyPanelFormat(() {
                        if (style.quote) {
                          _applyBlock(quill.Attribute.blockQuote);
                        } else if (style.header == null) {
                          _applyBlock(null);
                        } else {
                          _applyBlock(switch (style.header) {
                            '1' => quill.Attribute.h1,
                            '2' => quill.Attribute.h2,
                            _ => quill.Attribute.h3,
                          });
                        }
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const _PanelDivider(),
          const SizedBox(height: 12),
          _TactileGroup(
            children: [
              Expanded(
                child: _tactileIcon(
                  'format_bold',
                  '加粗',
                  selected: _selectionHasAttribute(quill.Attribute.bold.key),
                  onTap: () => _applyPanelFormat(
                    () => _toggleAttribute(quill.Attribute.bold),
                  ),
                ),
              ),
              Expanded(
                child: _tactileIcon(
                  'format_italic',
                  '斜体',
                  selected: _selectionHasAttribute(quill.Attribute.italic.key),
                  onTap: () => _applyPanelFormat(
                    () => _toggleAttribute(quill.Attribute.italic),
                  ),
                ),
              ),
              Expanded(
                child: _tactileIcon(
                  'format_underlined',
                  '下划线',
                  selected: _selectionHasAttribute(
                    quill.Attribute.underline.key,
                  ),
                  onTap: () => _applyPanelFormat(
                    () => _toggleAttribute(quill.Attribute.underline),
                  ),
                ),
              ),
              Expanded(
                child: _tactileIcon(
                  'strikethrough_s',
                  '删除线',
                  selected: _selectionHasAttribute(
                    quill.Attribute.strikeThrough.key,
                  ),
                  onTap: () => _applyPanelFormat(
                    () => _toggleAttribute(quill.Attribute.strikeThrough),
                  ),
                ),
              ),
              Expanded(child: _buildFontSizePicker()),
            ],
          ),
          const SizedBox(height: 12),
          const _PanelDivider(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _TactileGroup(
                  children: [
                    Expanded(
                      child: _tactileIcon(
                        'format_list_bulleted',
                        '项目符号',
                        selected: _selectionHasBlockValue(
                          quill.Attribute.list.key,
                          quill.Attribute.ul.value,
                        ),
                        onTap: () => _applyPanelFormat(
                          () => _toggleAttribute(quill.Attribute.ul),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tactileIcon(
                        'format_list_numbered',
                        '编号列表',
                        selected: _selectionHasBlockValue(
                          quill.Attribute.list.key,
                          quill.Attribute.ol.value,
                        ),
                        onTap: () => _applyPanelFormat(
                          () => _toggleAttribute(quill.Attribute.ol),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TactileGroup(
                  children: [
                    Expanded(
                      child: _tactileIcon(
                        'format_indent_decrease',
                        '减少缩进',
                        onTap: () => _applyPanelFormat(
                          () => _quillController.indentSelection(false),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tactileIcon(
                        'format_indent_increase',
                        '增加缩进',
                        onTap: () => _applyPanelFormat(
                          () => _quillController.indentSelection(true),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _PanelDivider(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _TactileGroup(
                  children: [
                    Expanded(
                      child: _tactileIcon(
                        'format_align_left',
                        '左对齐',
                        selected: _selectionHasBlockValue(
                          quill.Attribute.align.key,
                          quill.Attribute.leftAlignment.value,
                        ),
                        onTap: () => _applyPanelFormat(
                          () => _quillController.formatSelection(
                            quill.Attribute.leftAlignment,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tactileIcon(
                        'format_align_center',
                        '居中',
                        selected: _selectionHasBlockValue(
                          quill.Attribute.align.key,
                          quill.Attribute.centerAlignment.value,
                        ),
                        onTap: () => _applyPanelFormat(
                          () => _quillController.formatSelection(
                            quill.Attribute.centerAlignment,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tactileIcon(
                        'format_align_right',
                        '右对齐',
                        selected: _selectionHasBlockValue(
                          quill.Attribute.align.key,
                          quill.Attribute.rightAlignment.value,
                        ),
                        onTap: () => _applyPanelFormat(
                          () => _quillController.formatSelection(
                            quill.Attribute.rightAlignment,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _tactileIcon(
                'highlight_marker',
                '高亮',
                colored: true,
                selected: _selectionHasAttribute(
                  quill.Attribute.background.key,
                ),
                onTap: () => _applyPanelFormat(
                  () => _toggleAttribute(
                    const quill.BackgroundAttribute('#F4D72C'),
                  ),
                ),
                width: 62,
              ),
              const SizedBox(width: 10),
              _buildTextColorPicker(),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _tactileIcon(
    String asset,
    String label, {
    required VoidCallback onTap,
    bool selected = false,
    bool colored = false,
    double width = double.infinity,
  }) => _TactileIconButton(
    asset: asset,
    label: label,
    onTap: onTap,
    selected: selected,
    colored: colored,
    width: width,
    ink: _ink,
  );

  Widget _buildFontSizePicker() {
    final rawSize = _quillController
        .getSelectionStyle()
        .attributes[quill.Attribute.size.key]
        ?.value;
    final currentSize = rawSize is num
        ? rawSize.round()
        : int.tryParse(rawSize?.toString() ?? '') ?? 16;
    return Tooltip(
      message: '字体大小',
      child: Semantics(
        button: true,
        label: '字体大小，当前$currentSize',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _openFontSizeMenu,
            child: SizedBox(
              key: _fontSizeAnchorKey,
              height: 54,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$currentSize',
                      style: TextStyle(color: _ink, fontSize: 18),
                    ),
                    const SizedBox(width: 4),
                    Transform.rotate(
                      angle: _fontSizeMenuOpen ? pi : 0,
                      child: SvgPicture.asset(
                        'assets/icons/note_format/arrow_drop_down.svg',
                        width: 18,
                        height: 18,
                        colorFilter: ColorFilter.mode(_ink, BlendMode.srcIn),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextColorPicker() {
    return Tooltip(
      message: '文字颜色',
      child: Semantics(
        button: true,
        label: '文字颜色',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _openTextColorMenu,
            child: SizedBox(
              key: _textColorAnchorKey,
              width: 62,
              height: 60,
              child: _TactileSurface(
                width: 62,
                height: 60,
                selected: _textColorMenuOpen,
                flat: true,
                child: SvgPicture.asset(
                  'assets/icons/note_format/color_palette.svg',
                  width: 27,
                  height: 27,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<T?> _showAnchoredFormatMenu<T>({
    required GlobalKey anchorKey,
    required double width,
    required double height,
    required List<PopupMenuEntry<T>> items,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final inheritedThemes = InheritedTheme.capture(
      from: context,
      to: navigator.context,
    );
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return showGeneralDialog<T>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      requestFocus: false,
      transitionDuration: transitionDuration,
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (menuContext, animation, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final anchorObject = anchorKey.currentContext?.findRenderObject();
            final overlayObject = navigator.overlay?.context.findRenderObject();
            if (anchorObject is! RenderBox || overlayObject is! RenderBox) {
              return const SizedBox.shrink();
            }
            final anchorOrigin = anchorObject.localToGlobal(
              Offset.zero,
              ancestor: overlayObject,
            );
            final anchorRect = anchorOrigin & anchorObject.size;
            final menuWidth = min(min(width, 280.0), constraints.maxWidth / 2);
            final safeTop = MediaQuery.viewPaddingOf(context).top + 8;
            final menuBottom = anchorRect.top - 8;
            final availableAboveAnchor = min(
              menuBottom - safeTop,
              constraints.maxHeight - safeTop - 8,
            );
            final menuHeight = min(height, max(0.0, availableAboveAnchor));
            final left = (anchorRect.right - menuWidth)
                .clamp(8.0, max(8.0, constraints.maxWidth - menuWidth - 8))
                .toDouble();
            final top = menuBottom - menuHeight;
            final menuAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return inheritedThemes.wrap(
              Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(menuContext).pop(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    width: menuWidth,
                    height: menuHeight,
                    child: FadeTransition(
                      opacity: menuAnimation,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.12,
                          end: 1,
                        ).animate(menuAnimation),
                        alignment: Alignment.bottomRight,
                        child: Material(
                          color: _surface,
                          elevation: 10,
                          shadowColor: Colors.black26,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: items,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  double _formatMenuWidth() {
    final overlayObject = Navigator.of(
      context,
      rootNavigator: true,
    ).overlay?.context.findRenderObject();
    final viewportWidth = overlayObject is RenderBox
        ? overlayObject.size.width
        : MediaQuery.sizeOf(context).width;
    return min(280.0, viewportWidth / 2);
  }

  Future<void> _openFontSizeMenu() async {
    if (_fontSizeMenuOpen) return;
    final rawSize = _quillController
        .getSelectionStyle()
        .attributes[quill.Attribute.size.key]
        ?.value;
    final currentSize = rawSize is num
        ? rawSize.round()
        : int.tryParse(rawSize?.toString() ?? '') ?? 16;
    setState(() => _fontSizeMenuOpen = true);
    int? selectedSize;
    try {
      final menuWidth = _formatMenuWidth();
      selectedSize = await _showAnchoredFormatMenu<int>(
        anchorKey: _fontSizeAnchorKey,
        width: menuWidth,
        height: _fontSizes.length * 54.0,
        items: [
          for (final size in _fontSizes)
            PopupMenuItem<int>(
              value: size,
              height: 54,
              padding: EdgeInsets.symmetric(
                horizontal: menuWidth < 120 ? 10 : 16,
              ),
              child: Container(
                height: 54,
                decoration: BoxDecoration(
                  border: size == _fontSizes.last
                      ? null
                      : Border(bottom: BorderSide(color: _divider)),
                ),
                child: Row(
                  children: [
                    Text('$size', style: TextStyle(color: _ink, fontSize: 18)),
                    const Spacer(),
                    if (size == currentSize)
                      const Icon(
                        Icons.check,
                        color: _formatMenuAccent,
                        size: 22,
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    } finally {
      if (mounted) setState(() => _fontSizeMenuOpen = false);
    }
    if (selectedSize != null && mounted) {
      _applyPanelFormat(
        () => _quillController.formatSelection(
          quill.SizeAttribute('$selectedSize'),
        ),
      );
    }
  }

  Future<void> _openTextColorMenu() async {
    if (_textColorMenuOpen) return;
    const colors = <({String label, String value, Color swatch})>[
      (label: '默认', value: '', swatch: Color(0xFF191919)),
      (label: '灰色', value: '#757575', swatch: Color(0xFF757575)),
      (label: '红色', value: '#DA382B', swatch: Color(0xFFDA382B)),
      (label: '橙色', value: '#EB6E00', swatch: Color(0xFFEB6E00)),
      (label: '黄色', value: '#DC9902', swatch: Color(0xFFDC9902)),
      (label: '绿色', value: '#019910', swatch: Color(0xFF019910)),
      (label: '蓝色', value: '#0166FF', swatch: Color(0xFF0166FF)),
    ];
    final currentColor =
        _quillController
            .getSelectionStyle()
            .attributes[quill.Attribute.color.key]
            ?.value
            ?.toString() ??
        '';
    setState(() => _textColorMenuOpen = true);
    String? selectedColor;
    try {
      final menuWidth = _formatMenuWidth();
      final compactMenu = menuWidth < 150;
      selectedColor = await _showAnchoredFormatMenu<String>(
        anchorKey: _textColorAnchorKey,
        width: menuWidth,
        height: colors.length * 58.0,
        items: [
          for (final color in colors)
            PopupMenuItem<String>(
              value: color.value,
              height: 58,
              padding: EdgeInsets.symmetric(horizontal: compactMenu ? 4 : 16),
              child: Container(
                height: 58,
                decoration: BoxDecoration(
                  border: color == colors.last
                      ? null
                      : Border(bottom: BorderSide(color: _divider)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(backgroundColor: color.swatch, radius: 13),
                    SizedBox(width: compactMenu ? 4 : 14),
                    Expanded(
                      child: Text(
                        color.label,
                        style: TextStyle(
                          color: _ink,
                          fontSize: compactMenu ? 15 : 17,
                        ),
                      ),
                    ),
                    if (currentColor.toUpperCase() == color.value.toUpperCase())
                      Icon(
                        Icons.check,
                        color: _formatMenuAccent,
                        size: compactMenu ? 16 : 22,
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    } finally {
      if (mounted) setState(() => _textColorMenuOpen = false);
    }
    if (selectedColor != null && mounted) {
      _applyPanelFormat(
        () => _quillController.formatSelection(
          quill.ColorAttribute(selectedColor!.isEmpty ? null : selectedColor),
        ),
      );
    }
  }

  Widget _buildAddPanel() {
    return _toolPanelShell(
      title: '添加内容',
      content: Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 4),
        child: Row(
          children: [
            Expanded(
              child: _AddPanelAction(
                asset: 'image',
                label: '图片',
                onTap: () {
                  unawaited(_closeToolPanel());
                  unawaited(_pickImageAttachments(camera: false));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _AddPanelAction(
                asset: 'add_a_photo',
                label: '拍照上传',
                onTap: () {
                  unawaited(_closeToolPanel());
                  unawaited(_pickImageAttachments(camera: true));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _AddPanelAction(
                asset: 'attach_file',
                label: '文件上传',
                onTap: () {
                  unawaited(_closeToolPanel());
                  unawaited(_pickFileAttachments());
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoicePanel() {
    final minutes = (_voiceSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_voiceSeconds % 60).toString().padLeft(2, '0');
    final active = _isListening || _isStartingVoice || _isSavingVoice;
    return _toolPanelShell(
      title: '语音输入',
      content: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isListening) ...[
              const SizedBox(height: 5),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final level in _voiceLevels)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 100),
                        width: 4,
                        height: 9 + level * 32,
                        decoration: BoxDecoration(
                          color: _isVoicePaused
                              ? const Color(0xFFB9BBC0)
                              : const Color(0xFF33363A),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$minutes:$seconds',
                style: TextStyle(
                  color: _ink,
                  fontSize: 24,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _isVoicePaused ? '已暂停' : '正在录音 · 保存为正文音频',
                style: TextStyle(color: _muted, fontSize: 13),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _TactileTextButton(
                      label: _isVoicePaused ? '继续录音' : '暂停',
                      iconAsset: _isVoicePaused ? 'play_arrow' : 'pause',
                      onTap: _pauseOrResumeChatVoice,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TactileTextButton(
                      label: '完成并插入正文',
                      iconAsset: 'stop',
                      onTap: _stopChatVoice,
                    ),
                  ),
                ],
              ),
            ] else if (_isSavingVoice || _isStartingVoice) ...[
              const SizedBox(height: 20),
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  color: _accent,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _isStartingVoice ? '正在准备麦克风…' : '正在保存录音…',
                style: TextStyle(color: _muted),
              ),
              const SizedBox(height: 20),
            ] else if (_voiceNeedsRetry) ...[
              const SizedBox(height: 8),
              Text(
                _voiceFailureMessage ?? '录音保存失败，请重新录制',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _TactileTextButton(
                      label: '重新录音',
                      iconAsset: 'mic',
                      onTap: _startChatVoice,
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 7),
              SvgPicture.asset(
                'assets/icons/note_format/mic.svg',
                width: 30,
                height: 30,
                colorFilter: ColorFilter.mode(_muted, BlendMode.srcIn),
              ),
              const SizedBox(height: 8),
              if (_voiceHasInsertedAudio)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '已插入正文 · 点击音频块可播放',
                    style: TextStyle(color: _muted),
                  ),
                ),
              _TactileTextButton(
                label: _voiceHasInsertedAudio ? '继续录音' : '开始录音',
                iconAsset: 'mic',
                onTap: _startChatVoice,
                fullWidth: true,
              ),
            ],
            if (!active && !_voiceNeedsRetry) const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveToolPanel() {
    return switch (_activeToolPanel) {
      _EditorToolPanel.format => _buildFormatPanel(),
      _EditorToolPanel.voice => _buildVoicePanel(),
      _EditorToolPanel.add => _buildAddPanel(),
      null => const SizedBox.shrink(key: ValueKey('no-tool-panel')),
    };
  }

  Future<void> _showFormatSheet() async {
    if (widget.isBottomSheet) {
      _showToolPanel(_EditorToolPanel.format);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void run(VoidCallback action) {
            action();
            setSheetState(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 18,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SheetHeader(
                    title: '文字格式',
                    color: _ink,
                    onClose: () => Navigator.pop(sheetContext),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _FormatChip(
                        label: '标题',
                        onTap: () => run(() => _applyBlock(quill.Attribute.h1)),
                        color: _accent,
                      ),
                      _FormatChip(
                        label: '副标题',
                        onTap: () => run(() => _applyBlock(quill.Attribute.h2)),
                        color: _accent,
                      ),
                      _FormatChip(
                        label: '小标题',
                        onTap: () => run(() => _applyBlock(quill.Attribute.h3)),
                        color: _accent,
                      ),
                      _FormatChip(
                        label: '正文',
                        onTap: () => run(() => _applyBlock(null)),
                        color: _accent,
                      ),
                      _FormatChip(
                        label: '注释',
                        onTap: () =>
                            run(() => _applyBlock(quill.Attribute.blockQuote)),
                        color: _accent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 5,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.08,
                    children: [
                      _ToolTile(
                        icon: Icons.format_bold,
                        tooltip: '加粗',
                        onTap: () =>
                            run(() => _toggleAttribute(quill.Attribute.bold)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_italic,
                        tooltip: '斜体',
                        onTap: () =>
                            run(() => _toggleAttribute(quill.Attribute.italic)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_underlined,
                        tooltip: '下划线',
                        onTap: () => run(
                          () => _toggleAttribute(quill.Attribute.underline),
                        ),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_strikethrough,
                        tooltip: '删除线',
                        onTap: () => run(
                          () => _toggleAttribute(quill.Attribute.strikeThrough),
                        ),
                        color: _ink,
                      ),
                      _FontSizeButton(
                        values: _fontSizes,
                        color: _ink,
                        accent: _accent,
                        onSelected: (size) => run(
                          () => _quillController.formatSelection(
                            quill.SizeAttribute('$size'),
                          ),
                        ),
                      ),
                      _ToolTile(
                        icon: Icons.format_list_bulleted,
                        tooltip: '项目符号',
                        onTap: () =>
                            run(() => _toggleAttribute(quill.Attribute.ul)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_list_numbered,
                        tooltip: '编号列表',
                        onTap: () =>
                            run(() => _toggleAttribute(quill.Attribute.ol)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_indent_increase,
                        tooltip: '增加缩进',
                        onTap: () =>
                            run(() => _quillController.indentSelection(true)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_indent_decrease,
                        tooltip: '减少缩进',
                        onTap: () =>
                            run(() => _quillController.indentSelection(false)),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_align_left,
                        tooltip: '左对齐',
                        onTap: () => run(
                          () => _quillController.formatSelection(
                            quill.Attribute.leftAlignment,
                          ),
                        ),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_align_center,
                        tooltip: '居中',
                        onTap: () => run(
                          () => _quillController.formatSelection(
                            quill.Attribute.centerAlignment,
                          ),
                        ),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.format_align_right,
                        tooltip: '右对齐',
                        onTap: () => run(
                          () => _quillController.formatSelection(
                            quill.Attribute.rightAlignment,
                          ),
                        ),
                        color: _ink,
                      ),
                      _ToolTile(
                        icon: Icons.border_color_outlined,
                        tooltip: '高亮',
                        onTap: () => run(
                          () => _quillController.formatSelection(
                            const quill.BackgroundAttribute('#FFF1A8'),
                          ),
                        ),
                        color: _ink,
                      ),
                      _TextColorButton(
                        color: _ink,
                        onSelected: (value) => run(
                          () => _quillController.formatSelection(
                            quill.ColorAttribute(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAiSheet() async {
    const actions = <({String label, IconData icon})>[
      (label: '智能排版', icon: Icons.auto_fix_high_outlined),
      (label: '语句修正', icon: Icons.spellcheck_outlined),
      (label: '润色', icon: Icons.palette_outlined),
      (label: '续写', icon: Icons.edit_note_outlined),
      (label: '扩充篇幅', icon: Icons.unfold_more_outlined),
      (label: '缩短篇幅', icon: Icons.unfold_less_outlined),
      (label: '正式化', icon: Icons.business_center_outlined),
      (label: '口语化', icon: Icons.sentiment_satisfied_alt_outlined),
    ];
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetHeader(
              title: 'AI 笔记助手',
              color: _ink,
              onClose: () => Navigator.pop(sheetContext),
            ),
            Text(
              '有选中文字时只处理选区，否则处理整篇正文',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 2.35,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: actions.length,
              itemBuilder: (_, index) {
                final action = actions[index];
                return Material(
                  color: _background,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _runAiAction(action.label);
                    },
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        Icon(action.icon, color: _accent),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            action.label,
                            style: TextStyle(
                              color: _ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAiAction(String action) async {
    final selection = _quillController.selection;
    final wholeText = _plainText();
    final hasSelection = selection.isValid && !selection.isCollapsed;
    final start = hasSelection ? selection.start : 0;
    final length = hasSelection
        ? selection.end - selection.start
        : wholeText.length;
    final source = hasSelection
        ? wholeText.substring(selection.start, selection.end)
        : wholeText;
    if (source.trim().isEmpty) {
      AppToast.show(context, '请先输入需要处理的文字');
      return;
    }
    setState(() => _isProcessing = true);
    try {
      final result = await _ai.rewriteText(action: action, text: source);
      if (!mounted) return;
      _quillController.replaceText(
        start,
        length,
        result,
        TextSelection.collapsed(offset: start),
      );
      AppToast.show(context, '已完成“$action”，可使用撤销恢复');
    } catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          error is AiException ? error.message : 'AI处理失败，请稍后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _toggleVoice() async {
    if (_isStartingVoice || _isTranscribing) return;
    if (_isListening) {
      _voiceTimer?.cancel();
      setState(() {
        _isListening = false;
        _isTranscribing = true;
      });
      try {
        final words = await _speechService.stopAndRecognize(this);
        if (!mounted || !_speechService.ownsSession(this)) return;
        if (words.isEmpty) {
          AppToast.show(context, '没有检测到有效语音，本次未插入；请说话后松开重试');
          return;
        }
        _quillController.replaceText(
          _voiceInsertionStart,
          0,
          words,
          TextSelection.collapsed(offset: _voiceInsertionStart + words.length),
        );
        _speechService.releaseSession(this);
      } catch (error) {
        _speechService.reportException(this, error);
        if (mounted) {
          AppToast.show(context, _speechService.messageForException(error));
        }
      } finally {
        await _speechService.cancelSession(this);
        if (mounted) setState(() => _isTranscribing = false);
      }
      return;
    }
    if (!_speechService.acquireSession(this)) {
      AppToast.show(context, '上一轮语音识别仍在结束，请稍后重试');
      return;
    }
    setState(() => _isStartingVoice = true);
    try {
      await _speechService.initialize(owner: this);
      if (!mounted) {
        unawaited(_speechService.cancelSession(this));
        return;
      }
      _voiceInsertionStart = _quillController.selection.start.clamp(
        0,
        _quillController.document.length - 1,
      );
      await _speechService.startRecording(owner: this);
      if (!mounted || !_speechService.ownsSession(this)) return;
      setState(() {
        _isStartingVoice = false;
        _isListening = true;
        _voiceSeconds = 0;
        _sourceType = _sourceType == 'text_note' ? 'voice' : _sourceType;
      });
      _voiceTimer?.cancel();
      _voiceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isListening) {
          setState(() => _voiceSeconds++);
        }
      });
    } catch (error) {
      _voiceTimer?.cancel();
      _speechService.reportException(this, error);
      await _speechService.cancelSession(this);
      if (mounted) {
        setState(() {
          _isStartingVoice = false;
          _isListening = false;
        });
        AppToast.show(context, _speechService.messageForException(error));
      }
    }
  }

  Future<void> _showVoiceSheet() async {
    if (widget.isBottomSheet) {
      _showToolPanel(_EditorToolPanel.voice);
      return;
    }
    Timer? refreshTimer;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: _surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          refreshTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
            if (sheetContext.mounted) setSheetState(() {});
          });
          final minutes = (_voiceSeconds ~/ 60).toString().padLeft(2, '0');
          final seconds = (_voiceSeconds % 60).toString().padLeft(2, '0');
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SheetHeader(
                  title: '语音输入',
                  color: _ink,
                  onClose: () => Navigator.pop(sheetContext),
                ),
                const SizedBox(height: 18),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: _isListening
                        ? Colors.redAccent.withValues(alpha: 0.12)
                        : _accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isListening ? Icons.graphic_eq : Icons.mic_none,
                    size: 38,
                    color: _isListening ? Colors.redAccent : _accent,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$minutes:$seconds',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _isTranscribing
                      ? '正在本机识别…'
                      : _isStartingVoice
                      ? '正在准备麦克风…'
                      : _isListening
                      ? '正在录音；停止后本机识别并插入光标处'
                      : '松开后在本机识别，文字插入光标处',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _isStartingVoice || _isTranscribing
                        ? null
                        : () async {
                            final operation = _toggleVoice();
                            if (sheetContext.mounted) setSheetState(() {});
                            await operation;
                            if (sheetContext.mounted) setSheetState(() {});
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: _isListening
                          ? Colors.redAccent
                          : _accent,
                    ),
                    icon: _isTranscribing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(_isListening ? Icons.stop : Icons.mic),
                    label: Text(
                      _isTranscribing
                          ? '本机识别中'
                          : _isStartingVoice
                          ? '正在准备麦克风'
                          : _isListening
                          ? '停止录音'
                          : '开始录音',
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    refreshTimer?.cancel();
    if (_isStartingVoice || _isListening || _isTranscribing) {
      _voiceTimer?.cancel();
      await _speechService.cancelSession(this);
      if (mounted) {
        setState(() {
          _isStartingVoice = false;
          _isListening = false;
          _isTranscribing = false;
        });
      }
    }
  }

  Future<void> _showAddSheet() async {
    if (widget.isBottomSheet) {
      _showToolPanel(_EditorToolPanel.add);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHeader(
              title: '添加内容',
              color: _ink,
              onClose: () => Navigator.pop(sheetContext),
            ),
            _AddTile(
              icon: Icons.format_quote_outlined,
              title: '引用',
              subtitle: '插入引用段落',
              color: _ink,
              onTap: () {
                Navigator.pop(sheetContext);
                _insertText('引用内容\n');
                _quillController.formatSelection(quill.Attribute.blockQuote);
              },
            ),
            _AddTile(
              icon: Icons.image_outlined,
              title: '图片',
              subtitle: '添加一张图片作为笔记来源',
              color: _ink,
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImageAttachment();
              },
            ),
            _AddTile(
              icon: Icons.horizontal_rule,
              title: '分隔线',
              subtitle: '分隔不同主题的内容',
              color: _ink,
              onTap: () {
                Navigator.pop(sheetContext);
                _insertText('\n────────────\n');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<File> _persistImage(XFile image) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'note_sources'));
    await directory.create(recursive: true);
    final extension = p.extension(image.path).isEmpty
        ? '.jpg'
        : p.extension(image.path);
    final target = p.join(
      directory.path,
      'source_${DateTime.now().microsecondsSinceEpoch}$extension',
    );
    return File(image.path).copy(target);
  }

  Future<void> _pickImageAttachments({required bool camera}) async {
    try {
      final images = camera
          ? <XFile?>[await _picker.pickImage(source: ImageSource.camera)]
          : await _picker.pickMultiImage();
      for (final image in images.whereType<XFile>()) {
        final attachment = await _persistAttachment(
          name: p.basename(image.name.isEmpty ? image.path : image.name),
          bytes: image.openRead(),
          mimeType: image.mimeType,
        );
        if (!mounted) {
          await _deleteStoredAttachment(attachment.relativePath);
          return;
        }
        setState(() => _pendingAttachments.add(attachment));
        _insertAttachmentEmbed(attachment);
        _onContentChanged();
      }
    } catch (_) {
      if (mounted) AppToast.show(context, camera ? '照片添加失败' : '图片添加失败');
    }
  }

  Future<void> _pickFileAttachments() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) return;
      for (final picked in files) {
        final stream = picked.readAsByteStream();
        final attachment = await _persistAttachment(
          name: picked.name,
          bytes: stream,
          mimeType: _mimeTypeForName(picked.name),
        );
        if (!mounted) {
          await _deleteStoredAttachment(attachment.relativePath);
          return;
        }
        setState(() => _pendingAttachments.add(attachment));
        _insertAttachmentEmbed(attachment);
        _onContentChanged();
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '文件添加失败，请重试');
    }
  }

  Future<NoteAttachment> _persistAttachment({
    required String name,
    required Stream<List<int>> bytes,
    String? mimeType,
  }) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'note_attachments'));
    await directory.create(recursive: true);
    final extension = p
        .extension(name)
        .replaceAll(RegExp(r'[^.a-zA-Z0-9]'), '');
    final uniqueName =
        'attachment_${DateTime.now().microsecondsSinceEpoch}_'
        '${Random.secure().nextInt(1 << 32).toRadixString(16)}$extension';
    final relativePath = p.join('note_attachments', uniqueName);
    final target = File(p.join(documents.path, relativePath));
    final sink = target.openWrite();
    try {
      await sink.addStream(bytes);
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      rethrow;
    }
    final mime = mimeType ?? _mimeTypeForName(name);
    return NoteAttachment(
      name: name.isEmpty ? '附件' : name,
      relativePath: relativePath,
      kind: _attachmentKind(mime, extension),
      mimeType: mime,
      position:
          [..._attachments, ..._pendingAttachments].fold<int>(
            -1,
            (largest, item) =>
                largest > item.position ? largest : item.position,
          ) +
          1,
      createdAt: DateTime.now().toIso8601String(),
    );
  }

  List<NoteAttachment> get _nonInlineAttachments {
    final inlinePaths = _inlineAttachmentPaths();
    return [..._attachments, ..._pendingAttachments]
        .where((attachment) => !inlinePaths.contains(attachment.relativePath))
        .toList(growable: false);
  }

  Future<(String, String)> _createVoiceRecordingFile() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'note_attachments'));
    await directory.create(recursive: true);
    final name =
        'voice_${DateTime.now().microsecondsSinceEpoch}_'
        '${Random.secure().nextInt(1 << 32).toRadixString(16)}.m4a';
    final relativePath = p.join('note_attachments', name);
    return (relativePath, p.join(documents.path, relativePath));
  }

  void _insertAttachmentEmbed(
    NoteAttachment attachment, {
    int? durationSeconds,
  }) {
    final maximum = max(0, _quillController.document.length - 1);
    final insertionSelection =
        _mediaInsertionSelection ?? _captureMediaInsertionSelection();
    final offset = insertionSelection.extentOffset.clamp(0, maximum);
    final data = <String, Object?>{
      'relativePath': attachment.relativePath,
      'name': attachment.name,
      'kind': attachment.kind,
      'mimeType': attachment.mimeType,
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
    };
    _quillController.skipRequestKeyboard = true;
    _quillController.replaceText(
      offset,
      0,
      quill.BlockEmbed.custom(
        quill.CustomBlockEmbed('note_attachment', jsonEncode(data)),
      ),
      TextSelection.collapsed(offset: offset + 1),
    );
    _mediaInsertionSelection = TextSelection.collapsed(offset: offset + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _quillController.skipRequestKeyboard = false;
    });
  }

  Set<String> _inlineAttachmentPaths() {
    final paths = <String>{};
    for (final operation in _quillController.document.toDelta().toJson()) {
      if (operation is! Map) continue;
      final insert = operation['insert'];
      if (insert is! Map || insert['custom'] is! String) continue;
      try {
        final custom = quill.CustomBlockEmbed.fromJsonString(
          insert['custom'] as String,
        );
        if (custom.type != 'note_attachment' || custom.data is! String) {
          continue;
        }
        final payload = jsonDecode(custom.data as String);
        if (payload is Map && payload['relativePath'] is String) {
          paths.add(payload['relativePath'] as String);
        }
      } catch (_) {
        // Unknown custom embeds remain untouched for forward compatibility.
      }
    }
    return paths;
  }

  void _removeInlineAttachmentEmbed(String relativePath) {
    final offsets = <int>[];
    var offset = 0;
    for (final operation in _quillController.document.toDelta().toJson()) {
      if (operation is! Map) continue;
      final insert = operation['insert'];
      if (insert is String) {
        offset += insert.length;
        continue;
      }
      if (insert is Map && insert['custom'] is String) {
        try {
          final custom = quill.CustomBlockEmbed.fromJsonString(
            insert['custom'] as String,
          );
          final payload = custom.data is String
              ? jsonDecode(custom.data as String)
              : null;
          if (custom.type == 'note_attachment' &&
              payload is Map &&
              payload['relativePath'] == relativePath) {
            offsets.add(offset);
          }
        } catch (_) {}
      }
      offset++;
    }
    for (final index in offsets.reversed) {
      _quillController.replaceText(
        index,
        1,
        '',
        TextSelection.collapsed(offset: index),
      );
    }
  }

  String? _mimeTypeForName(String name) {
    return switch (p.extension(name).toLowerCase()) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.pdf' => 'application/pdf',
      '.doc' => 'application/msword',
      '.docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.txt' => 'text/plain',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.wav' => 'audio/wav',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      _ => null,
    };
  }

  String _attachmentKind(String? mime, String extension) {
    if (mime?.startsWith('image/') ?? false) return 'image';
    if (mime?.startsWith('audio/') ?? false) return 'audio';
    if (mime?.startsWith('video/') ?? false) return 'video';
    if (mime == 'application/pdf' || extension.toLowerCase() == '.pdf') {
      return 'pdf';
    }
    return 'file';
  }

  Future<String> _attachmentAbsolutePath(String relativePath) async {
    final documents = await getApplicationDocumentsDirectory();
    final root = p.normalize(documents.path);
    final target = p.normalize(p.join(root, relativePath));
    final fromRoot = p.relative(target, from: root);
    if (p.isAbsolute(fromRoot) ||
        fromRoot == '..' ||
        fromRoot.startsWith('..${p.separator}')) {
      throw StateError('附件路径无效');
    }
    return target;
  }

  Future<void> _deleteStoredAttachment(String relativePath) async {
    try {
      final file = File(await _attachmentAbsolutePath(relativePath));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A failed cleanup leaves the database record intact when applicable.
    }
  }

  Future<void> _removeAttachment(NoteAttachment attachment) async {
    try {
      final isPending = _pendingAttachments.any(
        (item) => item.relativePath == attachment.relativePath,
      );
      if (isPending && _pendingSave != null) {
        if (mounted) AppToast.show(context, '附件保存中，请稍后移除');
        return;
      }
      if (isPending) {
        setState(() {
          _pendingAttachments.removeWhere(
            (item) => item.relativePath == attachment.relativePath,
          );
        });
      } else if (attachment.id != null) {
        final removed = await _db.deleteNoteAttachment(attachment.id!);
        if (!removed) throw StateError('附件记录不存在');
        if (mounted) {
          setState(() {
            _attachments = _attachments
                .where((item) => item.id != attachment.id)
                .toList(growable: false);
          });
        }
      }
      _removeInlineAttachmentEmbed(attachment.relativePath);
      await _deleteStoredAttachment(attachment.relativePath);
      if (mounted) _onContentChanged();
    } catch (_) {
      if (mounted) AppToast.show(context, '附件移除失败，请重试');
    }
  }

  Future<void> _openAttachment(NoteAttachment attachment) async {
    await _openAttachmentPath(attachment.relativePath);
  }

  Future<void> _openInlineAttachment(String relativePath) async {
    await _openAttachmentPath(relativePath);
  }

  bool _isInlineAudioPlaying(String relativePath) =>
      _activeInlineAudioPath == relativePath &&
      _inlineAudioState == PlayerState.playing;

  Duration _inlineAudioPositionFor(String relativePath) =>
      _activeInlineAudioPath == relativePath
      ? _inlineAudioPosition
      : Duration.zero;

  Duration _inlineAudioDurationFor(String relativePath) =>
      _activeInlineAudioPath == relativePath
      ? _inlineAudioDuration
      : Duration.zero;

  Future<void> _toggleInlineAudio(String relativePath) async {
    try {
      final path = await _attachmentAbsolutePath(relativePath);
      if (!await File(path).exists()) {
        if (mounted) AppToast.show(context, '录音文件已不存在');
        return;
      }
      if (_activeInlineAudioPath == relativePath &&
          _inlineAudioState == PlayerState.playing) {
        await _inlineAudioPlayer.pause();
        return;
      }
      if (_activeInlineAudioPath == relativePath &&
          _inlineAudioState == PlayerState.paused) {
        await _inlineAudioPlayer.resume();
        return;
      }
      await _inlineAudioPlayer.stop();
      if (!mounted) return;
      setState(() {
        _activeInlineAudioPath = relativePath;
        _inlineAudioPosition = Duration.zero;
        _inlineAudioDuration = Duration.zero;
      });
      await _inlineAudioPlayer.play(DeviceFileSource(path));
    } catch (_) {
      if (mounted) AppToast.show(context, '录音播放失败，请重试');
    }
  }

  Future<void> _openAttachmentPath(String relativePath) async {
    try {
      final path = await _attachmentAbsolutePath(relativePath);
      if (!await File(path).exists()) {
        if (mounted) AppToast.show(context, '文件已不存在');
        return;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        final result = await OpenFilex.open(path);
        if (result.type != ResultType.done && mounted) {
          AppToast.show(
            context,
            result.message == 'done' ? '没有可打开此文件的应用' : result.message,
          );
        }
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else if (mounted) {
        AppToast.show(context, '此设备暂不支持打开附件');
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '文件打开失败');
    }
  }

  Future<void> _removeInlineAttachment(String relativePath) async {
    NoteAttachment? attachment;
    for (final item in [..._attachments, ..._pendingAttachments]) {
      if (item.relativePath == relativePath) {
        attachment = item;
        break;
      }
    }
    if (attachment != null) {
      await _removeAttachment(attachment);
      return;
    }
    _removeInlineAttachmentEmbed(relativePath);
    _onContentChanged();
  }

  Future<void> _pickImageAttachment() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 95,
      );
      if (picked == null) return;
      final file = await _persistImage(picked);
      if (!mounted) return;
      setState(() {
        _sourcePhotoPath = file.path;
        if (_sourceType == 'text_note') _sourceType = 'image_attachment';
      });
      _onContentChanged();
      AppToast.show(context, '图片已添加');
    } catch (_) {
      if (mounted) AppToast.show(context, '图片添加失败');
    }
  }

  Future<void> _selectNotebook() async {
    if (_notebooks.isEmpty) return;
    final currentId = _notebookId;
    final selected = await showModalBottomSheet<Notebook>(
      context: context,
      useSafeArea: true,
      backgroundColor: _surface,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHeader(
              title: '保存到笔记本',
              color: _ink,
              onClose: () => Navigator.pop(sheetContext),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: _notebooks
                    .map(
                      (item) => ListTile(
                        minTileHeight: 56,
                        leading: Container(
                          width: 34,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: NotebookTheme.coverGradient(
                              item.coverIndex,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        title: Text(item.name, style: TextStyle(color: _ink)),
                        subtitle: Text(
                          item.category,
                          style: TextStyle(color: _muted),
                        ),
                        trailing: item.id == currentId
                            ? Icon(Icons.check, color: _accent)
                            : null,
                        onTap: () => Navigator.pop(sheetContext, item),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (selected == null || selected.id == currentId) return;
    if (_note?.id == null) {
      setState(() {
        _notebookId = selected.id!;
        _notebook = selected;
      });
      _onContentChanged();
      AppToast.show(context, '将保存到“${selected.name}”');
      return;
    }
    final saved = await _save(force: true);
    if (saved?.id == null) return;
    try {
      await _db.moveNoteToNotebook(saved!.id!, selected.id!);
      _notebookId = selected.id!;
      _note = saved.copyWith(notebookId: selected.id);
      if (!mounted) return;
      setState(() => _notebook = selected);
      _lastSavedSignature = _signature();
      AppToast.show(context, '已移动到“${selected.name}”');
    } catch (_) {
      if (mounted) AppToast.show(context, '移动失败，请重试');
    }
  }

  Future<void> _duplicate() async {
    final saved = await _save(force: true);
    if (saved == null) return;
    final sourceNoteId = saved.id;
    if (sourceNoteId == null) return;
    final now = DateTime.now().toIso8601String();
    final copiedAttachments = <NoteAttachment>[];
    final copiedPaths = <String, String>{};
    try {
      final sourceAttachments = await _db.queryNoteAttachments(sourceNoteId);
      for (var index = 0; index < sourceAttachments.length; index++) {
        final source = sourceAttachments[index];
        final sourceFile = File(
          await _attachmentAbsolutePath(source.relativePath),
        );
        if (!await sourceFile.exists()) {
          throw StateError('附件文件已不存在：${source.name}');
        }
        final attachmentCopy = await _persistAttachment(
          name: source.name,
          bytes: sourceFile.openRead(),
          mimeType: source.mimeType,
        );
        copiedAttachments.add(attachmentCopy.copyWith(position: index));
        copiedPaths[source.relativePath] = attachmentCopy.relativePath;
      }
      final copy = saved.copyWith(
        id: null,
        title: '${saved.title} 副本',
        contentDelta: _deltaWithCopiedAttachmentPaths(
          saved.contentDelta,
          copiedPaths,
        ),
        createdAt: now,
        updatedAt: now,
      );
      final map = copy.toMap()..remove('id');
      final id = await _db.insertNoteWithCopiedChatSources(
        Note.fromMap(map),
        sourceNoteId: sourceNoteId,
        copiedAttachments: copiedAttachments,
      );
      if (mounted) AppToast.show(context, '已创建副本 #$id');
    } catch (_) {
      for (final attachment in copiedAttachments) {
        await _deleteStoredAttachment(attachment.relativePath);
      }
      if (mounted) AppToast.show(context, '复制笔记失败，请重试');
    }
  }

  String _deltaWithCopiedAttachmentPaths(
    String encodedDelta,
    Map<String, String> copiedPaths,
  ) {
    if (copiedPaths.isEmpty || encodedDelta.trim().isEmpty) {
      return encodedDelta;
    }
    try {
      final decoded = jsonDecode(encodedDelta);
      if (decoded is! List) return encodedDelta;
      final rewritten = decoded.map((operation) {
        if (operation is! Map) return operation;
        final insert = operation['insert'];
        if (insert is! Map || insert['custom'] is! String) return operation;
        try {
          final custom = quill.CustomBlockEmbed.fromJsonString(
            insert['custom'] as String,
          );
          if (custom.type != 'note_attachment' || custom.data is! String) {
            return operation;
          }
          final payload = jsonDecode(custom.data as String);
          if (payload is! Map) return operation;
          final oldPath = payload['relativePath'];
          final newPath = copiedPaths[oldPath];
          if (newPath == null) return operation;
          final nextPayload = Map<String, dynamic>.from(payload)
            ..['relativePath'] = newPath;
          final nextCustom = quill.CustomBlockEmbed(
            'note_attachment',
            jsonEncode(nextPayload),
          ).toJsonString();
          return {
            ...Map<String, dynamic>.from(operation),
            'insert': {
              ...Map<String, dynamic>.from(insert),
              'custom': nextCustom,
            },
          };
        } catch (_) {
          return operation;
        }
      }).toList();
      return jsonEncode(rewritten);
    } catch (_) {
      return encodedDelta;
    }
  }

  Future<void> _delete() async {
    final note = _note;
    if (note?.id == null) {
      setState(() => _allowPop = true);
      if (mounted) {
        Navigator.pop(context, const NoteEditorResult.unchanged());
      }
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这篇笔记？'),
        content: const Text('删除后将不再显示在笔记本目录中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: NotebookTheme.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _db.softDelete(note!.id!);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.pop(context, NoteEditorResult.deleted(note));
  }

  Future<void> _showMoreMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                secondary: widget.isBottomSheet
                    ? _ChatNoteIcon(_nightMode ? 'sun' : 'moon', color: _ink)
                    : Icon(
                        _nightMode
                            ? Icons.dark_mode
                            : Icons.light_mode_outlined,
                        color: _ink,
                      ),
                title: Text('夜间模式', style: TextStyle(color: _ink)),
                subtitle: Text(
                  _nightMode ? '当前：夜间阅读风格' : '当前：纯净便签风格',
                  style: TextStyle(color: _muted),
                ),
                value: _nightMode,
                activeThumbColor: _accent,
                onChanged: (value) {
                  Navigator.pop(sheetContext);
                  setState(() => _nightMode = value);
                },
              ),
              if (widget.isBottomSheet) ...[
                _MoreTile(
                  icon: Icons.undo,
                  svgAsset: 'arrow-counter-clockwise',
                  label: '撤销',
                  color: _ink,
                  enabled: _quillController.hasUndo,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (_quillController.hasUndo) {
                      setState(_quillController.undo);
                    }
                  },
                ),
                _MoreTile(
                  icon: Icons.redo,
                  svgAsset: 'arrow-clockwise',
                  label: '重做',
                  color: _ink,
                  enabled: _quillController.hasRedo,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (_quillController.hasRedo) {
                      setState(_quillController.redo);
                    }
                  },
                ),
                Divider(height: 1, color: _divider),
              ],
              _MoreTile(
                icon: Icons.drive_file_move_outline,
                svgAsset: widget.isBottomSheet ? 'book-open-text' : null,
                label: '移动到其他笔记本',
                color: _ink,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _selectNotebook();
                },
              ),
              _MoreTile(
                icon: Icons.ios_share_outlined,
                svgAsset: widget.isBottomSheet ? 'share-network' : null,
                label: '分享',
                color: _ink,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final note = await _save(force: true);
                  if (note != null && mounted) {
                    await NoteActions.share(context, note);
                  }
                },
              ),
              _MoreTile(
                icon: Icons.description_outlined,
                svgAsset: widget.isBottomSheet ? 'export' : null,
                label: '导出 Markdown',
                color: _ink,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final note = await _save(force: true);
                  if (note != null && mounted) {
                    await NoteActions.exportMarkdown(context, note);
                  }
                },
              ),
              _MoreTile(
                icon: Icons.copy_outlined,
                svgAsset: widget.isBottomSheet ? 'copy' : null,
                label: '创建副本',
                color: _ink,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _duplicate();
                },
              ),
              _MoreTile(
                icon: Icons.delete_outline,
                svgAsset: widget.isBottomSheet ? 'trash' : null,
                label: '删除笔记',
                color: NotebookTheme.danger,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _delete();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _saveLabel => switch (_saveState) {
    _SaveState.pending => '待保存',
    _SaveState.saved => widget.isBottomSheet ? '已保存' : '已自动保存',
    _SaveState.saving => '正在保存…',
    _SaveState.failed => '保存失败，点此重试',
  };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _chatSourcePromptTimer?.cancel();
    _chatSourceDoubleTapTimer?.cancel();
    _voiceTimer?.cancel();
    final partialVoicePath = _activeVoiceRecordingPath;
    _activeVoiceRecordingPath = null;
    unawaited(
      _speechService.cancelSession(this).then((_) async {
        if (partialVoicePath != null) {
          await _deleteStoredAttachment(partialVoicePath);
        }
      }),
    );
    _inlineAudioStateSubscription?.cancel();
    _inlineAudioPositionSubscription?.cancel();
    _inlineAudioDurationSubscription?.cancel();
    unawaited(_inlineAudioPlayer.dispose());
    for (final attachment in _pendingAttachments) {
      unawaited(_deleteStoredAttachment(attachment.relativePath));
    }
    _titleController
      ..removeListener(_onContentChanged)
      ..dispose();
    _titleFocus.removeListener(_onChatInputFocusChanged);
    _titleFocus.dispose();
    _quillController
      ..removeListener(_onContentChanged)
      ..dispose();
    _editorFocus.removeListener(_onChatInputFocusChanged);
    _editorFocus.dispose();
    _editorScroll.dispose();
    _pageScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHidden = MediaQuery.viewInsetsOf(context).bottom <= 0;
    final savedAndIdle = _saveState == _SaveState.saved && _pendingSave == null;
    final shouldDeleteEmptyNoteOnReturn = _isEmptyChatNote && _note?.id != null;
    return PopScope<NoteEditorResult>(
      canPop:
          _allowPop ||
          (widget.isBottomSheet &&
              _activeToolPanel == null &&
              keyboardHidden &&
              savedAndIdle &&
              !shouldDeleteEmptyNoteOnReturn),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_activeToolPanel != null) {
          unawaited(_closeToolPanel());
          return;
        }
        if (MediaQuery.viewInsetsOf(context).bottom > 0) {
          _hideKeyboardForBack();
          return;
        }
        _finish();
      },
      child: Theme(
        data: Theme.of(context).copyWith(
          brightness: _nightMode ? Brightness.dark : Brightness.light,
          scaffoldBackgroundColor: _background,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _accent,
            brightness: _nightMode ? Brightness.dark : Brightness.light,
            surface: _surface,
          ),
          bottomSheetTheme: BottomSheetThemeData(backgroundColor: _surface),
        ),
        child: Scaffold(
          backgroundColor: _background,
          resizeToAvoidBottomInset: true,
          appBar: widget.isBottomSheet
              ? null
              : AppBar(
                  backgroundColor: _background,
                  surfaceTintColor: Colors.transparent,
                  leading: IconButton(
                    tooltip: '返回并保存',
                    onPressed: _finish,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  actions: [
                    IconButton(
                      tooltip: '撤销',
                      onPressed: _quillController.hasUndo
                          ? () => setState(_quillController.undo)
                          : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: '重做',
                      onPressed: _quillController.hasRedo
                          ? () => setState(_quillController.redo)
                          : null,
                      icon: const Icon(Icons.redo),
                    ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: () => _invokeChatEditorTool(_showMoreMenu),
                      icon: const Icon(Icons.more_vert),
                    ),
                    IconButton(
                      tooltip: '完成并保存',
                      onPressed: _finish,
                      icon: const Icon(Icons.check, size: 30),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
          body: SafeArea(
            top: false,
            left: false,
            right: false,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    widget.isBottomSheet
                        ? SizedBox(
                            height: 56,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: Row(
                                children: [
                                  _ChatNoteIcon(
                                    'note-pencil',
                                    size: 22,
                                    color: _ink,
                                  ),
                                  const SizedBox(width: 9),
                                  Text(
                                    '笔记',
                                    style: TextStyle(
                                      color: _ink,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 106,
                                    ),
                                    child: Semantics(
                                      button: _saveState == _SaveState.failed,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: _saveState == _SaveState.failed
                                            ? () => _save(force: true)
                                            : null,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 8,
                                          ),
                                          child: Text(
                                            _saveLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              color:
                                                  _saveState ==
                                                      _SaveState.failed
                                                  ? NotebookTheme.danger
                                                  : _muted,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '更多',
                                    onPressed: () =>
                                        _invokeChatEditorTool(_showMoreMenu),
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 48,
                                      height: 48,
                                    ),
                                    icon: _ChatNoteIcon(
                                      'dots-three-vertical',
                                      size: 22,
                                      color: _ink,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '返回添加笔记',
                                    onPressed: _finish,
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 48,
                                      height: 48,
                                    ),
                                    icon: _ChatNoteIcon(
                                      'undo',
                                      size: 22,
                                      color: _ink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: _selectNotebook,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.menu_book_outlined,
                                            size: 17,
                                            color: _muted,
                                          ),
                                          const SizedBox(width: 7),
                                          Flexible(
                                            child: Text(
                                              _notebook?.name ?? '当前笔记本',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: _muted,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.keyboard_arrow_down,
                                            color: _muted,
                                            size: 19,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _saveState == _SaveState.failed
                                      ? () => _save(force: true)
                                      : null,
                                  icon: Icon(
                                    _saveState == _SaveState.failed
                                        ? Icons.error_outline
                                        : Icons.cloud_done_outlined,
                                    size: 16,
                                  ),
                                  label: Text(_saveLabel),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        _saveState == _SaveState.failed
                                        ? NotebookTheme.danger
                                        : _muted,
                                    disabledForegroundColor: _muted,
                                    minimumSize: const Size(48, 44),
                                  ),
                                ),
                              ],
                            ),
                          ),
                    Divider(height: 1, color: _divider),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _handleEditorSurfaceTap,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: widget.isBottomSheet
                                  ? 840
                                  : double.infinity,
                            ),
                            child: Stack(
                              children: [
                                ListView(
                                  controller: _pageScroll,
                                  padding: EdgeInsets.fromLTRB(
                                    22,
                                    22,
                                    22,
                                    widget.isBottomSheet ? 24 : 120,
                                  ),
                                  children: [
                                    TextField(
                                      key: const Key('note_title_field'),
                                      controller: _titleController,
                                      focusNode: _titleFocus,
                                      showCursor: _titleFocus.hasFocus,
                                      maxLines: null,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      style: TextStyle(
                                        color: _ink,
                                        fontSize: 30,
                                        height: 1.2,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      decoration: InputDecoration.collapsed(
                                        hintText: widget.isBottomSheet
                                            ? '请输入标题'
                                            : '标题',
                                        hintStyle: TextStyle(
                                          color: _muted.withValues(alpha: 0.55),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (_sourcePhotoPath.isNotEmpty) ...[
                                      const SizedBox(height: 18),
                                      _SourceCard(
                                        path: _sourcePhotoPath,
                                        color: _surface,
                                        ink: _ink,
                                        muted: _muted,
                                        accent: _accent,
                                        onRemove: () {
                                          setState(() {
                                            _sourcePhotoPath = '';
                                            if (_sourceType ==
                                                    'photo_analysis' ||
                                                _sourceType ==
                                                    'image_attachment') {
                                              _sourceType = 'text_note';
                                            }
                                          });
                                          _onContentChanged();
                                        },
                                      ),
                                    ],
                                    for (final attachment
                                        in _nonInlineAttachments) ...[
                                      const SizedBox(height: 10),
                                      _NoteAttachmentTile(
                                        attachment: attachment,
                                        pending: attachment.id == null,
                                        ink: _ink,
                                        muted: _muted,
                                        onTap: () =>
                                            _openAttachment(attachment),
                                        onRemove: () =>
                                            _removeAttachment(attachment),
                                      ),
                                    ],
                                    const SizedBox(height: 20),
                                    DefaultTextStyle(
                                      style: TextStyle(
                                        color: _ink,
                                        fontSize: 17,
                                        height: 1.7,
                                      ),
                                      child: Listener(
                                        onPointerDown:
                                            _handleChatNoteEditorPointerDown,
                                        onPointerMove:
                                            _handleChatNoteEditorPointerMove,
                                        onPointerUp:
                                            _handleChatNoteEditorPointerUp,
                                        onPointerCancel:
                                            _handleChatNoteEditorPointerCancel,
                                        child: quill.QuillEditor.basic(
                                          key: const Key('note_body_editor'),
                                          controller: _quillController,
                                          focusNode: _editorFocus,
                                          scrollController: _editorScroll,
                                          config: quill.QuillEditorConfig(
                                            editorKey: _quillEditorKey,
                                            contextMenuBuilder:
                                                _buildChatNoteContextMenu,
                                            scrollable: false,
                                            expands: false,
                                            showCursor: _editorFocus.hasFocus,
                                            padding: EdgeInsets.zero,
                                            placeholder: '开始记录…',
                                            textCapitalization:
                                                TextCapitalization.sentences,
                                            embedBuilders: [
                                              _NoteAttachmentEmbedBuilder(
                                                resolvePath:
                                                    _attachmentAbsolutePath,
                                                onOpen: _openInlineAttachment,
                                                onAudioTap: _toggleInlineAudio,
                                                isAudioPlaying:
                                                    _isInlineAudioPlaying,
                                                audioPosition:
                                                    _inlineAudioPositionFor,
                                                audioDuration:
                                                    _inlineAudioDurationFor,
                                                onRemove:
                                                    _removeInlineAttachment,
                                                ink: _ink,
                                                muted: _muted,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (_isProcessing)
                                  Positioned.fill(
                                    child: ColoredBox(
                                      color: _background.withValues(
                                        alpha: 0.72,
                                      ),
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 22,
                                            vertical: 18,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _surface,
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SizedBox(
                                                width: 22,
                                                height: 22,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.5,
                                                      color: _accent,
                                                    ),
                                              ),
                                              const SizedBox(width: 14),
                                              Text(
                                                '正在处理内容…',
                                                style: TextStyle(
                                                  color: _ink,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    _BottomEditorBar(
                      background: _surface,
                      divider: _divider,
                      ink: _ink,
                      accent: _accent,
                      listening: _isListening || _isSavingVoice,
                      phosphorStyle: widget.isBottomSheet,
                      onAi: () => _invokeChatEditorTool(_showAiSheet),
                      onFormat: () => _invokeChatEditorTool(_showFormatSheet),
                      onVoice: () {
                        if (widget.isBottomSheet && _isSavingVoice) return;
                        if (widget.isBottomSheet && _isListening) {
                          unawaited(_stopChatVoice());
                        } else {
                          _invokeChatEditorTool(_showVoiceSheet);
                        }
                      },
                      onAdd: () => _invokeChatEditorTool(_showAddSheet),
                    ),
                  ],
                ),
                if (widget.isBottomSheet && keyboardHidden)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -_currentKeyboardInset,
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 260),
                      reverseDuration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 210),
                      transitionBuilder: (child, animation) {
                        final curve = CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        );
                        return FadeTransition(
                          opacity: curve,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 1),
                              end: Offset.zero,
                            ).animate(curve),
                            child: child,
                          ),
                        );
                      },
                      child: IgnorePointer(
                        key: ValueKey(_activeToolPanel ?? 'closed'),
                        ignoring: _activeToolPanel == null,
                        child: _buildActiveToolPanel(),
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
}

class _BottomEditorBar extends StatelessWidget {
  const _BottomEditorBar({
    required this.background,
    required this.divider,
    required this.ink,
    required this.accent,
    required this.listening,
    required this.onAi,
    required this.onFormat,
    required this.onVoice,
    required this.onAdd,
    required this.phosphorStyle,
  });

  final Color background;
  final Color divider;
  final Color ink;
  final Color accent;
  final bool listening;
  final VoidCallback onAi;
  final VoidCallback onFormat;
  final VoidCallback onVoice;
  final VoidCallback onAdd;
  final bool phosphorStyle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border(top: BorderSide(color: divider)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            _BottomAction(
              icon: Icons.auto_awesome_outlined,
              svgAsset: phosphorStyle ? 'sparkle' : null,
              label: 'AI助手',
              color: accent,
              onTap: onAi,
            ),
            _BottomAction(
              icon: Icons.format_size,
              svgAsset: phosphorStyle ? 'text-aa' : null,
              label: '格式',
              color: ink,
              onTap: onFormat,
            ),
            _BottomAction(
              icon: listening ? Icons.stop_circle_outlined : Icons.mic_none,
              svgAsset: phosphorStyle
                  ? listening
                        ? 'stop-circle'
                        : 'microphone'
                  : null,
              label: listening ? '停止' : '语音',
              color: listening ? Colors.redAccent : ink,
              onTap: onVoice,
            ),
            _BottomAction(
              icon: Icons.add_circle_outline,
              svgAsset: phosphorStyle ? 'plus-circle' : null,
              label: '添加',
              color: ink,
              onTap: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({
    required this.icon,
    this.svgAsset,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String? svgAsset;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                svgAsset == null
                    ? Icon(icon, color: color, size: 24)
                    : _ChatNoteIcon(svgAsset!, color: color, size: 24),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: color, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: Color(0xFFE8E9EB));
}

class _StyleChoice extends StatelessWidget {
  const _StyleChoice({
    required this.label,
    required this.fontSize,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final double fontSize;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        child: Material(
          color: selected ? const Color(0xFFF1F2F3) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: selected ? Colors.black : const Color(0xFF696C70),
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  decoration: selected ? TextDecoration.underline : null,
                  decorationThickness: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TactileGroup extends StatelessWidget {
  const _TactileGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2F3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) Container(width: 1, height: 42, color: Colors.white),
            children[index],
          ],
        ],
      ),
    );
  }
}

class _TactileSurface extends StatelessWidget {
  const _TactileSurface({
    required this.width,
    required this.selected,
    required this.child,
    this.height = 60,
    this.flat = false,
  });

  final double width;
  final bool selected;
  final Widget child;
  final double height;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    if (flat) {
      return Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE3E5E8) : const Color(0xFFF1F2F3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );
    }
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: selected
              ? const [Color(0xFFF0F1F2), Color(0xFFE9EAEC)]
              : const [Colors.white, Color(0xFFFAFAFB)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: selected ? const Color(0xFFCFD1D4) : const Color(0xFFE0E2E5),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
          BoxShadow(color: Colors.white, blurRadius: 1, offset: Offset(0, -1)),
        ],
      ),
      child: child,
    );
  }
}

class _TactileIconButton extends StatelessWidget {
  const _TactileIconButton({
    required this.asset,
    required this.label,
    required this.onTap,
    required this.selected,
    required this.colored,
    required this.width,
    required this.ink,
  });

  final String asset;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool colored;
  final double width;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final face = Container(
      width: width,
      height: width == double.infinity ? 52 : 56,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: width == double.infinity
            ? selected
                  ? _formatMenuAccent
                  : Colors.transparent
            : selected
            ? (colored ? const Color(0xFFE3E5E8) : _formatMenuAccent)
            : const Color(0xFFF1F2F3),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: SvgPicture.asset(
        'assets/icons/note_format/$asset.svg',
        width: 27,
        height: 27,
        colorFilter: colored
            ? null
            : ColorFilter.mode(selected ? Colors.white : ink, BlendMode.srcIn),
      ),
    );
    final content = face;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _TactileTextButton extends StatelessWidget {
  const _TactileTextButton({
    required this.label,
    required this.iconAsset,
    required this.onTap,
    this.fullWidth = false,
  });

  final String label;
  final String iconAsset;
  final VoidCallback onTap;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
      children: [
        SvgPicture.asset(
          'assets/icons/note_format/$iconAsset.svg',
          width: 22,
          height: 22,
          colorFilter: const ColorFilter.mode(
            Color(0xFF25272A),
            BlendMode.srcIn,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF25272A),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: _TactileSurface(
          width: fullWidth ? double.infinity : double.infinity,
          selected: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AddPanelAction extends StatelessWidget {
  const _AddPanelAction({
    required this.asset,
    required this.label,
    required this.onTap,
  });

  final String asset;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: _TactileSurface(
          width: double.infinity,
          height: 86,
          selected: false,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                'assets/icons/note_format/$asset.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(
                  Color(0xFF242629),
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF242629),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteAttachmentEmbedBuilder extends quill.EmbedBuilder {
  const _NoteAttachmentEmbedBuilder({
    required this.resolvePath,
    required this.onOpen,
    required this.onAudioTap,
    required this.isAudioPlaying,
    required this.audioPosition,
    required this.audioDuration,
    required this.onRemove,
    required this.ink,
    required this.muted,
  });

  final Future<String> Function(String relativePath) resolvePath;
  final Future<void> Function(String relativePath) onOpen;
  final Future<void> Function(String relativePath) onAudioTap;
  final bool Function(String relativePath) isAudioPlaying;
  final Duration Function(String relativePath) audioPosition;
  final Duration Function(String relativePath) audioDuration;
  final Future<void> Function(String relativePath) onRemove;
  final Color ink;
  final Color muted;

  @override
  String get key => 'note_attachment';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    try {
      final decoded = jsonDecode(embedContext.node.value.data as String);
      if (decoded is! Map) return const SizedBox.shrink();
      final payload = Map<String, dynamic>.from(decoded);
      final relativePath = payload['relativePath'] as String? ?? '';
      if (relativePath.isEmpty) return const SizedBox.shrink();
      final name = payload['name'] as String? ?? '附件';
      final kind = payload['kind'] as String? ?? 'file';
      if (kind == 'image') {
        return FutureBuilder<String>(
          future: resolvePath(relativePath),
          builder: (context, snapshot) {
            final maximumWidth = min(
              560.0,
              max(180.0, MediaQuery.sizeOf(context).width - 40),
            );
            if (!snapshot.hasData) {
              return Container(
                width: maximumWidth,
                height: 150,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F5),
                  borderRadius: BorderRadius.circular(12),
                ),
              );
            }
            return GestureDetector(
              onTap: () => unawaited(onOpen(relativePath)),
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: maximumWidth,
                      maxHeight: 420,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(snapshot.data!),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: maximumWidth,
                          height: 150,
                          alignment: Alignment.center,
                          color: const Color(0xFFF3F4F5),
                          child: Text(
                            '图片无法显示 · 点击打开',
                            style: TextStyle(color: muted),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!embedContext.readOnly)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Material(
                        color: Colors.white.withValues(alpha: 0.92),
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: '移除图片',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => unawaited(onRemove(relativePath)),
                          icon: Icon(Icons.close, size: 18, color: muted),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      }

      final isAudio = kind == 'audio';
      final playing = isAudioPlaying(relativePath);
      final position = audioPosition(relativePath);
      final actualDuration = audioDuration(relativePath);
      final recordedDuration = payload['durationSeconds'] is int
          ? Duration(seconds: payload['durationSeconds'] as int)
          : Duration.zero;
      final totalDuration = actualDuration > Duration.zero
          ? actualDuration
          : recordedDuration;
      String clock(Duration value) =>
          '${value.inMinutes.toString().padLeft(2, '0')}:'
          '${(value.inSeconds % 60).toString().padLeft(2, '0')}';
      final durationLabel = isAudio
          ? totalDuration > Duration.zero
                ? '${clock(position)} / ${clock(totalDuration)}'
                : '点击播放'
          : '文件 · 点击打开';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E6E8)),
        ),
        child: InkWell(
          onTap: () => unawaited(
            isAudio ? onAudioTap(relativePath) : onOpen(relativePath),
          ),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  isAudio
                      ? playing
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded
                      : Icons.insert_drive_file_outlined,
                  color: muted,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        durationLabel,
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      if (isAudio && totalDuration > Duration.zero) ...[
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            minHeight: 3,
                            value:
                                (position.inMilliseconds /
                                        totalDuration.inMilliseconds)
                                    .clamp(0.0, 1.0)
                                    .toDouble(),
                            backgroundColor: const Color(0xFFE6E8EB),
                            color: const Color(0xFF555B63),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!embedContext.readOnly)
                  IconButton(
                    tooltip: '移除附件',
                    onPressed: () => unawaited(onRemove(relativePath)),
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    icon: Icon(Icons.close, color: muted, size: 20),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

class _NoteAttachmentTile extends StatelessWidget {
  const _NoteAttachmentTile({
    required this.attachment,
    required this.pending,
    required this.ink,
    required this.muted,
    required this.onTap,
    required this.onRemove,
  });

  final NoteAttachment attachment;
  final bool pending;
  final Color ink;
  final Color muted;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFB),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE5E6E8)),
          ),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/icons/note_format/attach_file.svg',
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(muted, BlendMode.srcIn),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pending ? '待保存 · 点击打开' : '点击打开',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '移除附件',
                onPressed: onRemove,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                icon: SvgPicture.asset(
                  'assets/icons/note_format/close.svg',
                  width: 20,
                  height: 20,
                  colorFilter: ColorFilter.mode(muted, BlendMode.srcIn),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.title,
    required this.color,
    required this.onClose,
  });

  final String title;
  final Color color;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip({
    required this.label,
    required this.onTap,
    required this.color,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      side: BorderSide(color: color.withValues(alpha: 0.25)),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Icon(icon, color: color),
        ),
      ),
    );
  }
}

class _FontSizeButton extends StatelessWidget {
  const _FontSizeButton({
    required this.values,
    required this.color,
    required this.accent,
    required this.onSelected,
  });

  final List<int> values;
  final Color color;
  final Color accent;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '字体大小',
      onSelected: onSelected,
      itemBuilder: (_) => values
          .map(
            (value) => PopupMenuItem<int>(
              value: value,
              height: 52,
              child: Row(
                children: [
                  Text('$value', style: TextStyle(color: color, fontSize: 17)),
                  const Spacer(),
                  if (value == 16) Icon(Icons.check, color: accent),
                ],
              ),
            ),
          )
          .toList(),
      child: Material(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Text(
            '16',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _TextColorButton extends StatelessWidget {
  const _TextColorButton({required this.color, required this.onSelected});

  final Color color;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    const colors = <String, Color>{
      '#24211E': Color(0xFF24211E),
      '#9A6544': Color(0xFF9A6544),
      '#B5473D': Color(0xFFB5473D),
      '#365C9A': Color(0xFF365C9A),
    };
    return PopupMenuButton<String>(
      tooltip: '文字颜色',
      onSelected: onSelected,
      itemBuilder: (_) => colors.entries
          .map(
            (entry) => PopupMenuItem<String>(
              value: entry.key,
              child: Row(
                children: [
                  CircleAvatar(backgroundColor: entry.value, radius: 10),
                  const SizedBox(width: 12),
                  Text(entry.key),
                ],
              ),
            ),
          )
          .toList(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Container(
            width: 25,
            height: 25,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF24211E),
              border: Border.fromBorderSide(
                BorderSide(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _ChatNoteIcon extends StatelessWidget {
  const _ChatNoteIcon(this.name, {required this.color, this.size = 24});

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/chat_note_editor/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.svgAsset,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final String? svgAsset;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? color : Theme.of(context).disabledColor;
    return ListTile(
      minTileHeight: 54,
      enabled: enabled,
      leading: svgAsset == null
          ? Icon(icon, color: iconColor)
          : _ChatNoteIcon(svgAsset!, color: iconColor),
      title: Text(label, style: TextStyle(color: iconColor)),
      onTap: enabled ? onTap : null,
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.path,
    required this.color,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onRemove,
  });

  final String path;
  final Color color;
  final Color ink;
  final Color muted;
  final Color accent;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: SizedBox(
              width: 58,
              height: 58,
              child: file.existsSync()
                  ? Image.file(file, fit: BoxFit.cover)
                  : Icon(Icons.broken_image_outlined, color: muted),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '图片来源',
                  style: TextStyle(color: ink, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  p.basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '移除图片来源',
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
