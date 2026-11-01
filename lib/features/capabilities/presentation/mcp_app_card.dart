import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import '../data/capability_cloud_sync.dart';
import 'mcp_app_shell.dart';

class McpAppCard extends StatefulWidget {
  const McpAppCard({
    super.key,
    required this.artifact,
    required this.onSendMessage,
  });
  final Map<String, Object?> artifact;
  final Future<bool> Function(String text) onSendMessage;
  @override
  State<McpAppCard> createState() => _McpAppCardState();
}

class _McpAppCardState extends State<McpAppCard> {
  Map<String, dynamic>? _descriptor, _surface, _lastResult;
  PlatformWebViewController? _controller;
  PlatformWebViewWidget? _view;
  final _bindings = <String, String>{};
  final _replies = <String, Map<String, dynamic>>{};
  final _pending = <String>{};
  final _calls = <String>{};
  final _callIds = <String, String>{};
  final _cancelled = <String>{};
  final _dialogs = <String, DialogRoute<bool>>{};
  Map<String, dynamic>? _recovery;
  String _nonce = '', _status = '';
  String? _error;
  bool _expanded = false, _loading = false, _ready = false, _busy = false;
  bool _disposed = false, _initializing = false;
  int _epoch = 0, _sequence = 0, _logs = 0;
  double _height = 400;
  String get _task => widget.artifact['task_id']?.toString() ?? '';
  String get _app => _descriptor?['app_id'] as String? ?? '';
  final _cloud = CapabilityCloudSync.instance;

