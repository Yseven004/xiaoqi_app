import 'dart:async';
import 'dart:math' as math;

import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:a2ui_flutter/a2ui_flutter.dart' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:genkit/client.dart' as genkit;
import 'package:genkit/experimental_client.dart' as agent;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:json_schema_builder/json_schema_builder.dart' as schema;
import 'package:url_launcher/url_launcher.dart';

import '../config/book_flow_theme.dart';
import '../features/ai_study_annotation/domain/ai_chat_process.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../services/book_library_service.dart';
import '../services/home_chat_model_preferences.dart';
import '../services/online_book_import.dart';
import '../services/online_book_search.dart';
import '../services/online_book_search_suggestions.dart';
import '../utils/isbn.dart';
import 'app_toast.dart';
import 'book_import_progress.dart';

final _search = OnlineBookSearch.instance;

Future<void> _openBookSource(BuildContext context, Uri uri) async {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return;
  }
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Exception {
    // Older Android devices may have no HTTPS handler.
  }
  if (!opened && context.mounted) AppToast.show(context, '无法打开来源页');
}

Future<BookSourceImportResult?> showOnlineBookSearch(
  BuildContext context, {
  required BookLibraryService library,
  int? bookId,
  String title = '',
  VoidCallback? onImporting,
}) => showDialog<BookSourceImportResult>(
  context: context,
  barrierColor: const Color(0x70000000),
  requestFocus: false,
  builder: (_) => _OnlineBookSearchDialog(
    library: library,
    bookId: bookId,
    title: title,
    onImporting: onImporting,
  ),
);

class _OnlineBookSearchDialog extends StatefulWidget {
  const _OnlineBookSearchDialog({
    required this.library,
    required this.bookId,
    required this.title,
    required this.onImporting,
  });
  final BookLibraryService library;
  final int? bookId;
  final String title;
  final VoidCallback? onImporting;

  @override
  State<_OnlineBookSearchDialog> createState() =>
      _OnlineBookSearchDialogState();
}

class _BookSearchMessage {
  _BookSearchMessage(this.query);

  final String query;
  String reply = '';
  String get visibleReply => visibleChatAssistantText(reply).trimRight();
  String? searchId;
  String? error;
}

