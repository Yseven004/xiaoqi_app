import 'dart:typed_data';

/// Reads a JPEG EXIF orientation tag without decoding or rewriting pixels.
class JpegExif {
  JpegExif._();

  static const int _app1 = 0xe1;
  static const int _startOfScan = 0xda;
  static const int _endOfImage = 0xd9;
  static const int _orientationTag = 0x0112;

  /// Returns an EXIF orientation from 1 to 8, or 1 when it is unavailable.
  static int orientation(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return 1;
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return 1;
      final marker = bytes[offset++];
      if (marker == _startOfScan || marker == _endOfImage) return 1;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) return 1;

      final segmentLength = _u16(bytes, offset, littleEndian: false);
      if (segmentLength < 2 || offset + segmentLength > bytes.length) {
        return 1;
      }
      if (marker == _app1 && segmentLength >= 8) {
        final exifStart = offset + 2;
        if (_hasExifHeader(bytes, exifStart)) {
          final value = _readTiffOrientation(bytes, exifStart + 6);
          if (value >= 1 && value <= 8) return value;
        }
      }
      offset += segmentLength;
    }
    return 1;
  }

  static bool _hasExifHeader(Uint8List bytes, int offset) {
    const header = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
    if (offset + header.length > bytes.length) return false;
    for (var i = 0; i < header.length; i++) {
      if (bytes[offset + i] != header[i]) return false;
    }
    return true;
  }

  static int _readTiffOrientation(Uint8List bytes, int tiffStart) {
    if (tiffStart + 8 > bytes.length) return 1;
    final littleEndian =
        bytes[tiffStart] == 0x49 && bytes[tiffStart + 1] == 0x49;
    final bigEndian = bytes[tiffStart] == 0x4d && bytes[tiffStart + 1] == 0x4d;
    if (!littleEndian && !bigEndian) return 1;
    if (_u16(bytes, tiffStart + 2, littleEndian: littleEndian) != 42) {
      return 1;
    }
    final ifdOffset = _u32(bytes, tiffStart + 4, littleEndian: littleEndian);
    final ifdStart = tiffStart + ifdOffset;
    if (ifdStart + 2 > bytes.length) return 1;
    final entryCount = _u16(bytes, ifdStart, littleEndian: littleEndian);
    for (var i = 0; i < entryCount; i++) {
      final entryStart = ifdStart + 2 + i * 12;
      if (entryStart + 12 > bytes.length) return 1;
      final tag = _u16(bytes, entryStart, littleEndian: littleEndian);
      if (tag != _orientationTag) continue;
      final type = _u16(bytes, entryStart + 2, littleEndian: littleEndian);
      final count = _u32(bytes, entryStart + 4, littleEndian: littleEndian);
      if (type != 3 || count < 1) return 1;
      return _u16(bytes, entryStart + 8, littleEndian: littleEndian);
    }
    return 1;
  }

  static int _u16(Uint8List bytes, int offset, {required bool littleEndian}) {
    if (offset < 0 || offset + 2 > bytes.length) return 0;
    final a = bytes[offset];
    final b = bytes[offset + 1];
    return littleEndian ? a | (b << 8) : (a << 8) | b;
  }

  static int _u32(Uint8List bytes, int offset, {required bool littleEndian}) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    final a = bytes[offset];
    final b = bytes[offset + 1];
    final c = bytes[offset + 2];
    final d = bytes[offset + 3];
    return littleEndian
        ? a | (b << 8) | (c << 16) | (d << 24)
        : (a << 24) | (b << 16) | (c << 8) | d;
  }
}
