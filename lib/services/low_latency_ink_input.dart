import 'dart:async';

import 'package:flutter/services.dart';

/// A batch of platform ink samples collected between two Flutter frames.
///
/// Actual samples are the only samples that may be persisted. Predicted
/// samples are temporary wet-ink hints and must be discarded when the next
/// actual event arrives.
class InkPointerSample {
  const InkPointerSample({
    required this.x,
    required this.y,
    required this.timeMicros,
    required this.pressure,
    required this.predicted,
  });

  final double x;
  final double y;
  final int timeMicros;
  final double pressure;
  final bool predicted;
}

enum InkPointerPhase { down, move, up, cancel }

class InkPointerPacket {
  const InkPointerPacket({
    required this.phase,
    required this.pointer,
    required this.samples,
  });

  final InkPointerPhase phase;
  final int pointer;
  final List<InkPointerSample> samples;
}

/// Platform bridge for high-fidelity ink input.
///
/// Android supplies unbuffered MotionEvent batches (including historical
/// samples); iOS supplies coalesced and predicted UITouch samples. Desktop and
/// web simply return false and continue using Flutter pointer events.
class LowLatencyInkInput {
  LowLatencyInkInput._();

  static final instance = LowLatencyInkInput._();

  static const _controlChannel = MethodChannel('xiaoqi_app/ink_input_control');
  static const _eventChannel = EventChannel('xiaoqi_app/ink_input');

  Stream<InkPointerPacket>? _packets;

  Stream<InkPointerPacket> get packets => _packets ??= _eventChannel
      .receiveBroadcastStream()
      .map(_decode)
      .asBroadcastStream();

  Future<bool> setEnabled(bool enabled) async {
    try {
      await _controlChannel.invokeMethod<void>('setEnabled', enabled);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  InkPointerPacket _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Invalid ink pointer packet');
    }
    final phase = switch (raw['phase']?.toString()) {
      'down' => InkPointerPhase.down,
      'move' => InkPointerPhase.move,
      'up' => InkPointerPhase.up,
      'cancel' => InkPointerPhase.cancel,
      _ => throw const FormatException('Unknown ink pointer phase'),
    };
    final rawSamples = raw['samples'];
    final samples = <InkPointerSample>[];
    if (rawSamples is List) {
      for (final item in rawSamples) {
        if (item is! Map) continue;
        final x = _number(item['x']);
        final y = _number(item['y']);
        if (!x.isFinite || !y.isFinite) continue;
        samples.add(
          InkPointerSample(
            x: x,
            y: y,
            timeMicros: _integer(item['timeMicros']),
            pressure: _number(item['pressure']).clamp(0, 1).toDouble(),
            predicted: item['predicted'] == true,
          ),
        );
      }
    }
    return InkPointerPacket(
      phase: phase,
      pointer: _integer(raw['pointer']),
      samples: samples,
    );
  }

  static double _number(Object? value) =>
      value is num ? value.toDouble() : double.nan;

  static int _integer(Object? value) => value is num ? value.toInt() : 0;
}
