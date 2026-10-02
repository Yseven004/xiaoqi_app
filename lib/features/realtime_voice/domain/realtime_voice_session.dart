import 'package:flutter/foundation.dart';

import 'voice_context_snapshot.dart';

enum RealtimeVoiceState {
  disconnected,
  connecting,
  listening,
  thinking,
  speaking,
  reconnecting,
  ending,
  error,
}

enum VoiceSpeaker { user, assistant, system }

class VoiceTranscript {
  const VoiceTranscript({
    required this.speaker,
    required this.text,
    required this.isFinal,
    required this.contextVersion,
    required this.createdAt,
    this.turnId,
    this.sequence,
    this.isInterrupted = false,
  });

  final VoiceSpeaker speaker;
  final String text;
  final bool isFinal;
  final int? contextVersion;
  final DateTime createdAt;
  final String? turnId;
  final int? sequence;
  final bool isInterrupted;
}

class VoiceUsage {
  const VoiceUsage({
    required this.elapsed,
    required this.sttSeconds,
    required this.llmInputTokens,
    required this.llmOutputTokens,
    required this.ttsCharacters,
    required this.budgetExceeded,
    required this.budgetWarning,
  });

  const VoiceUsage.empty()
    : elapsed = Duration.zero,
      sttSeconds = 0,
      llmInputTokens = 0,
      llmOutputTokens = 0,
      ttsCharacters = 0,
      budgetExceeded = false,
      budgetWarning = false;

  final Duration elapsed;
  final int sttSeconds;
  final int llmInputTokens;
  final int llmOutputTokens;
  final int ttsCharacters;
  final bool budgetExceeded;
  final bool budgetWarning;
}

/// Stable boundary used by the UI. A future domestic RTC provider can replace
/// the LiveKit implementation without changing the page/editor integration.
abstract class RealtimeVoiceSession extends ChangeNotifier {
  RealtimeVoiceState get state;
  String? get errorMessage;
  bool get isMuted;
  VoiceContextSnapshot? get context;
  List<VoiceTranscript> get transcripts;
  VoiceUsage get usage;
  bool get isConfigured;

  Future<void> start({required VoiceContextSnapshot context});
  Future<void> updateContext(VoiceContextSnapshot context);
  Future<void> mute();
  Future<void> unmute();
  Future<void> interrupt();
  Future<void> end();
}