class _OnlineBookSearchDialogState extends State<_OnlineBookSearchDialog>
    with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _messages = <_BookSearchMessage>[];
  final _importActivity = ValueNotifier<(String, String)?>(null);
  final _workflow = OnlineBookSearch.newId();
  late final _chat = CapabilityCloudSync.instance.createRemoteAgent().chat();
  late List<String> _suggestions = initialOnlineBookSearchSuggestions(
    bookTitle: widget.title,
  );
  agent.AgentTurn<Map<String, dynamic>>? _turn;
  String? _searchId;
  String? _pendingId;
  String? _permissionError;
  var _closed = false;
  var _keyboard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadEnabled());
    unawaited(_loadSuggestions());
  }

  Future<void> _loadEnabled() async {
    try {
      final enabled = await _search.loadEnabled();
      if (mounted && !_closed) {
        setState(() {
          _permissionError = enabled ? null : '网上找书已关闭，可在「内置插件」重新开启。';
        });
      }
    } on Object catch (error) {
      if (mounted && !_closed) {
        setState(() => _permissionError = _message(error));
      }
    }
  }

  Future<void> _loadSuggestions() async {
    final suggestions = await loadOnlineBookSearchSuggestions(
      bookId: widget.bookId,
      bookTitle: widget.title,
      library: widget.library,
    );
    if (mounted && !_closed && _messages.isEmpty) {
      setState(() => _suggestions = suggestions);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboard = View.of(context).viewInsets.bottom > 0;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    if (_keyboard && !visible && _inputController.text.isEmpty) {
      _focus.unfocus();
    }
    _keyboard = visible;
  }

  void _cancelOnClose() {
    if (_closed) return;
    _closed = true;
    _turn?.abort();
    for (final id in {_searchId, _pendingId}.whereType<String>()) {
      unawaited(_search.stop(id));
    }
  }

  @override
  void dispose() {
    _cancelOnClose();
    WidgetsBinding.instance.removeObserver(this);
    _importActivity.dispose();
    _focus.dispose();
    _inputController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _message(Object error) => switch (error) {
    OnlineBookSearchException() => error.message,
    StateError() => error.message,
    _ => '暂时无法连接找书服务，请重试。',
  };

  void _keepLatestInView({bool force = false}) {
    if (!force && (!_scroll.hasClients || _scroll.position.extentAfter > 72)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _attachSearch(_BookSearchMessage entry, String id) {
    if (entry.searchId == id) return;
    final previous = _searchId;
    if (previous != null && previous != id) unawaited(_search.stop(previous));
    setState(() {
      entry.searchId = id;
      _searchId = id;
    });
    _keepLatestInView();
  }

  Future<void> _submit(String value, {bool clearDraft = false}) async {
    final query = value.trim();
    if (query.isEmpty ||
        _closed ||
        _pendingId != null ||
        _search.enabled.value == false) {
      return;
    }
    _focus.unfocus();
    if (clearDraft) _inputController.clear();
    final entry = _BookSearchMessage(query);
    final id = OnlineBookSearch.newId();
    setState(() {
      _permissionError = null;
      _pendingId = id;
      _messages.add(entry);
    });
    _keepLatestInView(force: true);

    try {
      // Only a standalone, validated ISBN can bypass the chat turn.
      final isbn =
          RegExp(
            r'^(?:ISBN\s*[:：]?\s*)?[0-9X][0-9X\s-]*$',
            caseSensitive: false,
          ).hasMatch(query)
          ? Isbn.normalize(
              query.replaceFirst(RegExp(r'^ISBN', caseSensitive: false), ''),
            )
          : null;
      if (isbn != null) {
        await _search.start(id, isbn);
        if (mounted && !_closed) _attachSearch(entry, id);
      } else {
        await _sendToAgent(entry, id);
      }
    } on Object catch (error) {
      if (mounted && !_closed) {
        if (entry.searchId == null) unawaited(_search.stop(id));
        setState(() => entry.error = _message(error));
      }
    } finally {
      if (mounted && !_closed && _pendingId == id) {
        setState(() {
          _pendingId = null;
          _turn = null;
        });
        _keepLatestInView();
      }
    }
  }

  Future<void> _sendToAgent(_BookSearchMessage entry, String id) async {
    final models = HomeChatModelPreferences.instance;
    await models.load();
    if (!mounted || _closed) return;
    final selected = models.defaultSelection.value;
    final turn = _chat.sendStream(
      message: genkit.Message(
        role: genkit.Role.user,
        content: [genkit.TextPart(text: entry.query)],
        metadata: {
          'xiaoqi_agent_turn': {
            'task_id': id,
            'workflow_id': _workflow,
            'user_message_id': id,
            'current_turn_text': entry.query,
            'book_search_id': id,
            'book_search_context_id': ?_searchId,
            'model_id': selected.model.id,
            'reasoning_level': selected.reasoningLevel.name,
          },
        },
      ),
    );
    setState(() => _turn = turn);
    unawaited(turn.response.then<void>((_) {}, onError: (Object _) {}));
    await for (final chunk in turn.stream) {
      if (!mounted || _closed) break;
      if (chunk.custom?['book_search_reference'] == id) {
        _attachSearch(entry, id);
      }
      if (chunk.text.isNotEmpty) {
        setState(() => entry.reply += chunk.text);
        _keepLatestInView();
      }
    }
    if (!mounted || _closed) return;
    final response = await turn.response;
    if (!mounted || _closed) return;
    if (response.state?['book_search_reference'] == id) {
      _attachSearch(entry, id);
    }
    final reply = response.text.trimRight();
    setState(() {
      if (reply.isNotEmpty) entry.reply = reply;
      if (entry.visibleReply.trim().isEmpty && entry.searchId == null) {
        entry.error = '这次没有收到回复，请重试。';
      }
    });
    _keepLatestInView();
  }

  bool get _canSubmit => _pendingId == null && _search.enabled.value != false;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return PopScope<BookSourceImportResult>(
      onPopInvokedWithResult: (popped, _) {
        if (popped) _cancelOnClose();
      },
      child: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            surface: Colors.white,
            onSurface: BookFlowTheme.ink,
            primary: BookFlowTheme.ink,
            onSurfaceVariant: BookFlowTheme.inkSecondary,
            error: BookFlowTheme.danger,
          ),
        ),
        child: Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 16,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: SizedBox(
            width: math.min(680.0, viewport.width * .91),
            height: viewport.height * .685,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 4),
                      const Expanded(
                        child: Text(
                          '网上找书',
                          style: TextStyle(
                            color: BookFlowTheme.ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, color: BookFlowTheme.ink),
                        onPressed: () {
                          _cancelOnClose();
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  ),
                  Expanded(
                    child: _messages.isEmpty
                        ? _guidance()
                        : SingleChildScrollView(
                            controller: _scroll,
                            padding: const EdgeInsets.only(top: 12, bottom: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final entry in _messages)
                                  ..._conversationEntry(entry),
                              ],
                            ),
                          ),
                  ),
                  if (_permissionError case final String error)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        error,
                        style: const TextStyle(color: BookFlowTheme.danger),
                      ),
                    ),
                  _composer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _guidance() => LayoutBuilder(
    builder: (context, constraints) {
      final spacious =
          constraints.maxWidth >= 480 && constraints.maxHeight >= 400;
      final inset = (constraints.maxWidth * .10).clamp(8.0, 56.0).toDouble();
      final recommendationSize = spacious ? 17.0 : 15.0;
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Align(
            alignment: Alignment(0, spacious ? -.12 : 0),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _sparkle(spacious ? 30 : 26),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          '想找哪本书？',
                          style: TextStyle(
                            fontSize: spacious ? 30 : 25,
                            fontWeight: FontWeight.w700,
                            color: BookFlowTheme.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: spacious ? 19 : 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 376),
                      child: Text(
                        '告诉我书名、作者或 ISBN，我来帮你找可导入的版本。',
                        style: BookFlowTheme.body.copyWith(
                          fontSize: spacious ? 17 : 15,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: spacious ? 26 : 18),
                  for (final (index, query) in _suggestions.indexed)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: index == _suggestions.length - 1
                            ? 0
                            : (spacious ? 14 : 10),
                      ),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFFEDEDED),
                          foregroundColor: BookFlowTheme.ink,
                          disabledBackgroundColor: const Color(0xFFEDEDED),
                          minimumSize: Size.fromHeight(spacious ? 60 : 50),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: TextStyle(
                            fontSize: recommendationSize,
                            height: 1.4,
                            fontWeight: FontWeight.w500,
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: spacious ? 17 : 12,
                            vertical: spacious ? 13 : 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                        onPressed: _canSubmit ? () => _submit(query) : null,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: spacious ? 28 : 24,
                              child: Text(
                                '${index + 1}.',
                                style: const TextStyle(
                                  color: BookFlowTheme.inkSecondary,
                                ),
                              ),
                            ),
                            Expanded(child: Text(query)),
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
    },
  );

  List<Widget> _conversationEntry(_BookSearchMessage entry) {
    final reply = entry.visibleReply;
    return [
      _bubble(entry.query, user: true),
      if (reply.trim().isNotEmpty)
        _bubble(
          reply,
          user: false,
          isStreaming: _turn != null && identical(entry, _messages.last),
        ),
      if (entry.searchId case final String id)
        Padding(
          key: ValueKey(id),
          padding: const EdgeInsets.only(bottom: 16),
          child: OnlineBookSearchResults(
            searchId: id,
            library: widget.library,
            bookId: widget.bookId,
            importActivity: _importActivity,
            awaitingReply:
                _turn != null &&
                identical(entry, _messages.last) &&
                reply.trim().isEmpty,
            onImporting: widget.onImporting,
            onImported: (result) {
              if (_closed || ModalRoute.of(context)?.isCurrent != true) return;
              _cancelOnClose();
              Navigator.of(context).pop(result);
            },
          ),
        ),
      if (entry.error case final String error)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            error,
            style: const TextStyle(color: BookFlowTheme.danger),
          ),
        ),
      if (identical(entry, _messages.last) &&
          _pendingId != null &&
          reply.trim().isEmpty &&
          entry.searchId == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _turn == null ? '正在准备…' : '小七正在处理…',
              style: BookFlowTheme.body,
            ),
          ),
        ),
    ];
  }

  Widget _sparkle(double size) => SvgPicture.asset(
    'assets/icons/chat_note_editor/sparkle.svg',
    width: size,
    height: size,
    colorFilter: const ColorFilter.mode(BookFlowTheme.ink, BlendMode.srcIn),
    excludeFromSemantics: true,
  );

  Widget _bubble(
    String text, {
    required bool user,
    bool isStreaming = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (user) const SizedBox(width: 32),
        if (!user) ...[
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 7),
            child: _sparkle(20),
          ),
        ],
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(16),
            ),
            child: user
                ? SelectableText(
                    text,
                    style: const TextStyle(
                      color: BookFlowTheme.ink,
                      height: 1.45,
                    ),
                  )
                : SelectionArea(
                    child: GptMarkdown(
                      text,
                      style: const TextStyle(
                        color: BookFlowTheme.ink,
                        fontSize: 15,
                        height: 1.55,
                      ),
                      textDirection: Directionality.of(context),
                      isStreaming: isStreaming,
                      imageBuilder: (_, _, _, _) => const SizedBox.shrink(),
                      onLinkTap: (url, _) {
                        final uri = Uri.tryParse(url.trim());
                        if (uri != null) {
                          unawaited(_openBookSource(context, uri));
                        }
                      },
                    ),
                  ),
          ),
        ),
        if (!user) const SizedBox(width: 7),
      ],
    ),
  );

  Widget _composer() {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFD6D7D9)),
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _inputController,
      builder: (context, value, _) {
        final canSend = _canSubmit && value.text.trim().isNotEmpty;
        return TextField(
          controller: _inputController,
          focusNode: _focus,
          maxLength: 240,
          onTapOutside: (_) => _focus.unfocus(),
          onSubmitted: (value) => _submit(value, clearDraft: true),
          textInputAction: TextInputAction.send,
          style: const TextStyle(color: BookFlowTheme.ink),
          decoration: InputDecoration(
            counterText: '',
            hintText: _messages.isEmpty ? '输入书名、作者或 ISBN，也可以直接问' : '继续提问或找书…',
            hintStyle: const TextStyle(color: BookFlowTheme.inkSecondary),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: border,
            enabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: const BorderSide(color: BookFlowTheme.ink),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 56,
              minHeight: 52,
            ),
            suffixIcon: IconButton(
              onPressed: canSend
                  ? () => _submit(value.text, clearDraft: true)
                  : null,
              tooltip: '发送',
              padding: EdgeInsets.zero,
              icon: SvgPicture.asset(
                canSend
                    ? 'assets/images/home_send_active.svg'
                    : 'assets/images/home_send_idle.svg',
                width: 38,
                height: 38,
              ),
            ),
          ),
        );
      },
    );
  }
}

