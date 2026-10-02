import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book_source.dart';

/// Keeps a small number of PDF documents warm while a reader route is rebuilt.
///
/// A [PdfDocumentRefKey] only shares a document while its listenable is still
/// referenced. The pin listener below makes that lifetime explicit; the LRU
/// bound prevents a long browsing session from retaining every opened book.
class PdfDocumentSessionCache {
  PdfDocumentSessionCache._();

  static const int _maxEntries = 2;
  static final LinkedHashMap<String, _PdfDocumentSession> _sessions =
      LinkedHashMap<String, _PdfDocumentSession>();

  static PdfDocumentRef obtain(BookSourceRecord source) {
    final key = _keyFor(source);
    final existing = _sessions.remove(key);
    if (existing != null) {
      _sessions[key] = existing;
      return existing.ref;
    }

    final ref = PdfDocumentRefFile(
      source.filePath,
      autoDispose: true,
      key: PdfDocumentRefKey(key),
    );
    final listenable = ref.resolveListenable();
    final removePin = listenable.addListener(() {});
    _sessions[key] = _PdfDocumentSession(ref: ref, removePin: removePin);

    while (_sessions.length > _maxEntries) {
      final oldestKey = _sessions.keys.first;
      final oldest = _sessions.remove(oldestKey);
      oldest?.removePin();
    }
    return ref;
  }

  static String _keyFor(BookSourceRecord source) =>
      'book-source:${source.id}:${source.contentHash}';
}

class _PdfDocumentSession {
  const _PdfDocumentSession({required this.ref, required this.removePin});

  final PdfDocumentRef ref;
  final VoidCallback removePin;
}
