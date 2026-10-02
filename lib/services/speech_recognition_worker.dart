import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Owns sherpa's native recognizer on a long-lived isolate so FFI work cannot
/// block the Flutter UI isolate.
class SpeechRecognitionWorker {
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final Map<int, Timer> _timeouts = {};

  Isolate? _isolate;
  SendPort? _commandPort;
  Object? _terminalError;
  int _nextId = 0;
  Future<void>? _startOperation;

  bool get isHealthy => _terminalError == null && _isolate != null;

  Future<void> start() {
    final error = _terminalError;
    if (error != null) return Future<void>.error(error);
    return _startOperation ??= _spawn();
  }

  Future<void> _spawn() async {
    _messages.listen(_handleMessage);
    _errors.listen((dynamic error) {
      _fail(StateError('Speech worker failed: $error'));
    });
    _exits.listen((_) {
      _fail(StateError('Speech worker exited unexpectedly'));
    });
    _isolate = await Isolate.spawn(
      _speechWorkerMain,
      _messages.sendPort,
      onError: _errors.sendPort,
      onExit: _exits.sendPort,
    );
    await _ready.future.timeout(const Duration(seconds: 8));
  }

  Future<void> initialize({
    required String recognizerPath,
    required String tokensPath,
    required String vadPath,
  }) async {
    await start();
    await _request('initialize', <String, Object?>{
      'recognizerPath': recognizerPath,
      'tokensPath': tokensPath,
      'vadPath': vadPath,
    }, timeout: const Duration(seconds: 60));
  }

  Future<Map<String, Object?>> transcribe(
    Uint8List pcm16, {
    required int sessionId,
  }) async {
    await start();
    final result = await _request('transcribe', <String, Object?>{
      'sessionId': sessionId,
      'audio': TransferableTypedData.fromList([pcm16]),
    }, timeout: const Duration(seconds: 60));
    if ((result['sessionId'] as num?)?.toInt() != sessionId) {
      throw StateError('Speech worker returned a result for another session');
    }
    return result;
  }

  Future<Map<String, Object?>> _request(
    String command,
    Map<String, Object?> payload, {
    required Duration timeout,
  }) {
    final terminalError = _terminalError;
    if (terminalError != null)
      return Future<Map<String, Object?>>.error(terminalError);
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _timeouts[id] = Timer(timeout, () {
      _pending.remove(id);
      _timeouts.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Speech worker $command timed out'),
        );
      }
    });
    _ready.future
        .then((port) {
          if (!_pending.containsKey(id)) return;
          _commandPort = port;
          port.send(<String, Object?>{
            'id': id,
            'command': command,
            ...payload,
          });
        })
        .catchError((Object error) {
          final pending = _pending.remove(id);
          _timeouts.remove(id)?.cancel();
          if (pending != null && !pending.isCompleted)
            pending.completeError(error);
        });
    return completer.future;
  }

  void _handleMessage(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! Map) return;
    final id = (message['id'] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    _timeouts.remove(id)?.cancel();
    final error = message['error'];
    if (error != null) {
      completer.completeError(StateError(error.toString()));
    } else {
      completer.complete(
        Map<String, Object?>.from(message.cast<String, Object?>()),
      );
    }
  }

  void _fail(Object error) {
    _terminalError ??= error;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final timer in _timeouts.values) {
      timer.cancel();
    }
    _timeouts.clear();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    if (_terminalError == null && _commandPort != null) {
      try {
        await _request(
          'dispose',
          const <String, Object?>{},
          timeout: const Duration(seconds: 2),
        );
      } catch (_) {
        // Leave a timed-out native call alone; the queued dispose command will
        // run if that call returns. Do not kill an isolate inside native FFI.
      }
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    _messages.close();
    _errors.close();
    _exits.close();
  }
}

