import 'dart:async';
import 'dart:convert';

import 'package:livekit_client/livekit_client.dart';

import '../../../config/api_config.dart';
import '../domain/realtime_voice_session.dart';
import '../domain/voice_context_snapshot.dart';

/// LiveKit Cloud Build implementation used by the personal MVP.
///
/// This class deliberately contains no provider API keys. STT/LLM/TTS are
/// selected in the Agent deployment and can be replaced without touching the
/// Flutter app. The development token source is intentionally guarded by the
/// configuration check and must not be used for a public release.
class LiveKitRealtimeVoiceSession extends RealtimeVoiceSession {
  LiveKitRealtimeVoiceSession({
    String? tokenServerId,
    String? agentName,
    this.maxDuration = const Duration(minutes: 20),
  }) : tokenServerId = tokenServerId ?? ApiConfig.livekitDevTokenServerId,
       agentName = agentName ?? ApiConfig.livekitAgentName;

  final String tokenServerId;
  final String agentName;
  final Duration maxDuration;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _usageTimer;
  RealtimeVoiceState _state = RealtimeVoiceState.disconnected;
  String? _errorMessage;
  bool _muted = false;
  VoiceContextSnapshot? _context;
  final _transcripts = <VoiceTranscript>[];
  final _assistantTurnIndexes = <String, int>{};
  final _closedAssistantTurns = <String>{};
  String? _activeAssistantTurnId;
  VoiceUsage _usage = const VoiceUsage.empty();
  DateTime? _startedAt;
  bool _ending = false;
  bool _budgetWarningSent = false;
  VoiceContextSnapshot? _pendingContext;
  bool _publishingContext = false;

  @override
  RealtimeVoiceState get state => _state;

  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get isMuted => _muted;

  @override
  VoiceContextSnapshot? get context => _context;

  @override
  List<VoiceTranscript> get transcripts => List.unmodifiable(_transcripts);

  @override
  VoiceUsage get usage => _usage;

  @override
  bool get isConfigured => tokenServerId.trim().isNotEmpty;

  @override
  Future<void> start({required VoiceContextSnapshot context}) async {
    if (_state == RealtimeVoiceState.connecting ||
        _state == RealtimeVoiceState.listening ||
        _state == RealtimeVoiceState.thinking ||
        _state == RealtimeVoiceState.speaking) {
      await updateContext(context);
      return;
    }
    if (!isConfigured) {
      _setError('尚未配置 LiveKit 开发令牌服务 ID');
      return;
    }

    _ending = false;
    _errorMessage = null;
    _context = context;
    _transcripts.clear();
    _assistantTurnIndexes.clear();
    _closedAssistantTurns.clear();
    _activeAssistantTurnId = null;
    _usage = const VoiceUsage.empty();
    _budgetWarningSent = false;
    _startedAt = DateTime.now();
    _setState(RealtimeVoiceState.connecting);

    final roomName =
        'xiaoqi-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final identity =
        'xiaoqi-user-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final room = Room();
    _room = room;
    final listener = room.createListener();
    _listener = listener;
    listener
      ..on<RoomReconnectingEvent>((_) {
        if (!_ending) _setState(RealtimeVoiceState.reconnecting);
      })
      ..on<RoomReconnectedEvent>((_) {
        if (!_ending) _setState(RealtimeVoiceState.listening);
        final current = _context;
        if (current != null) unawaited(_publishContext(current));
      })
      ..on<RoomDisconnectedEvent>((_) {
        if (!_ending) _setState(RealtimeVoiceState.disconnected);
      })
      ..on<DataReceivedEvent>(_onDataReceived);

    try {
      final tokenSource = DevelopmentTokenSource(id: tokenServerId.trim());
      final response = await tokenSource.fetch(
        TokenRequestOptions(
          roomName: roomName,
          participantIdentity: identity,
          participantName: '小七用户',
          agentName: agentName.trim().isEmpty ? null : agentName.trim(),
        ),
      );
      await room.connect(response.serverUrl, response.participantToken);
      // Publish the page snapshot before opening the microphone so the first
      // user turn cannot race ahead of the context handshake.
      await _publishContext(context);
      await room.localParticipant?.setMicrophoneEnabled(true);
      _muted = false;
      _setState(RealtimeVoiceState.listening);
      _startUsageTimer();
    } catch (error) {
      _setError(_friendlyError(error));
      await _disposeRoom();
    }
  }

