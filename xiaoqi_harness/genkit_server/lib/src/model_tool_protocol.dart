/// Holds a possible protocol prefix until it can be distinguished from prose.
/// Once a control sequence starts, its parameters must never become public text.
class ModelToolProtocolBuffer {
  static const _markers = ['<｜DSML｜', '</｜DSML｜', '<|DSML|', '</|DSML|'];
  String _pending = '';
  bool sawProtocol = false;

  String add(String text) {
    if (sawProtocol) return '';
    final value = _pending + text;
    var markerAt = value.length;
    for (final marker in _markers) {
      final index = value.indexOf(marker);
      if (index >= 0 && index < markerAt) markerAt = index;
    }
    if (markerAt < value.length) {
      sawProtocol = true;
      _pending = '';
      return value.substring(0, markerAt);
    }
    var held = 0;
    for (final marker in _markers) {
      for (var length = 1; length < marker.length; length++) {
        if (length > held && value.endsWith(marker.substring(0, length))) {
          held = length;
        }
      }
    }
    _pending = value.substring(value.length - held);
    return value.substring(0, value.length - held);
  }

  String finish() {
    final tail = _pending;
    _pending = '';
    if (sawProtocol) return '';
    if (tail.contains('｜') || tail.contains('|')) {
      sawProtocol = true;
      return '';
    }
    return tail;
  }
}

bool containsModelToolProtocol(String text) {
  final buffer = ModelToolProtocolBuffer()..add(text);
  buffer.finish();
  return buffer.sawProtocol;
}

String stripModelToolProtocol(String text) {
  final buffer = ModelToolProtocolBuffer();
  final visible = buffer.add(text);
  return visible + buffer.finish();
}