void _speechWorkerMain(SendPort mainPort) {
  final commands = ReceivePort();
  mainPort.send(commands.sendPort);
  sherpa.initBindings();
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;

  commands.listen((dynamic message) {
    if (message is! Map) return;
    final id = (message['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      switch (message['command']) {
        case 'initialize':
          recognizer?.free();
          vad?.free();
          recognizer = sherpa.OfflineRecognizer(
            sherpa.OfflineRecognizerConfig(
              model: sherpa.OfflineModelConfig(
                paraformer: sherpa.OfflineParaformerModelConfig(
                  model: message['recognizerPath'] as String,
                ),
                tokens: message['tokensPath'] as String,
                numThreads: 2,
                provider: 'cpu',
              ),
            ),
          );
          vad = sherpa.VoiceActivityDetector(
            config: sherpa.VadModelConfig(
              sileroVad: sherpa.SileroVadModelConfig(
                model: message['vadPath'] as String,
                threshold: 0.5,
                minSilenceDuration: 0.5,
                minSpeechDuration: 0.25,
                windowSize: 512,
              ),
              sampleRate: 16000,
              numThreads: 1,
              provider: 'cpu',
              debug: false,
            ),
            bufferSizeInSeconds: 30,
          );
          mainPort.send(<String, Object?>{'id': id, 'result': true});
          break;
        case 'transcribe':
          final conversionClock = Stopwatch()..start();
          final audio = _pcm16ToFloat(
            (message['audio'] as TransferableTypedData)
                .materialize()
                .asUint8List(),
          );
          final conversionMilliseconds = conversionClock.elapsedMilliseconds;
          final vadClock = Stopwatch()..start();
          final speech = _detectSpeech(vad!, audio);
          final vadMilliseconds = vadClock.elapsedMilliseconds;
          if (speech.isEmpty) {
            mainPort.send(<String, Object?>{
              'id': id,
              'sessionId': message['sessionId'],
              'result': '',
              'conversionMilliseconds': conversionMilliseconds,
              'vadMilliseconds': vadMilliseconds,
              'decodeMilliseconds': 0,
              'voicedSamples': 0,
            });
            break;
          }
          final stream = recognizer!.createStream();
          final decodeClock = Stopwatch()..start();
          try {
            stream.acceptWaveform(samples: speech, sampleRate: 16000);
            recognizer!.decode(stream);
            final text = recognizer!.getResult(stream).text.trim();
            mainPort.send(<String, Object?>{
              'id': id,
              'sessionId': message['sessionId'],
              'result': text,
              'conversionMilliseconds': conversionMilliseconds,
              'vadMilliseconds': vadMilliseconds,
              'decodeMilliseconds': decodeClock.elapsedMilliseconds,
              'voicedSamples': speech.length,
            });
          } finally {
            stream.free();
          }
          break;
        case 'dispose':
          recognizer?.free();
          recognizer = null;
          vad?.free();
          vad = null;
          mainPort.send(<String, Object?>{'id': id, 'result': true});
          commands.close();
          break;
        default:
          throw StateError('Unknown speech worker command');
      }
    } catch (error, stack) {
      mainPort.send(<String, Object?>{'id': id, 'error': '$error\n$stack'});
    }
  });
}

Float32List _pcm16ToFloat(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  final samples = Float32List(count);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

Float32List _detectSpeech(
  sherpa.VoiceActivityDetector? vad,
  Float32List audio,
) {
  if (vad == null)
    throw StateError('Local voice activity detector is not loaded');

  const frameSize = 512;
  final segments = <Float32List>[];
  vad.reset();
  try {
    for (var offset = 0; offset < audio.length; offset += frameSize) {
      final frame = Float32List(frameSize);
      final end = offset + frameSize < audio.length
          ? offset + frameSize
          : audio.length;
      frame.setRange(0, end - offset, audio, offset);
      vad.acceptWaveform(frame);
      _drainVadSegments(vad, segments);
    }
    vad.flush();
    _drainVadSegments(vad, segments);
  } finally {
    vad.reset();
  }

  final sampleCount = segments.fold<int>(
    0,
    (sum, segment) => sum + segment.length,
  );
  if (sampleCount == 0) return Float32List(0);
  final speech = Float32List(sampleCount);
  var offset = 0;
  for (final segment in segments) {
    speech.setRange(offset, offset + segment.length, segment);
    offset += segment.length;
  }
  return speech;
}

void _drainVadSegments(
  sherpa.VoiceActivityDetector vad,
  List<Float32List> segments,
) {
  while (!vad.isEmpty()) {
    final samples = vad.front().samples;
    vad.pop();
    if (samples.isNotEmpty) segments.add(samples);
  }
}
