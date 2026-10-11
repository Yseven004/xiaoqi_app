import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/services/home_chat_drawing_draft_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HomeChatDrawingDraftStore', () {
    late Directory root;
    late HomeChatDrawingDraftStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('xiaoqi-drawing-test-');
      store = HomeChatDrawingDraftStore(rootDirectory: root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'resumes a draft per conversation and starts fresh after completion',
      () async {
        final first = await store.open('conversation-a');
        await store.save(first.path, const {
          'schemaVersion': 1,
          'drawables': ['arrow'],
        });

        final resumed = await store.open('conversation-a');
        final other = await store.open('conversation-b');

        expect(resumed.path, first.path);
        expect(resumed.wasResumed, isTrue);
        expect(resumed.document['drawables'], ['arrow']);
        expect(other.path, isNot(first.path));

        await store.finish('conversation-a', first.path);
        final fresh = await store.open('conversation-a');
        expect(fresh.path, isNot(first.path));
        expect(fresh.document['drawables'], isEmpty);
      },
    );

    test('discarding an edit restores its pre-edit scene', () async {
      final draft = await store.open('conversation-a');
      final originalBackground = Uint8List.fromList([1, 2, 3]);
      await store.save(draft.path, const {
        'schemaVersion': 1,
        'drawables': ['original'],
      }, backgroundBytes: originalBackground);
      await store.finish('conversation-a', draft.path);

      final editing = await store.open('conversation-a', draftPath: draft.path);
      final changedBackground = Uint8List.fromList([4, 5, 6]);
      await store.save(editing.path, const {
        'schemaVersion': 1,
        'drawables': ['changed'],
      }, backgroundBytes: changedBackground);
      await store.discard('conversation-a', editing);
      expect(File('${draft.path}.baseline').existsSync(), isFalse);

      final restored = await store.open(
        'conversation-a',
        draftPath: draft.path,
      );
      expect(restored.document['drawables'], ['original']);
      expect(restored.backgroundBytes, originalBackground);
    });

    test('rejects draft paths outside their conversation directory', () async {
      final outside = File('${root.path}/important.json');
      await outside.writeAsString('{"kept":true}');

      await expectLater(
        store.delete('conversation-a', outside.path),
        throwsFormatException,
      );
      expect(await outside.exists(), isTrue);
    });

    test('isolates same conversation ids across account scopes', () async {
      final anotherAccount = HomeChatDrawingDraftStore(
        rootDirectory: root,
        accountScope: 'account-b',
      );

      final first = await store.open('conversation-shared');
      final second = await anotherAccount.open('conversation-shared');

      expect(first.path, isNot(second.path));
    });
  });

  test(
    'drawing attachment metadata round-trips and old records still load',
    () {
      final old = HomeChatAttachment.fromJson({
        'id': 'old',
        'name': 'photo.png',
        'path': '/tmp/photo.png',
        'mime_type': 'image/png',
        'byte_length': 12,
        'source': 'image',
      });
      expect(old.drawingDraftPath, isNull);

      final drawing = HomeChatAttachment(
        id: 'drawing-1',
        name: '绘图.png',
        path: '/tmp/drawing.png',
        mimeType: 'image/png',
        byteLength: 32,
        source: 'drawing',
        drawingDraftPath: '/tmp/drawing-scene.json',
        drawingDraftScope: 'account-a',
      );
      final roundTrip = HomeChatAttachment.fromJson(drawing.toJson());
      expect(roundTrip.source, 'drawing');
      expect(roundTrip.drawingDraftPath, drawing.drawingDraftPath);
      expect(roundTrip.drawingDraftScope, drawing.drawingDraftScope);
      expect(
        roundTrip.copyWith(drawingDraftPath: null).drawingDraftPath,
        isNull,
      );
      expect(
        roundTrip.copyWith(drawingDraftScope: null).drawingDraftScope,
        isNull,
      );
    },
  );
}
