import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book_recognition.dart';

/// Stores catalogue covers privately on the device. Remote URLs remain only
/// as source hints; a missing local file can be downloaded again later.
class BookCoverStorage {
  BookCoverStorage({
    http.Client? httpClient,
    Duration? timeout,
    Future<Directory> Function()? directoryFactory,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout ?? const Duration(seconds: 8),
       _directoryFactory = directoryFactory ?? getApplicationSupportDirectory;

  final http.Client _httpClient;
  final Duration _timeout;
  final Future<Directory> Function() _directoryFactory;

  Future<BookRecord> persistCatalogueCover(BookRecord book) async {
    if (book.coverType == 'uploaded' || book.coverType == 'template') {
      return book;
    }
    if (book.coverUrl.trim().isEmpty || book.isbn13.trim().isEmpty) {
      return book;
    }
    if (book.coverPath.trim().isNotEmpty &&
        await File(book.coverPath).exists()) {
      return book;
    }

    final source = Uri.tryParse(book.coverUrl.trim());
    if (source == null || !source.hasScheme || source.host.isEmpty) {
      return book;
    }
    final uri = source.scheme.toLowerCase() == 'http'
        ? source.replace(scheme: 'https')
        : source;
    if (uri.scheme != 'https') return book;

    try {
      final response = await _httpClient.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return book;
      }
      if (response.bodyBytes.isEmpty ||
          response.bodyBytes.length > 5 * 1024 * 1024) {
        return book;
      }
      final contentType =
          response.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() ??
          '';
      if (contentType.isNotEmpty && !contentType.startsWith('image/')) {
        return book;
      }

      final root = await _directoryFactory();
      final directory = Directory(
        p.join(root.path, 'book_covers', 'catalogue'),
      );
      await directory.create(recursive: true);
      final extension = _extension(contentType, uri.path);
      final target = File(
        p.join(directory.path, 'cover_${book.isbn13}$extension'),
      );
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return book.copyWith(
        coverPath: target.path,
        coverType: book.coverType == 'auto' ? 'official' : book.coverType,
      );
    } on TimeoutException {
      return book;
    } catch (_) {
      return book;
    }
  }

  String _extension(String contentType, String path) {
    final fromType = switch (contentType) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/heic' => '.heic',
      'image/heif' => '.heif',
      _ => '',
    };
    if (fromType.isNotEmpty) return fromType;
    final candidate = p.extension(path).toLowerCase();
    return const {
          '.jpg',
          '.jpeg',
          '.png',
          '.webp',
          '.heic',
          '.heif',
        }.contains(candidate)
        ? candidate
        : '.jpg';
  }
}
