import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:record/record.dart';

import 'speech_model_storage.dart';
import 'speech_recognition_worker.dart';

/// One in-memory recorder and local recognizer shared by voice entry points.
class SpeechRecognitionService {
  SpeechRecognitionService._();

  static final SpeechRecognitionService instance = SpeechRecognitionService._();

  static const _modelAsset =
      'assets/speech_models/paraformer-zh-small-2024-03-09/model.int8.onnx';
  static const _tokensAsset =
      'assets/speech_models/paraformer-zh-small-2024-03-09/tokens.txt';
  static const _vadModelAsset =
      'assets/speech_models/silero-vad-int8/silero_vad.int8.onnx';

  final AudioRecorder _recorder = AudioRecorder();
  Object? _sessionOwner;
  SpeechRecognitionWorker? _worker;
  Future<void>? _modelInitialization;
  Future<Uint8List>? _audioCollection;
  Uint8List? _lastAudioBytes;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  String? _recordingFilePath;
  int _sessionId = 0;
  bool _soundLevelReported = false;
  String _phase = 'idle';
  final Stopwatch _sessionClock = Stopwatch();

  void _log(String event) {
    final elapsed = _sessionOwner == null
        ? ''
        : ' +${_sessionClock.elapsedMilliseconds}ms';
    debugPrint('[SpeechRecognition] session=$_sessionId$elapsed $event');
  }

  bool acquireSession(Object owner) {
    if (_sessionOwner != null) return false;
    _sessionOwner = owner;
    _sessionId++;
    _sessionClock
      ..reset()
      ..start();
    _soundLevelReported = false;
    _phase = 'acquired';
    _log('phase=acquired');
    return true;
  }

  bool ownsSession(Object owner) => identical(_sessionOwner, owner);

  /// Loads model assets and warms the native models away from the UI isolate.
  Future<void> prepare() => _ensureRecognizer();

  void releaseSession(Object owner) {
    if (!identical(_sessionOwner, owner)) return;
    _log('phase=$_phase event=released');
    _sessionClock.stop();
    unawaited(_amplitudeSubscription?.cancel());
    _amplitudeSubscription = null;
    _audioCollection = null;
    _lastAudioBytes = null;
    _recordingFilePath = null;
    _sessionOwner = null;
    _phase = 'idle';
  }

  Future<void> initialize({required Object owner}) async {
    if (!identical(_sessionOwner, owner)) {
      throw StateError('Voice session is not owned by this page');
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw PlatformException(
        code: 'speech_platform_unsupported',
        message: 'On-device speech input is supported on Android and iOS',
      );
    }

    _phase = 'checking_microphone_permission';
    _log('phase=$_phase');
    if (!await _recorder.hasPermission()) {
      throw PlatformException(
        code: 'error_permission',
        message: 'Microphone permission was denied',
      );
    }
    _log('phase=permission_resolved');
    _phase = 'ready';
  }

  Future<void> _ensureRecognizer() async {
    final existingWorker = _worker;
    if (existingWorker != null && !existingWorker.isHealthy) {
      _worker = null;
      _modelInitialization = null;
      unawaited(existingWorker.dispose());
    }
    if (_worker != null && _modelInitialization == null) return;
    final current = _modelInitialization;
    if (current != null) {
      await current;
      return;
    }

    final attempt = _createWorker();
    _modelInitialization = attempt;
    try {
      await attempt;
    } catch (_) {
      if (identical(_modelInitialization, attempt)) {
        _modelInitialization = null;
      }
      rethrow;
    }
  }

  Future<void> _createWorker() async {
    final initializationClock = Stopwatch()..start();
    _log('event=local_model_initialization_started');
    final modelPath = await installSpeechModelAsset(_modelAsset);
    final tokensPath = await installSpeechModelAsset(_tokensAsset);
    final vadModelPath = await installSpeechModelAsset(_vadModelAsset);
    _log(
      'event=local_model_assets_ready '
      'elapsed_ms=${initializationClock.elapsedMilliseconds}',
    );
    final worker = SpeechRecognitionWorker();
    _worker = worker;
    try {
      await worker.initialize(
        recognizerPath: modelPath,
        tokensPath: tokensPath,
        vadPath: vadModelPath,
      );
      _log(
        'event=local_models_ready isolate=true '
        'elapsed_ms=${initializationClock.elapsedMilliseconds}',
      );
    } catch (_) {
      await worker.dispose();
      if (identical(_worker, worker)) _worker = null;
      rethrow;
    }
  }