  @override
  Future<void> updateContext(VoiceContextSnapshot context) async {
    _context = context;
    notifyListeners();
    if (_room?.connectionState == ConnectionState.connected) {
      await _publishContext(context);
    }
  }

  @override
  Future<void> mute() async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    await participant.setMicrophoneEnabled(false);
    _muted = true;
    notifyListeners();
  }

  @override
  Future<void> unmute() async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    await participant.setMicrophoneEnabled(true);
    _muted = false;
    if (_state == RealtimeVoiceState.reconnecting) {
      _setState(RealtimeVoiceState.listening);
    } else {
      notifyListeners();
    }
  }

  @override
  Future<void> interrupt() async {
    final turnId = _activeAssistantTurnId;
    if (turnId != null) _markAssistantInterrupted(turnId);
    await _publishEnvelope('interrupt', {if (turnId != null) 'turnId': turnId});
    _setState(RealtimeVoiceState.listening);
  }

  @override
  Future<void> end() async {
    if (_state == RealtimeVoiceState.disconnected || _ending) return;
    _ending = true;
    _setState(RealtimeVoiceState.ending);
    await _disposeRoom();
    _setState(RealtimeVoiceState.disconnected);
  }

  Future<void> _publishContext(VoiceContextSnapshot context) {
    // Coalesce rapid page/selection changes, but always send the newest
    // snapshot after the current packet finishes. This preserves reliable
    // ordering while avoiding a queue of stale full-page payloads.
    _pendingContext = context;
    if (_publishingContext) return Future.value();
    _publishingContext = true;
    return _drainContextQueue();
  }

  Future<void> _drainContextQueue() async {
    try {
      while (_pendingContext != null) {
        final context = _pendingContext!;
        _pendingContext = null;
        // LiveKit reliable data packets are intentionally kept below the
        // common 15 KiB limit. The local snapshot remains complete; only the
        // wire copy is bounded so a long OCR page cannot break the session.
        final payload = context.toJson();
        payload['pageText'] = _truncateUtf8(context.pageText, 7000);
        payload['selectedText'] = _truncateUtf8(context.selectedText, 3000);
        await _publishEnvelope('context_snapshot', payload);
      }
    } finally {
      _publishingContext = false;
      if (_pendingContext != null && _room != null) {
        _publishingContext = true;
        unawaited(_drainContextQueue());
      }
    }
  }

  String _truncateUtf8(String text, int maxBytes) {
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return text;
    return utf8.decode(bytes.take(maxBytes).toList(), allowMalformed: true);
  }

  Future<void> _publishEnvelope(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    await participant.publishData(
      utf8.encode(jsonEncode({'type': type, ...payload})),
      reliable: true,
      topic: 'xiaoqi.voice.control',
    );
  }

  void _onDataReceived(DataReceivedEvent event) {
    if (event.topic != 'xiaoqi.voice.transcript' &&
        event.topic != 'xiaoqi.voice.usage' &&
        event.topic != 'xiaoqi.voice.state') {
      return;
    }
    try {
      final decoded = jsonDecode(utf8.decode(event.data));
      if (decoded is! Map) return;
      final type = decoded['type']?.toString();
      if (type == 'assistant_delta') {
        _appendAssistantDelta(
          turnId: decoded['turnId']?.toString() ?? '',
          sequence: (decoded['seq'] as num?)?.toInt() ?? 0,
          delta: decoded['delta']?.toString() ?? '',
          contextVersion: (decoded['contextVersion'] as num?)?.toInt(),
        );
      } else if (type == 'assistant_done') {
        _closeAssistantTurn(
          decoded['turnId']?.toString() ?? '',
          sequence: (decoded['seq'] as num?)?.toInt() ?? 0,
          interrupted: false,
        );
      } else if (type == 'assistant_interrupted') {
        _closeAssistantTurn(
          decoded['turnId']?.toString() ?? '',
          sequence: (decoded['seq'] as num?)?.toInt() ?? 0,
          interrupted: true,
        );
      } else if (type == 'transcript') {
        final speaker = switch (decoded['speaker']?.toString()) {
          'user' => VoiceSpeaker.user,
          'system' => VoiceSpeaker.system,
          _ => VoiceSpeaker.assistant,
        };
        final transcript = VoiceTranscript(
          speaker: speaker,
          text: decoded['text']?.toString() ?? '',
          isFinal: decoded['isFinal'] != false,
          contextVersion: (decoded['contextVersion'] as num?)?.toInt(),
          createdAt: DateTime.now(),
        );
        final last = _transcripts.isEmpty ? null : _transcripts.last;
        if (last != null &&
            last.speaker == transcript.speaker &&
            !last.isFinal) {
          _transcripts[_transcripts.length - 1] = transcript;
        } else {
          _transcripts.add(transcript);
        }
        notifyListeners();
      } else if (type == 'state') {
        final next = decoded['state']?.toString();
        _setState(switch (next) {
          'thinking' => RealtimeVoiceState.thinking,
          'speaking' => RealtimeVoiceState.speaking,
          _ => RealtimeVoiceState.listening,
        });
      } else if (type == 'usage') {
        _usage = VoiceUsage(
          elapsed: _usage.elapsed,
          sttSeconds:
              (decoded['sttSeconds'] as num?)?.toInt() ?? _usage.sttSeconds,
          llmInputTokens:
              (decoded['llmInputTokens'] as num?)?.toInt() ??
              _usage.llmInputTokens,
          llmOutputTokens:
              (decoded['llmOutputTokens'] as num?)?.toInt() ??
              _usage.llmOutputTokens,
          ttsCharacters:
              (decoded['ttsCharacters'] as num?)?.toInt() ??
              _usage.ttsCharacters,
          budgetExceeded:
              decoded['budgetExceeded'] == true || _usage.budgetExceeded,
          budgetWarning:
              decoded['budgetWarning'] == true || _usage.budgetWarning,
        );
        notifyListeners();
      }
    } catch (_) {
      // Agent messages are advisory; malformed telemetry must not end a call.
    }
  }

  void _appendAssistantDelta({
    required String turnId,
    required int sequence,
    required String delta,
    required int? contextVersion,
  }) {
    if (turnId.isEmpty ||
        delta.isEmpty ||
        _closedAssistantTurns.contains(turnId)) {
      return;
    }
    final previousSequence = _assistantSequenceFor(turnId);
    if (sequence <= previousSequence) return;
    final existingIndex = _assistantTurnIndexes[turnId];
    final now = DateTime.now();
    if (existingIndex == null || existingIndex >= _transcripts.length) {
      _assistantTurnIndexes[turnId] = _transcripts.length;
      _transcripts.add(
        VoiceTranscript(
          speaker: VoiceSpeaker.assistant,
          text: delta,
          isFinal: false,
          contextVersion: contextVersion,
          createdAt: now,
          turnId: turnId,
          sequence: sequence,
        ),
      );
    } else {
      final previous = _transcripts[existingIndex];
      _transcripts[existingIndex] = VoiceTranscript(
        speaker: VoiceSpeaker.assistant,
        text: '${previous.text}$delta',
        isFinal: false,
        contextVersion: contextVersion ?? previous.contextVersion,
        createdAt: now,
        turnId: turnId,
        sequence: sequence,
      );
    }
    _activeAssistantTurnId = turnId;
    notifyListeners();
  }

  int _assistantSequenceFor(String turnId) {
    final index = _assistantTurnIndexes[turnId];
    if (index == null || index >= _transcripts.length) return -1;
    return _transcripts[index].sequence ?? -1;
  }

  void _closeAssistantTurn(
    String turnId, {
    required int sequence,
    required bool interrupted,
  }) {
    if (turnId.isEmpty || _closedAssistantTurns.contains(turnId)) return;
    final index = _assistantTurnIndexes[turnId];
    if (index == null || index >= _transcripts.length) {
      _closedAssistantTurns.add(turnId);
      return;
    }
    final previous = _transcripts[index];
    if (sequence < (previous.sequence ?? -1)) return;
    _transcripts[index] = VoiceTranscript(
      speaker: VoiceSpeaker.assistant,
      text: previous.text,
      isFinal: true,
      contextVersion: previous.contextVersion,
      createdAt: DateTime.now(),
      turnId: turnId,
      sequence: sequence,
      isInterrupted: interrupted,
    );
    _closedAssistantTurns.add(turnId);
    if (_activeAssistantTurnId == turnId) _activeAssistantTurnId = null;
    notifyListeners();
  }

  void _markAssistantInterrupted(String turnId) {
    final index = _assistantTurnIndexes[turnId];
    if (index == null || index >= _transcripts.length) return;
    final previous = _transcripts[index];
    if (previous.isFinal && previous.isInterrupted) return;
    _transcripts[index] = VoiceTranscript(
      speaker: VoiceSpeaker.assistant,
      text: previous.text,
      isFinal: true,
      contextVersion: previous.contextVersion,
      createdAt: DateTime.now(),
      turnId: turnId,
      sequence: previous.sequence,
      isInterrupted: true,
    );
    _closedAssistantTurns.add(turnId);
    _activeAssistantTurnId = null;
    notifyListeners();
  }

  void _startUsageTimer() {
    _usageTimer?.cancel();
    _usageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _startedAt;
      if (started == null) return;
      final elapsed = DateTime.now().difference(started);
      final warning = elapsed >= maxDuration - const Duration(minutes: 1);
      if (warning && !_budgetWarningSent) {
        _budgetWarningSent = true;
        unawaited(_publishEnvelope('usage', const {'budgetWarning': true}));
      }
      _usage = VoiceUsage(
        elapsed: elapsed,
        sttSeconds: _usage.sttSeconds,
        llmInputTokens: _usage.llmInputTokens,
        llmOutputTokens: _usage.llmOutputTokens,
        ttsCharacters: _usage.ttsCharacters,
        budgetExceeded: _usage.budgetExceeded,
        budgetWarning: _usage.budgetWarning || warning,
      );
      notifyListeners();
      if (elapsed >= maxDuration) unawaited(end());
    });
  }

  void _setState(RealtimeVoiceState state) {
    _state = state;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _setState(RealtimeVoiceState.error);
  }

  Future<void> _disposeRoom() async {
    _usageTimer?.cancel();
    _usageTimer = null;
    final listener = _listener;
    _listener = null;
    if (listener != null) await listener.dispose();
    final room = _room;
    _room = null;
    if (room != null) {
      try {
        await room.disconnect();
      } catch (_) {
        // A failed disconnect should not prevent the UI from closing.
      }
      await room.dispose();
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('permission') || text.contains('microphone')) {
      return '麦克风权限未授予，请在系统设置中允许小七使用麦克风';
    }
    if (text.contains('Socket') || text.contains('network')) {
      return '实时连接失败，请切换网络后重试';
    }
    return '实时语音暂时无法连接，请稍后重试';
  }

  @override
  void dispose() {
    unawaited(_disposeRoom());
    super.dispose();
  }
}
