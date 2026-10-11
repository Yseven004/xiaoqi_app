import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class HomeChatDrawingDraft {
  const HomeChatDrawingDraft({
    required this.path,
    required this.document,
    this.backgroundBytes,
    required this.isEditing,
    this.wasResumed = false,
  });

  final String path;
  final Map<String, Object?> document;
  final Uint8List? backgroundBytes;
  final bool isEditing;
  final bool wasResumed;
}

/// Stores editable drawing sessions separately from the immutable PNG sent to chat.
class HomeChatDrawingDraftStore {
  HomeChatDrawingDraftStore({this.rootDirectory, this.accountScope = 'local'});

  final Directory? rootDirectory;
  final String accountScope;

  Future<String> _conversationDirectory(String conversationId) async {
    final root = rootDirectory ?? await getApplicationSupportDirectory();
    final safeScope = accountScope.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safeId = conversationId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final directory = Directory(
      p.join(root.path, 'home_chat_drawing_drafts', safeScope, safeId),
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  Future<HomeChatDrawingDraft> open(
    String conversationId, {
    String? draftPath,
  }) async {
    final directory = await _conversationDirectory(conversationId);
    final isEditing = draftPath != null;
    if (draftPath == null) {
      final activeFile = File(p.join(directory, 'active.json'));
      if (await activeFile.exists()) {
        final activePath = (await activeFile.readAsString()).trim();
        if (_isInside(directory, activePath) &&
            await File(activePath).exists()) {
          final existing = await _read(
            activePath,
            isEditing: false,
            wasResumed: true,
          );
          if (existing != null) return existing;
        }
      }
      draftPath = p.join(
        directory,
        'drawing_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}.json',
      );
      await _replaceText(activeFile, draftPath);
    } else if (!_isInside(directory, draftPath)) {
      throw const FormatException('绘图草稿路径无效');
    }

    final resumedEdit =
        isEditing && await File(_baselinePath(draftPath)).exists();
    final draft = await _read(
      draftPath,
      isEditing: isEditing,
      wasResumed: resumedEdit,
    );
    if (draft != null) {
      if (isEditing) await _createBaselineIfMissing(draft);
      return draft;
    }
    final blank = HomeChatDrawingDraft(
      path: draftPath,
      document: const {'schemaVersion': 1, 'drawables': <Object?>[]},
      isEditing: isEditing,
    );
    if (isEditing) await _createBaselineIfMissing(blank);
    return blank;
  }

  Future<String?> save(
    String draftPath,
    Map<String, Object?> document, {
    Uint8List? backgroundBytes,
  }) async {
    String? backgroundPath = document['backgroundPath'] as String?;
    final draftFile = File(draftPath);
    final previousBackgroundPath = await _storedBackgroundPath(draftFile);
    if (backgroundBytes != null) {
      backgroundPath =
          '$draftPath.${DateTime.now().microsecondsSinceEpoch}.png';
      final backgroundTemp = File('$backgroundPath.tmp');
      try {
        await backgroundTemp.writeAsBytes(backgroundBytes, flush: true);
        await backgroundTemp.rename(backgroundPath);
      } catch (_) {
        if (await backgroundTemp.exists()) await backgroundTemp.delete();
        rethrow;
      }
      if (p.dirname(p.normalize(backgroundPath)) !=
          p.dirname(p.normalize(draftPath))) {
        throw const FormatException('绘图底图路径无效');
      }
    } else if (backgroundPath != null &&
        (p.dirname(p.normalize(backgroundPath)) !=
                p.dirname(p.normalize(draftPath)) ||
            !await File(backgroundPath).exists())) {
      backgroundPath = null;
    }
    final savedDocument = <String, Object?>{
      ...document,
      'backgroundPath': backgroundPath,
    };
    await draftFile.parent.create(recursive: true);
    final temp = File('$draftPath.tmp');
    await temp.writeAsString(jsonEncode(savedDocument), flush: true);
    await _replaceFile(draftFile, temp);
    if (previousBackgroundPath != null &&
        previousBackgroundPath != backgroundPath &&
        p.dirname(p.normalize(previousBackgroundPath)) ==
            p.dirname(p.normalize(draftPath))) {
      final previous = File(previousBackgroundPath);
      if (await previous.exists()) await previous.delete();
    }
    return backgroundPath;
  }

  Future<void> finish(String conversationId, String draftPath) async {
    final directory = await _conversationDirectory(conversationId);
    final activeFile = File(p.join(directory, 'active.json'));
    if (await activeFile.exists() &&
        (await activeFile.readAsString()).trim() == draftPath) {
      await activeFile.delete();
    }
    await _deleteBaseline(draftPath);
  }

  Future<void> reactivate(String conversationId, String draftPath) async {
    final directory = await _conversationDirectory(conversationId);
    if (!_isInside(directory, draftPath)) {
      throw const FormatException('绘图草稿路径无效');
    }
    await _replaceText(File(p.join(directory, 'active.json')), draftPath);
  }

  Future<void> discard(
    String conversationId,
    HomeChatDrawingDraft draft,
  ) async {
    if (draft.isEditing) {
      await _restoreBaseline(draft.path);
      return;
    }
    await finish(conversationId, draft.path);
    await _deleteDraftFiles(draft.path);
  }

  Future<void> delete(String conversationId, String draftPath) async {
    final directory = await _conversationDirectory(conversationId);
    if (!_isInside(directory, draftPath)) {
      throw const FormatException('绘图草稿路径无效');
    }
    await finish(conversationId, draftPath);
    await _deleteDraftFiles(draftPath);
  }

  Future<void> _createBaselineIfMissing(HomeChatDrawingDraft draft) async {
    final baseline = _baselinePath(draft.path);
    if (await File(baseline).exists()) return;
    await save(
      baseline,
      draft.document,
      backgroundBytes: draft.backgroundBytes,
    );
  }

  Future<void> _restoreBaseline(String draftPath) async {
    final baseline = await _read(_baselinePath(draftPath), isEditing: false);
    if (baseline != null) {
      await save(
        draftPath,
        baseline.document,
        backgroundBytes: baseline.backgroundBytes,
      );
    }
    await _deleteBaseline(draftPath);
  }

  Future<void> _deleteBaseline(String draftPath) async {
    await _deleteDraftFiles(_baselinePath(draftPath));
  }

  String _baselinePath(String draftPath) => '$draftPath.baseline';

  Future<String?> _storedBackgroundPath(File draftFile) async {
    if (!await draftFile.exists()) return null;
    try {
      final decoded = jsonDecode(await draftFile.readAsString());
      final path = decoded is Map ? decoded['backgroundPath'] : null;
      if (path is String &&
          p.dirname(p.normalize(path)) ==
              p.dirname(p.normalize(draftFile.path))) {
        return path;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _deleteDraftFiles(String draftPath) async {
    final file = File(draftPath);
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['backgroundPath'] is String) {
          final background = File(decoded['backgroundPath'] as String);
          if (p.dirname(background.path) == p.dirname(draftPath) &&
              await background.exists()) {
            await background.delete();
          }
        }
      } on FormatException {
        // A malformed draft should not prevent removing its remaining files.
      }
      await file.delete();
    }
    for (final suffix in ['.tmp', '.bak']) {
      final extra = File('$draftPath$suffix');
      if (await extra.exists()) await extra.delete();
    }
  }

  Future<HomeChatDrawingDraft?> _read(
    String draftPath, {
    required bool isEditing,
    bool wasResumed = false,
  }) async {
    final file = File(draftPath);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('绘图草稿格式无效');
    }
    final backgroundPath = decoded['backgroundPath'];
    Uint8List? backgroundBytes;
    if (backgroundPath is String && backgroundPath.isNotEmpty) {
      if (p.dirname(p.normalize(backgroundPath)) !=
          p.dirname(p.normalize(draftPath))) {
        throw const FormatException('绘图底图路径无效');
      }
      final background = File(backgroundPath);
      if (await background.exists()) {
        backgroundBytes = await background.readAsBytes();
      }
    }
    return HomeChatDrawingDraft(
      path: draftPath,
      document: Map<String, Object?>.from(decoded),
      backgroundBytes: backgroundBytes,
      isEditing: isEditing,
      wasResumed: wasResumed,
    );
  }

  bool _isInside(String directory, String target) {
    final normalizedDirectory = p.normalize(p.absolute(directory));
    final normalizedTarget = p.normalize(p.absolute(target));
    return p.isWithin(normalizedDirectory, normalizedTarget) &&
        normalizedTarget.endsWith('.json');
  }

  Future<void> _replaceText(File target, String contents) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await _replaceFile(target, temp);
  }

  Future<void> _replaceFile(File target, File temp) async {
    final backup = File('${target.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temp.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }
}
