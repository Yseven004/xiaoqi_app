import 'dart:async';

import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:a2ui_flutter/a2ui_flutter.dart' as ui;
import 'package:flutter/material.dart';
import 'package:genkit/client.dart' as genkit;
import 'package:genkit/experimental_client.dart' as agent;
import 'package:json_schema_builder/json_schema_builder.dart' as schema;
import 'package:url_launcher/url_launcher.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../services/book_library_service.dart';
import '../services/home_chat_model_preferences.dart';
import '../services/online_book_import.dart';
import '../services/online_book_search.dart';
import 'app_toast.dart';

final _search = OnlineBookSearch.instance;

Future<BookSourceImportResult?> showOnlineBookSearch(
  BuildContext context, {
  required BookLibraryService library,
  int? bookId,
  String title = '',
  VoidCallback? onImporting,
}) => showDialog<BookSourceImportResult>(
  context: context,
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

class _OnlineBookSearchDialogState extends State<_OnlineBookSearchDialog>
    with WidgetsBindingObserver {
  final _chatInput = TextEditingController();
  late final _directInput = TextEditingController(text: widget.title);
  final _focus = FocusNode();
  final _chatScroll = ScrollController();
  final _directScroll = ScrollController();
  final _messages = <(bool, String)>[];
  var _resultKey = GlobalKey();
  late final _chat = CapabilityCloudSync.instance.createRemoteAgent().chat();
  final _workflow = OnlineBookSearch.newId();
  agent.AgentTurn<Map<String, dynamic>>? _turn;
  String? _searchId;
  String? _pendingId;
  String? _selectedVersion;
  String? _error;
  var _ai = true;
  var _closed = false;
  var _keyboard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadEnabled());
  }

  Future<void> _loadEnabled() async {
    try {
      final enabled = await _search.loadEnabled();
      if (mounted && !enabled) setState(() => _error = '网上找书已关闭，可在「内置插件」重新开启。');
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    if (_keyboard &&
        !visible &&
        (_ai ? _chatInput : _directInput).text.isEmpty) {
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
    _focus.dispose();
    _chatInput.dispose();
    _directInput.dispose();
    _chatScroll.dispose();
    _directScroll.dispose();
    super.dispose();
  }

  String _message(Object error) => switch (error) {
    OnlineBookSearchException() => error.message,
    StateError() => error.message,
    _ => '暂时无法连接找书服务，请重试。',
  };

  void _replaceSearch(String id) {
    final previous = _searchId;
    if (previous != null && previous != id) unawaited(_search.stop(previous));
    if (_searchId != id) {
      setState(() {
        _searchId = id;
        _selectedVersion = null;
        _resultKey = GlobalKey();
      });
    }
  }

  Future<void> _submit(String value, {required bool ai}) async {
    final query = value.trim();
    if (query.isEmpty || _closed || _search.enabled.value == false) return;
    _focus.unfocus();
    setState(() => _error = null);
    final id = OnlineBookSearch.newId();
    if (!ai) {
      final oldPending = _pendingId;
      _pendingId = null;
      _turn?.abort();
      if (oldPending != null) unawaited(_search.stop(oldPending));
      _replaceSearch(id);
      try {
        await _search.start(id, query);
      } on Object catch (error) {
        if (mounted && !_closed && _searchId == id) {
          setState(() => _error = _message(error));
        }
      }
      return;
    }
    if (_turn != null || _pendingId != null) return;
    _pendingId = id;
    // Resolve the user's preferred model before sending this turn.
    final models = HomeChatModelPreferences.instance;
    try {
      await models.load();
    } on Exception {
      if (mounted && !_closed && _pendingId == id) {
        _pendingId = null;
        setState(() => _error = '读取模型设置失败，请重试。');
      }
      return;
    }
    if (!mounted || _closed || _pendingId != id) return;
    _chatInput.clear();
    setState(() {
      _messages.add((true, query));
      _messages.add((false, ''));
    });
    final replyIndex = _messages.length - 1;
    final selected = models.defaultSelection.value;
    final turn = _chat.sendStream(
      message: genkit.Message(
        role: genkit.Role.user,
        content: [genkit.TextPart(text: query)],
        metadata: {
          'xiaoqi_agent_turn': {
            'task_id': id,
            'workflow_id': _workflow,
            'user_message_id': id,
            'current_turn_text': query,
            'book_search_id': id,
            'book_search_context_id': ?_searchId,
            'model_id': selected.model.id,
            'reasoning_level': selected.reasoningLevel.name,
          },
        },
      ),
    );
    _turn = turn;
    // The response can fail before the streaming iterator exits.
    unawaited(turn.response.then<void>((_) {}, onError: (Object _) {}));
    try {
      await for (final chunk in turn.stream) {
        if (!mounted || _closed || _pendingId != id) continue;
        if (chunk.custom?['book_search_reference'] == id) _replaceSearch(id);
        final text = (chunk.raw.modelChunk?.content ?? const <genkit.Part>[])
            .whereType<genkit.TextPart>()
            .map((part) => part.text)
            .join();
        if (text.isNotEmpty) {
          setState(
            () => _messages[replyIndex] = (
              false,
              _messages[replyIndex].$2 + text,
            ),
          );
        }
      }
      final response = await turn.response;
      if (!mounted || _closed || _pendingId != id) return;
      if (response.state?['book_search_reference'] == id) _replaceSearch(id);
    } on Object catch (error) {
      if (mounted && !_closed && _pendingId == id) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (identical(_turn, turn)) {
        _turn = null;
        if (_pendingId == id) _pendingId = null;
        if (mounted && !_closed) setState(() {});
      }
    }
  }

  void _setMode(bool ai) {
    if (_ai == ai) return;
    _focus.unfocus();
    setState(() => _ai = ai);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope<BookSourceImportResult>(
      onPopInvokedWithResult: (popped, _) {
        if (popped) _cancelOnClose();
      },
      child: Dialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(context).height * .76,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        '网上找书',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _cancelOnClose();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
                DefaultTabController(
                  length: 2,
                  child: TabBar(
                    onTap: (index) => _setMode(index == 0),
                    labelColor: Theme.of(context).colorScheme.onSurface,
                    indicatorColor: Theme.of(context).colorScheme.onSurface,
                    tabs: const [
                      Tab(text: 'AI 对话'),
                      Tab(text: '直接搜索'),
                    ],
                  ),
                ),
                if (!_ai) _input(ai: false),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey(_ai),
                    controller: _ai ? _chatScroll : _directScroll,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_ai && _messages.isEmpty && _searchId == null)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              18,
                              keyboardOpen ? 8 : 48,
                              18,
                              20,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '想找哪本书？',
                                  style: TextStyle(
                                    fontSize: 23,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text('告诉我书名、作者或 ISBN，我来帮你找可导入的版本。'),
                                const SizedBox(height: 16),
                                OutlinedButton(
                                  onPressed: () =>
                                      _submit('帮我找《Hello 算法》中文版', ai: true),
                                  child: const Text('帮我找《Hello 算法》中文版 ↗'),
                                ),
                                if (widget.title.isNotEmpty)
                                  TextButton(
                                    onPressed: () => _submit(
                                      '帮我找《${widget.title}》',
                                      ai: true,
                                    ),
                                    child: Text('查找《${widget.title}》'),
                                  ),
                              ],
                            ),
                          ),
                        if (_ai)
                          for (final (user, text) in _messages)
                            if (text.isNotEmpty)
                              Align(
                                alignment: user
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(text),
                                ),
                              ),
                        if (_searchId case final String id)
                          OnlineBookSearchResults(
                            key: _resultKey,
                            searchId: id,
                            rich: _ai,
                            library: widget.library,
                            bookId: widget.bookId,
                            selectedVersion: _selectedVersion,
                            onVersionSelected: (id) =>
                                setState(() => _selectedVersion = id),
                            onImporting: widget.onImporting,
                            onImported: (result) =>
                                Navigator.of(context).pop(result),
                          ),
                        if (_ai && _turn != null) const Text('小七正在回复…'),
                        if (!_ai && _searchId == null)
                          const Text('输入书名、作者或 ISBN，查找可导入的版本。'),
                        if (_error case final String error)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              error,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_ai) _input(ai: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _input({required bool ai}) {
    final controller = ai ? _chatInput : _directInput;
    return Padding(
      padding: EdgeInsets.only(top: ai ? 0 : 10),
      child: TextField(
        key: ValueKey('book-input-$ai'),
        controller: controller,
        focusNode: _focus,
        maxLength: 240,
        onTapOutside: (_) => _focus.unfocus(),
        onSubmitted: (value) => _submit(value, ai: ai),
        textInputAction: ai ? TextInputAction.send : TextInputAction.search,
        decoration: InputDecoration(
          counterText: '',
          hintText: '输入书名、作者或 ISBN',
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          prefixIcon: ai ? null : const Icon(Icons.search),
          suffixIcon: IconButton(
            onPressed: ai && _turn != null
                ? null
                : () => _submit(controller.text, ai: ai),
            tooltip: ai ? '发送' : '搜索',
            icon: Icon(ai ? Icons.send_rounded : Icons.arrow_forward_rounded),
          ),
        ),
      ),
    );
  }
}