class OnlineBookSearchResults extends StatefulWidget {
  const OnlineBookSearchResults({
    super.key,
    required this.searchId,
    this.library,
    this.bookId,
    this.onImporting,
    this.onImported,
    this.importActivity,
    this.awaitingReply = false,
  });

  final String searchId;
  final BookLibraryService? library;
  final int? bookId;
  final VoidCallback? onImporting;
  final ValueChanged<BookSourceImportResult>? onImported;
  final ValueNotifier<(String, String)?>? importActivity;
  final bool awaitingReply;

  @override
  State<OnlineBookSearchResults> createState() =>
      _OnlineBookSearchResultsState();
}

class _OnlineBookSearchResultsState extends State<OnlineBookSearchResults> {
  static const _surfaceId = 'online-book-results';
  static const _catalogId = 'https://xiaoqi.app/a2ui/online-book-results';
  late final _processor = a2ui.MessageProcessor<ui.ComponentImplementation>(
    catalogs: [
      ui.CatalogImplementation(
        id: _catalogId,
        protocolVersion: a2ui.A2uiProtocolVersion.v0_9,
        components: [
          ui.ComponentImplementation(
            name: 'XiaoqiBookSearchResults',
            schema: schema.Schema.object(properties: {}, required: []),
            builder: (context, node, props, child) =>
                ValueListenableBuilder<int>(
                  valueListenable: _changes,
                  builder: (context, _, _) =>
                      _resultBody(context, node.componentId),
                ),
          ),
        ],
      ),
    ],
    defaultVersion: a2ui.A2uiProtocolVersion.v0_9,
  );
  final _changes = ValueNotifier(0);
  late final a2ui.Subscription _subscription;
  Map<String, dynamic>? _snapshot;
  String? _error;
  String? _localVersion;
  late final _importActivity =
      widget.importActivity ?? ValueNotifier<(String, String)?>(null);
  bool _stopping = false;
  bool _loaded = false;
  int _misses = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _processor.processMessages([
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': _surfaceId, 'catalogId': _catalogId},
      },
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': _surfaceId,
          'components': [
            {'id': 'root', 'component': 'XiaoqiBookSearchResults'},
          ],
        },
      },
    ]);
    _subscription = _processor.model.onAction.subscribe((event) {
      final data = event.toJson();
      final context = data['context'];
      final id = context is Map ? context['candidateId'] as String? : null;
      switch (data['name']) {
        case 'book_stop':
          unawaited(_stop());
        case 'book_import' when id != null:
          unawaited(_import(id));
        case 'book_select' when id != null:
          _localVersion = id;
          _changed();
      }
    });
    _search.enabled.addListener(_changed);
    _importActivity.addListener(_changed);
    unawaited(_refresh());
  }

  void _changed() {
    if (mounted) _changes.value++;
  }

  @override
  void didUpdateWidget(covariant OnlineBookSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.awaitingReply != widget.awaitingReply) _changed();
  }

  Future<void> _refresh() async {
    var retry = false;
    try {
      final snapshot = await _search.read(widget.searchId);
      if (!mounted) return;
      final oldRevision = _snapshot?['revision'] as int? ?? -1;
      if ((snapshot['revision'] as int? ?? 0) >= oldRevision) {
        _snapshot = snapshot;
      }
      _loaded = true;
      _misses = 0;
      _error = null;
      retry = _snapshot?['status'] == 'searching';
    } on OnlineBookSearchException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 404 && !_loaded && _misses++ < 5) {
        // The first poll may arrive before the submission reaches the API.
        retry = true;
      } else {
        _error = error.message;
        retry = error.statusCode >= 500 && _misses++ < 12;
      }
    } on Object {
      if (!mounted) return;
      _error = '连接中断，正在尝试重新连接…';
      retry = _misses++ < 12;
      if (!retry) _error = '暂时无法获取找书结果，可重试。';
    }
    _changed();
    _poll?.cancel();
    if (retry && mounted) _poll = Timer(const Duration(seconds: 1), _refresh);
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _stopping = true;
    _changed();
    final stopped = await _search.stop(widget.searchId);
    if (!mounted) return;
    _stopping = false;
    if (stopped != null) _snapshot = stopped;
    _changed();
  }

  Future<void> _import(String id) async {
    if (_search.enabled.value == false) return;
    if (_importActivity.value != null) {
      AppToast.show(context, '资料正在导入，请稍候');
      return;
    }
    final rows = (_snapshot?['candidates'] as List? ?? const []);
    if (!rows.whereType<Map>().any(
      (r) => r['id'] == id && r['importable'] == true,
    )) {
      return;
    }
    _importActivity.value = (widget.searchId, id);
    try {
      widget.onImporting?.call();
      final file = await _search.resolve(widget.searchId, id);
      if (!mounted || _search.enabled.value == false) return;
      final result = await importOnlineBook(
        file,
        bookId: widget.bookId,
        library: widget.library,
      );
      if (!mounted) return;
      AppToast.show(context, result.reusedExisting ? '这份资料已在书库中' : '已导入书库');
      widget.onImported?.call(result);
    } on Object catch (error) {
      if (mounted) AppToast.show(context, '导入失败：$error');
    } finally {
      if (mounted) _importActivity.value = null;
    }
  }

  void _action(
    BuildContext context,
    String componentId,
    String name, [
    String? id,
  ]) => unawaited(
    ui.A2uiSurface.of(context).dispatchAction({
      'event': {
        'name': name,
        'context': {'candidateId': ?id},
      },
    }, componentId),
  );

  Widget _resultBody(BuildContext context, String componentId) {
    final rows = (_snapshot?['candidates'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final selection = _localVersion ?? (rows.isEmpty ? null : rows.first['id']);
    final status = _snapshot?['status'] as String?;
    final statusLabel = switch (status) {
      'searching' when rows.isEmpty => '正在查找书源…',
      'searching' => '正在查找其他来源…',
      'complete' || 'unavailable' when widget.awaitingReply => '小七正在整理查找结果…',
      'stopped' => '已停止找书',
      'unavailable' => '书源暂时无法访问',
      'complete' when rows.isEmpty => '未找到匹配书目',
      'complete' when _snapshot?['partial'] == true => '部分书源未能访问',
      null when _error == null => '正在查找书源…',
      _ => null,
    };
    if (_search.enabled.value == false) return const Text('网上找书已关闭');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rows.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 5,
              children: [
                for (final row in rows)
                  ChoiceChip(
                    label: Text(_versionChipLabel(row)),
                    selected: row['id'] == selection,
                    showCheckmark: false,
                    selectedColor: BookFlowTheme.ink,
                    backgroundColor: Colors.white,
                    labelStyle: TextStyle(
                      color: row['id'] == selection
                          ? Colors.white
                          : BookFlowTheme.ink,
                    ),
                    side: BorderSide(
                      color: row['id'] == selection
                          ? BookFlowTheme.ink
                          : const Color(0xFFD6D7D9),
                    ),
                    shape: const StadiumBorder(),
                    onSelected: (_) => _action(
                      context,
                      componentId,
                      'book_select',
                      row['id'] as String,
                    ),
                  ),
              ],
            ),
          ),
        for (final row in rows)
          if (row['id'] == selection) _bookCard(context, componentId, row),
        if (statusLabel != null || _error != null)
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error ?? statusLabel!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              if (status == 'searching' || status == null && _error == null)
                TextButton(
                  onPressed: _stopping
                      ? null
                      : () => _action(context, componentId, 'book_stop'),
                  child: Text(_stopping ? '正在停止' : '停止'),
                ),
              if (_error != null && _poll?.isActive != true)
                TextButton(
                  onPressed: () {
                    _misses = 0;
                    unawaited(_refresh());
                  },
                  child: const Text('重试'),
                ),
            ],
          ),
      ],
    );
  }

  String _versionChipLabel(Map row) {
    final title = row['title']?.toString() ?? '';
    final parts = title.split(' · ');
    final edition = row['edition']?.toString() ?? '';
    final format = (row['format']?.toString() ?? '').toUpperCase();
    return [
      parts.length > 1
          ? parts.last
          : edition.isNotEmpty
          ? edition
          : title,
      format,
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  Widget _bookCard(BuildContext context, String componentId, Map row) {
    final candidate = row['id'] as String;
    final importing = _importActivity.value == (widget.searchId, candidate);
    final title = row['title']?.toString() ?? '';
    final source = Uri.tryParse(row['sourceUrl']?.toString() ?? '');
    final format = (row['format']?.toString() ?? '').toUpperCase();
    final details = [
      row['author'],
      row['edition'],
      row['language'],
      format,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFFF0F0F0),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: BookFlowTheme.ink,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: const TextStyle(color: BookFlowTheme.inkSecondary),
                  ),
                if (source != null &&
                    source.scheme == 'https' &&
                    source.host.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => _openBookSource(context, source),
                    child: Text('来源　${row['sourceName']} ↗'),
                  ),
                if (row['importable'] != true)
                  Text(
                    row['availability']?.toString() ?? '暂无可导入文件',
                    style: BookFlowTheme.body,
                  ),
              ],
            ),
          ),
          if (row['importable'] == true) ...[
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BookFlowTheme.ink,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE5E5E5),
                disabledForegroundColor: BookFlowTheme.inkSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              onPressed: importing
                  ? null
                  : () =>
                        _action(context, componentId, 'book_import', candidate),
              child: importing
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BookImportProgress(),
                        SizedBox(width: 6),
                        Text(bookImportInProgressLabel),
                      ],
                    )
                  : Text(format.isEmpty ? '导入' : '导入 $format'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ui.A2uiSurface(surface: _processor.model.getSurface(_surfaceId)!);

  @override
  void dispose() {
    _poll?.cancel();
    _search.enabled.removeListener(_changed);
    _importActivity.removeListener(_changed);
    if (widget.importActivity == null) _importActivity.dispose();
    _subscription.unsubscribe();
    _processor.dispose();
    _changes.dispose();
    super.dispose();
  }
}