  Future<void> _expand() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_expanded) {
      await _close();
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _expanded = true;
      _loading = true;
      _error = null;
      _ready = false;
    });
    try {
      final bytes = await _cloud.downloadTaskArtifact(
        _task,
        widget.artifact['id'].toString(),
      );
      if (bytes.length > 2 * 1024 * 1024) throw StateError('交互结果描述过大');
      final descriptor = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (descriptor['task_id'] != _task || descriptor['app_id'] is! String) {
        throw StateError('交互结果来源不匹配');
      }
      if (!mounted || epoch != _epoch) return;
      _descriptor = descriptor;
      _lastResult = Map<String, dynamic>.from(
        descriptor['last_result'] as Map? ?? {},
      );
      final surface = await _cloud.openMcpApp(_task, _app);
      if (!mounted || epoch != _epoch) return;
      if (surface['html'] is! String) throw StateError('插件未返回可显示的界面');
      if (kIsWeb) throw StateError('此面板需要 Android 或 iOS 客户端');
      if (WebViewPlatform.instance == null) {
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
            AndroidWebViewPlatform.registerWith();
          case TargetPlatform.iOS:
            WebKitWebViewPlatform.registerWith();
          default:
            throw StateError('此面板需要 Android 或 iOS 客户端');
        }
      }
      _surface = surface;
      _recovery = surface['pending_call'] is Map
          ? Map<String, dynamic>.from(surface['pending_call'] as Map)
          : null;
      _lastResult = Map<String, dynamic>.from(surface['result'] as Map? ?? {});
      _nonce = List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _bindings.clear();
      _cancelled.clear();
      _callIds.clear();
      _initializing = false;
      _replies.clear();
      _pending.clear();
      _sequence = 0;
      final shell = McpAppShell(html: surface['html'] as String, nonce: _nonce);
      final controller = PlatformWebViewController(
        const PlatformWebViewControllerCreationParams(),
      );
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.transparent);
      final navigation = PlatformNavigationDelegate(
        const PlatformNavigationDelegateCreationParams(),
      );
      await navigation.setOnNavigationRequest(
        (request) => shell.allowsNavigation(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      );
      await controller.setPlatformNavigationDelegate(navigation);
      await controller.addJavaScriptChannel(
        JavaScriptChannelParams(
          name: 'XiaoqiMcpApp',
          onMessageReceived: (message) =>
              unawaited(_receive(message.message, epoch)),
        ),
      );
      if (!mounted || epoch != _epoch) {
        await controller.removeJavaScriptChannel('XiaoqiMcpApp');
        return;
      }
      _controller = controller;
      _view = PlatformWebViewWidget(
        PlatformWebViewWidgetCreationParams(controller: controller),
      );
      await controller.loadHtmlString(
        shell.document,
        baseUrl: 'https://xiaoqi-app.invalid/',
      );
      if (mounted && epoch == _epoch) setState(() => _loading = false);
      unawaited(
        Future<void>.delayed(const Duration(seconds: 15), () {
          if (mounted && epoch == _epoch && !_ready) {
            setState(() => _error = '插件界面未完成初始化，已保留上次结果');
          }
        }),
      );
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _close() async {
    final closedEpoch = ++_epoch;
    for (final key in _pending.toList()) {
      _cancelRpc(key);
    }
    _nonce = '';
    _ready = false;
    final controller = _controller;
    _controller = null;
    _view = null;
    for (final call in _calls.toList()) {
      unawaited(
        _cloud.cancelMcpApp(_task, _app, call).catchError((_) {
          if (mounted && !_disposed && closedEpoch == _epoch) {
            setState(() => _status = '取消状态未确认，请核实原操作结果');
          }
        }),
      );
    }
    if (controller != null) {
      try {
        await controller.removeJavaScriptChannel('XiaoqiMcpApp');
        await controller.loadHtmlString('<!doctype html><html></html>');
      } catch (_) {
        // The detached view has no live nonce or native action authority.
      }
    }
    if (mounted && !_disposed) {
      setState(() {
        _expanded = false;
        _loading = false;
        _busy = false;
      });
    }
  }

  Future<void> _deliver(Map<String, dynamic> rpc, int epoch) async {
    if (!mounted || epoch != _epoch || _controller == null) return;
    final encoded = jsonEncode(rpc).replaceAll('<', r'\u003c');
    await _controller!.runJavaScript('window.xiaoqiAppDeliver($encoded)');
  }

  Future<void> _receive(String message, int epoch) async {
    if (!mounted ||
        epoch != _epoch ||
        utf8.encode(message).length > 128 * 1024) {
      return;
    }
    try {
      final envelope = jsonDecode(message) as Map;
      if (envelope['nonce'] != _nonce || _nonce.isEmpty) return;
      final rpc = Map<String, dynamic>.from(envelope['rpc'] as Map);
      if (rpc['jsonrpc'] != '2.0' || rpc['method'] is! String) return;
      final id = rpc['id'];
      if (id != null && id is! String && id is! num) return;
      final key = jsonEncode(id);
      if (rpc['method'] == 'notifications/cancelled') {
        final params = rpc['params'];
        if (params is Map && params.containsKey('requestId')) {
          _cancelRpc(jsonEncode(params['requestId']));
        }
        return;
      }
      final binding = jsonEncode([rpc['method'], rpc['params']]);
      if (id != null) {
        if (_bindings[key] != null && _bindings[key] != binding) {
          throw StateError('原请求参数已变化');
        }
        if (_replies[key] != null) {
          await _deliver(_replies[key]!, epoch);
          return;
        }
        if (_pending.contains(key)) return;
        if (_cancelled.contains(key)) throw StateError('原请求已取消');
        if (_bindings.length >= 256) throw StateError('面板请求数量超过限制');
        _bindings[key] = binding;
        _pending.add(key);
      }
      try {
        final output = await _handle(rpc, epoch);
        if (id != null) {
          final reply = <String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': output ?? {},
          };
          _replies[key] = reply;
          await _deliver(reply, epoch);
        }
      } catch (error) {
        if (id != null) {
          await _deliver({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32000, 'message': error.toString()},
          }, epoch);
        }
        if (mounted && epoch == _epoch) {
          setState(() => _status = error.toString());
        }
      } finally {
        _pending.remove(key);
      }
    } catch (_) {
      /* Unauthenticated or malformed frame messages have no authority. */
    }
  }

  void _cancelRpc(String key) {
    if (!_bindings.containsKey(key)) return;
    _cancelled.add(key);
    final route = _dialogs.remove(key);
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route, false);
    }
    final call = _callIds[key];
    if (call != null && _calls.contains(call)) {
      unawaited(_cancelCall(call, _epoch));
    }
  }

  Future<void> _cancelCall(String call, int epoch) async {
    try {
      await _cloud.cancelMcpApp(_task, _app, call);
      if (mounted && !_disposed && epoch == _epoch) {
        setState(() => _status = '已请求取消，仍需核实原结果');
      }
    } catch (_) {
      if (mounted && !_disposed && epoch == _epoch) {
        setState(() => _status = '取消状态未确认，请核实原操作结果');
      }
    }
  }

  Future<bool> _confirm(
    String title,
    String text,
    String key,
    int epoch,
  ) async {
    if (!mounted || epoch != _epoch || _cancelled.contains(key)) return false;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    _dialogs[key] = route;
    try {
      final accepted = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      return accepted == true &&
          mounted &&
          epoch == _epoch &&
          !_cancelled.contains(key);
    } finally {
      if (identical(_dialogs[key], route)) _dialogs.remove(key);
    }
  }

  Future<Object?> _handle(
    Map<String, dynamic> rpc,
    int epoch, {
    bool nativeRecovery = false,
  }) async {
    final method = rpc['method'] as String;
    final key = jsonEncode(rpc['id']);
    final params = Map<String, dynamic>.from(rpc['params'] as Map? ?? {});
    if (method == 'ui/initialize') {
      if (_ready) throw StateError('当前面板已初始化');
      _initializing = true;
      return {
        'protocolVersion': '2026-01-26',
        'hostInfo': {'name': 'Xiaoqi', 'version': '1'},
        'hostCapabilities': {
          'serverTools': {},
          'openLinks': {},
          'message': {},
          'logging': {},
        },
        'hostContext': {
          'theme': Theme.of(context).brightness == Brightness.dark
              ? 'dark'
              : 'light',
          'displayMode': 'inline',
          'availableDisplayModes': ['inline'],
          'platform': 'mobile',
        },
      };
    }
    if (method == 'ui/notifications/initialized') {
      if (!_initializing) throw StateError('尚未协商面板协议');
      if (_ready) return null;
      if (mounted && epoch == _epoch) {
        setState(() {
          _ready = true;
          _error = null;
        });
      }
      await _deliver({
        'jsonrpc': '2.0',
        'method': 'ui/notifications/tool-input',
        'params': {'arguments': _surface?['input'] ?? {}},
      }, epoch);
      await _deliver({
        'jsonrpc': '2.0',
        'method': 'ui/notifications/tool-result',
        'params': _lastResult ?? {},
      }, epoch);
      return null;
    }
    if (!_ready && !nativeRecovery) throw StateError('插件界面尚未初始化');
    if (method == 'ui/notifications/size-changed') {
      final height = params['height'];
      if (height is num && height.isFinite && mounted) {
        setState(() => _height = height.clamp(160, 600).toDouble());
      }
      return null;
    }
    if (method == 'notifications/message') {
      if (mounted) setState(() => _logs++);
      return null;
    }
    if (method == 'ui/request-display-mode') return {'mode': 'inline'};
    if (method == 'ui/open-link') {
      final url = Uri.tryParse(params['url']?.toString() ?? '');
      if (url == null ||
          !{'https', 'http'}.contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.toString().length > 2048) {
        throw StateError('链接无效');
      }
      if (!await _confirm('打开插件链接？', url.toString(), key, epoch)) {
        return {'isError': true};
      }
      if (!mounted || epoch != _epoch) return {'isError': true};
      return {
        'isError': !await launchUrl(url, mode: LaunchMode.externalApplication),
      };
    }
    if (method == 'ui/message') {
      if (params['role'] != 'user') throw StateError('插件只能请求发送用户确认的消息');
      final blocks = params['content'] is List
          ? params['content'] as List
          : [params['content']];
      if (blocks.isEmpty ||
          blocks.any(
            (block) =>
                block is! Map ||
                block['type'] != 'text' ||
                block['text'] is! String,
          )) {
        throw StateError('消息格式无效');
      }
      final text = blocks
          .map((block) => (block as Map)['text'] as String)
          .join('\n');
      if (text.trim().isEmpty || text.length > 8192) {
        throw StateError('消息为空或过长');
      }
      if (!await _confirm('发送到当前聊天？', text, key, epoch)) {
        return {'isError': true};
      }
      if (!mounted || epoch != _epoch) return {'isError': true};
      if (!await widget.onSendMessage(text)) {
        throw StateError('请先处理当前草稿或等待任务结束，原输入已保留');
      }
      return {'isError': false};
    }
    if (method == 'tools/call') {
      if (_recovery != null) throw StateError('请先核实上次操作的结果');
      if (_busy) throw StateError('请等待当前面板操作完成');
      if (_surface?['enabled'] != true) throw StateError('任务尚未结束，请稍后重新展开面板');
      final tool = params['name'];
      final args = params['arguments'] ?? <String, dynamic>{};
      if (tool is! String || args is! Map<String, dynamic>) {
        throw StateError('工具请求格式无效');
      }
      final call = _callIds.putIfAbsent(
        jsonEncode(rpc['id']),
        () => '${_nonce.substring(0, 32)}-${_sequence++}',
      );
      _calls.add(call);
      if (mounted) {
        setState(() {
          _busy = true;
          _status = '操作进行中';
        });
      }
      try {
        var response = await _cloud.callMcpApp(
          task: _task,
          app: _app,
          callId: call,
          tool: tool,
          arguments: args,
        );
        if (response['status'] == 'approval_required') {
          final approval = Map<String, dynamic>.from(
            response['approval'] as Map,
          );
          if (!mounted || epoch != _epoch) throw StateError('面板已关闭，未确认操作');
          final accepted = await _confirm(
            '确认插件操作？',
            '${approval['description'] ?? approval['tool_name'] ?? tool}\n${jsonEncode(approval['arguments'] ?? args)}',
            key,
            epoch,
          );
          if (!mounted || epoch != _epoch) throw StateError('面板已关闭，未提交确认');
          if (_cancelled.contains(key)) throw StateError('原请求已取消，未提交确认');
          response = await _cloud.callMcpApp(
            task: _task,
            app: _app,
            callId: call,
            tool: tool,
            arguments: args,
            approval: {
              'approved': accepted,
              'approval_hash': approval['approval_hash'],
            },
          );
        }
        if (response['status'] != 'completed') {
          throw StateError('面板操作仍待确认，请核实原结果');
        }
        final result = Map<String, dynamic>.from(response['result'] as Map);
        final failed = result['status'] != 'completed';
        if (mounted && epoch == _epoch) {
          setState(() {
            if (!failed) _lastResult = result;
            _status = failed ? '操作未完成，原结果已保留' : '操作完成';
          });
        }
        return {...result, 'isError': failed};
      } catch (error) {
        if (mounted && epoch == _epoch) {
          setState(
            () => _recovery = {
              'call_id': call,
              'tool_name': tool,
              'arguments': args,
            },
          );
        }
        rethrow;
      } finally {
        _calls.remove(call);
        if (mounted && epoch == _epoch) setState(() => _busy = false);
      }
    }
    throw StateError('插件请求的接口未在当前面板协商');
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }

  Future<void> _recoverCall() async {
    final saved = _recovery;
    if (saved == null || _busy) return;
    final epoch = _epoch;
    final id = 'native-recovery-${saved['call_id']}';
    _callIds[jsonEncode(id)] = saved['call_id'] as String;
    setState(() => _recovery = null);
    try {
      await _handle(
        {
          'method': 'tools/call',
          'id': id,
          'params': {
            'name': saved['tool_name'],
            'arguments': saved['arguments'],
          },
        },
        epoch,
        nativeRecovery: true,
      );
      if (mounted && epoch == _epoch) {
        setState(() => _status = '原操作结果已核实，可收起后重新展开面板');
      }
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _recovery = saved;
          _status = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: const Color(0xFFFAFAFA),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Color(0xFFE7E8EA)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(_descriptor?['title']?.toString() ?? '插件交互结果'),
          subtitle: Text(_logs > 0 ? '已接收 $_logs 条插件日志' : '操作沿用当前任务的权限与预算'),
          trailing: TextButton(
            onPressed: _expand,
            child: Text(_expanded ? '收起' : '展开'),
          ),
        ),
        if (_expanded) ...[
          if (_loading)
            const SizedBox(
              height: 160,
              child: Center(child: Text('正在读取交互结果…')),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          if (_view != null && _error == null)
            SizedBox(
              height: _height,
              child: IgnorePointer(
                ignoring: _busy,
                child: _view!.build(context),
              ),
            ),
          if (!_loading &&
              (_view == null || _error != null) &&
              _lastResult != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(jsonEncode(_lastResult)),
            ),
          if (_status.isNotEmpty || !_ready)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_status.isNotEmpty ? _status : '正在初始化插件界面…'),
            ),
          if (_busy)
            TextButton(
              onPressed: () {
                for (final call in _calls.toList()) {
                  unawaited(_cancelCall(call, _epoch));
                }
              },
              child: const Text('取消本次操作'),
            ),
          if (_recovery != null && !_busy)
            Wrap(
              children: [
                TextButton(
                  onPressed: _recoverCall,
                  child: const Text('核实上次操作'),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await _cloud.cancelMcpApp(
                        _task,
                        _app,
                        _recovery!['call_id'] as String,
                      );
                      if (mounted) setState(() => _status = '已请求取消，仍需核实原结果');
                    } catch (_) {
                      if (mounted) setState(() => _status = '取消状态未确认，请核实原结果');
                    }
                  },
                  child: const Text('取消上次操作'),
                ),
              ],
            ),
        ],
      ],
    ),
  );
}