  Future<void> startRecording({
    required Object owner,
    void Function(double decibels)? onSoundLevel,
  }) async {
    if (!identical(_sessionOwner, owner)) return;
    final sessionId = _sessionId;
    _phase = 'starting_recording';
    _log('phase=$_phase');
    final audioStream = await _recorder
        .startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          ),
        )
        .timeout(const Duration(seconds: 8));
    if (!identical(_sessionOwner, owner)) {
      await _recorder.cancel();
      return;
    }
    _audioCollection = _collectAudio(
      audioStream,
      owner: owner,
      sessionId: sessionId,
    );
    if (onSoundLevel != null) {
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) {
            if (!_isCurrentSession(owner, sessionId)) return;
            if (!_soundLevelReported) {
              _soundLevelReported = true;
              _log(
                'phase=$_phase sound_level=received '
                'dbfs=${amplitude.current.toStringAsFixed(1)}',
              );
            }
            onSoundLevel(amplitude.current);
          });
    }
    _phase = 'recording';
    _log('phase=$_phase');
    if (_worker?.isHealthy != true) {
      _log('event=local_model_warmup_started_during_recording');
      unawaited(
        _ensureRecognizer().catchError((Object error) {
          if (_isCurrentSession(owner, sessionId)) {
            reportException(owner, error, phase: 'local_model_warmup');
          }
        }),
      );
    }
  }

  /// Records directly to a private audio file without starting speech
  /// recognition or buffering the full recording in memory.
  Future<void> startAudioFileRecording({
    required Object owner,
    required String path,
    void Function(double decibels)? onSoundLevel,
  }) async {
    if (!identical(_sessionOwner, owner)) return;
    final sessionId = _sessionId;
    _audioCollection = null;
    _lastAudioBytes = null;
    _phase = 'starting_audio_file_recording';
    _log('phase=$_phase');
    await _recorder
        .start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 44100,
            numChannels: 1,
          ),
          path: path,
        )
        .timeout(const Duration(seconds: 8));
    if (!_isCurrentSession(owner, sessionId)) {
      await _recorder.cancel();
      return;
    }
    _recordingFilePath = path;
    if (onSoundLevel != null) {
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) {
            if (!_isCurrentSession(owner, sessionId)) return;
            onSoundLevel(amplitude.current);
          });
    }
    _phase = 'recording_audio_file';
    _log('phase=$_phase');
  }

  Future<String?> stopAudioFileRecording(Object owner) async {
    if (!identical(_sessionOwner, owner)) return null;
    _phase = 'stopping_audio_file_recording';
    _log('phase=$_phase');
    final outputPath = await _recorder.stop().timeout(
      const Duration(seconds: 4),
    );
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _phase = 'audio_file_saved';
    _log('phase=$_phase');
    return outputPath ?? _recordingFilePath;
  }

  Future<void> pauseRecording(Object owner) async {
    if (!identical(_sessionOwner, owner)) return;
    await _recorder.pause().timeout(const Duration(seconds: 4));
    _phase = 'paused';
    _log('phase=$_phase');
  }

  Future<void> resumeRecording(Object owner) async {
    if (!identical(_sessionOwner, owner)) return;
    await _recorder.resume().timeout(const Duration(seconds: 4));
    _phase = 'recording';
    _log('phase=$_phase');
  }

  Future<Uint8List> _collectAudio(
    Stream<Uint8List> stream, {
    required Object owner,
    required int sessionId,
  }) async {
    final bytes = BytesBuilder(copy: false);
    var hasReportedFirstChunk = false;
    await for (final chunk in stream) {
      if (!hasReportedFirstChunk && chunk.isNotEmpty) {
        hasReportedFirstChunk = true;
        if (_isCurrentSession(owner, sessionId)) {
          _log('phase=recording event=first_pcm');
        }
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<String> stopAndRecognize(Object owner) async {
    if (!identical(_sessionOwner, owner)) return '';
    final sessionId = _sessionId;
    _phase = 'stopping_recording';
    _log('phase=$_phase');
    await _recorder.stop().timeout(const Duration(seconds: 4));
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    _phase = 'waiting_for_audio';
    _log('phase=$_phase');
    final bytes = await _audioCollection?.timeout(const Duration(seconds: 4));
    _audioCollection = null;
    if (bytes == null || bytes.length < 2) return '';
    _lastAudioBytes = bytes;
    _log('event=audio_collected bytes=${bytes.length}');
    if (!_isCurrentSession(owner, sessionId)) return '';

    return _transcribe(owner, sessionId, bytes);
  }

  Future<String> retryRecognition(Object owner) async {
    if (!identical(_sessionOwner, owner)) return '';
    final bytes = _lastAudioBytes;
    if (bytes == null || bytes.length < 2) return '';
    return _transcribe(owner, _sessionId, bytes);
  }

  Future<String> _transcribe(
    Object owner,
    int sessionId,
    Uint8List bytes,
  ) async {
    if (!_isCurrentSession(owner, sessionId)) return '';
    _phase = 'loading_local_model';
    _log('phase=$_phase');
    await _ensureRecognizer();
    if (!_isCurrentSession(owner, sessionId)) return '';

    _phase = 'transcribing_locally';
    final transcriptionClock = Stopwatch()..start();
    _log('phase=$_phase bytes=${bytes.length}');
    final worker = _worker;
    if (worker == null) throw StateError('Local speech model is not loaded');
    final result = await worker.transcribe(bytes, sessionId: sessionId);
    if (!_isCurrentSession(owner, sessionId)) return '';
    _log(
      'event=worker_metrics '
      'convert_ms=${result['conversionMilliseconds']} '
      'vad_ms=${result['vadMilliseconds']} '
      'decode_ms=${result['decodeMilliseconds']} '
      'voiced_samples=${result['voicedSamples']}',
    );
    final text = result['result'] as String;
    _log(
      text.isEmpty
          ? 'phase=no_speech_detected elapsed_ms=${transcriptionClock.elapsedMilliseconds}'
          : 'phase=result_received chars=${text.length} elapsed_ms=${transcriptionClock.elapsedMilliseconds}',
    );
    return text;
  }

  bool _isCurrentSession(Object owner, int sessionId) =>
      identical(_sessionOwner, owner) && _sessionId == sessionId;

  void setPhase(Object owner, String phase) {
    if (!identical(_sessionOwner, owner)) return;
    _phase = phase;
    _log('phase=$phase');
  }

  void reportException(Object owner, Object error, {String? phase}) {
    if (!identical(_sessionOwner, owner) && phase == null) return;
    final code = error is PlatformException ? ' code=${error.code}' : '';
    _log('phase=${phase ?? _phase} exception=${error.runtimeType}$code');
  }

  String messageForException(Object error) {
    if (error is PlatformException &&
        error.code.toLowerCase().contains('permission')) {
      return '请允许麦克风权限后再次按住说话；语音只在本机识别，不会上传';
    }
    if (error is TimeoutException) {
      return '本机语音处理超时，录音没有上传，请重试';
    }
    return '本机语音识别未能完成，录音没有上传，请重试';
  }

  Future<void> cancelSession(Object owner) async {
    if (!identical(_sessionOwner, owner)) return;
    setPhase(owner, 'cancelling');
    try {
      await _recorder.cancel().timeout(const Duration(seconds: 3));
    } catch (error) {
      reportException(owner, error, phase: 'cancelling');
    }
    try {
      await _audioCollection?.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Cancellation discards any remaining in-memory audio.
    }
    releaseSession(owner);
  }
}