class OnlineBookSearchResults extends StatefulWidget {
  const OnlineBookSearchResults({
    super.key,
    required this.searchId,
    this.rich = true,
    this.library,
    this.bookId,
    this.onImporting,
    this.onImported,
    this.selectedVersion,
    this.onVersionSelected,
  });

  final String searchId;
  final bool rich;
  final BookLibraryService? library;
  final int? bookId;
  final VoidCallback? onImporting;
  final ValueChanged<BookSourceImportResult>? onImported;
  final String? selectedVersion;
  final ValueChanged<String>? onVersionSelected;

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
  String? _importing;
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
          widget.onVersionSelected?.call(id);
          _changed();
      }
    });
    _search.enabled.addListener(_changed);
    unawaited(_refresh());
  }

  void _changed() {
    if (mounted) _changes.value++;
  }

  @override
  void didUpdateWidget(covariant OnlineBookSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rich != widget.rich ||
        oldWidget.selectedVersion != widget.selectedVersion) {
      _changed();
    }
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
    if (_importing != null || _search.enabled.value == false) return;
    final rows = (_snapshot?['candidates'] as List? ?? const []);
    if (!rows.whereType<Map>().any(
      (r) => r['id'] == id && r['importable'] == true,
    )) {
      return;
    }
    _importing = id;
    widget.onImporting?.call();
    _changed();
    try {
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
      if (mounted) {
        _importing = null;
        _changed();
      }
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
    final selection =
        widget.selectedVersion ??
        _localVersion ??
        (rows.isEmpty ? null : rows.first['id']);
    final status = _snapshot?['status'] as String?;
    final statusLabel = switch (status) {
      'searching' => '正在查找其他来源…',
      'stopped' => '已停止找书',
      'unavailable' => '来源暂不可用',
      'complete' when rows.isEmpty => '暂未找到可导入的版本',
      null when _error == null => '正在查找…',
      _ => null,
    };
    if (_search.enabled.value == false) return const Text('网上找书已关闭');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.rich && rows.length > 1)
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
          if (!widget.rich || row['id'] == selection) ...[
            _bookCard(context, componentId, row),
            if (!widget.rich) const Divider(height: 16),
          ],
        if (statusLabel != null || _error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  _error ?? statusLabel!,
                  style: Theme.of(context).textTheme.bodySmall,
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
    final colors = Theme.of(context).colorScheme;
    final candidate = row['id'] as String;
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
      decoration: widget.rich
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: colors.surfaceContainerLow,
            )
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: widget.rich ? 12 : 2,
        vertical: 10,
      ),
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
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                if (source != null &&
                    source.scheme == 'https' &&
                    source.host.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () async {
                      var opened = false;
                      try {
                        opened = await launchUrl(
                          source,
                          mode: LaunchMode.externalApplication,
                        );
                      } on Exception {
                        // Older Android devices may have no HTTPS handler.
                      }
                      if (!opened && context.mounted) {
                        AppToast.show(context, '无法打开来源页');
                      }
                    },
                    child: Text('来源　${row['sourceName']} ↗'),
                  ),
                if (row['importable'] != true)
                  Text(row['availability']?.toString() ?? '暂无可导入文件'),
              ],
            ),
          ),
          if (row['importable'] == true) ...[
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.onSurface,
                foregroundColor: colors.surface,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              onPressed: _importing != null
                  ? null
                  : () =>
                        _action(context, componentId, 'book_import', candidate),
              child: Text(
                _importing == candidate
                    ? '导入中'
                    : (widget.rich ? '导入 $format' : '导入'),
              ),
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
    _subscription.unsubscribe();
    _processor.dispose();
    _changes.dispose();
    super.dispose();
  }
}
