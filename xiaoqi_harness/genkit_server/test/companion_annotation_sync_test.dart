import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _UnusedRuntime implements XiaoqiAgentRuntime {
  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) => throw UnimplementedError();
}

void main() {
  late XiaoqiApi api;
  final account = _hash('owner@example.com');
  final other = _hash('other@example.com');
  final book = _hash('book');
  final source = _hash('source');
  final selector = _hash('selector');
  final annotation = _fixtureId(1);

  setUp(() {
    final directory = Directory.systemTemp.createTempSync(
      'companion-sync-api-',
    );
    final store = CloudStore(root: directory.path);
    api = XiaoqiApi(store, _UnusedRuntime());
    for (final (token, email) in [
      ('device-a', 'owner@example.com'),
      ('device-b', 'owner@example.com'),
      ('other', 'other@example.com'),
    ]) {
      store.put('device/${_hash(token)}', {
        'tenant_id': 'personal',
        'device_id': token,
        'auth_method': 'email',
        'account_email': email,
        'revoked_at': null,
      }, null);
    }
    addTearDown(() async {
      await api.close();
      store.close();
      await directory.delete(recursive: true);
    });
  });

  Future<Response> call(
    String method, {
    String suffix = '',
    String? token = 'device-a',
    String? scope,
    String contentType = 'application/json',
    Object? payload,
  }) => api.router.call(
    Request(
      method,
      Uri.parse('http://localhost/v1/companion-annotations$suffix'),
      headers: {
        'x-xiaoqi-contract': apiContractVersion,
        'x-xiaoqi-annotation-scope': scope ?? account,
        if (token != null) 'authorization': 'Bearer $token',
        'content-type': contentType,
      },
      body: payload is Map ? jsonEncode(payload) : payload,
    ),
  );

  Map<String, Object?> note({
    required int operation,
    required int edit,
    String? id,
    String text = '片段的私密文字',
    bool deleted = false,
    int generation = 0,
    List<Map<String, Object?>> media = const [],
  }) => {
    'operation_id': _fixtureId(operation),
    'kind': 'note',
    'id': id ?? annotation,
    'revision': _fixtureId(operation + 100),
    'device': _fixtureId(998),
    'book_key': book,
    'source_hash': source,
    'selector': selector,
    'generation': generation,
    'edited_at': edit,
    'deleted': deleted,
    if (!deleted) ...{
      'text': text,
      'selection': {
        'source_version': source,
        'quote': '完整引文',
        'locator': '第 2 页',
        'anchor': jsonEncode({'source_id': source, 'kind': 'pdf', 'page': 2}),
        'start_offset': 1,
        'end_offset': 5,
      },
      'media': media,
    },
  };

  Map<String, Object?> bookAction(
    int operation, {
    required bool deleted,
    int generation = 0,
    bool purge = false,
  }) => {
    'operation_id': _fixtureId(operation),
    'kind': 'book',
    'book_key': book,
    'deleted': deleted,
    'purged': purge,
    'generation': generation,
  };

  test(
    'verified account shares private notes and media across devices only',
    () async {
      final image = [137, 80, 78, 71, 13, 10, 26, 10, 0];
      final digest = sha256.convert(image).toString();
      final media = {
        'digest': digest,
        'size': image.length,
        'mime': 'image/png',
      };
      expect(
        (await call(
          'POST',
          payload: note(operation: 2, edit: 100, media: [media]),
        )).statusCode,
        400,
      );
      expect(
        (await call(
          'PUT',
          suffix: '/media/$digest',
          contentType: 'image/png',
          payload: image,
        )).statusCode,
        201,
      );
      final upload = await call(
        'POST',
        payload: note(operation: 2, edit: 100, media: [media]),
      );
      expect(upload.statusCode, 200);
      final fromSecond = await _body(await call('GET', token: 'device-b'));
      expect(fromSecond['items'].single['selection']['quote'], '完整引文');
      expect(
        await (await call(
          'GET',
          token: 'device-b',
          suffix: '/media/$digest',
        )).read().expand((chunk) => chunk).toList(),
        image,
      );
      expect((await call('GET', token: 'other')).statusCode, 403);
      final ownOther = await _body(
        await call('GET', token: 'other', scope: other),
      );
      expect(ownOther['items'], isEmpty);
      expect(
        (await call(
          'GET',
          token: 'other',
          scope: other,
          suffix: '/media/$digest',
        )).statusCode,
        404,
      );
      expect((await call('GET', token: null)).statusCode, 401);
    },
  );

  test(
    'out-of-order edits converge and late requests cannot restore deleted notes',
    () async {
      final newest = note(operation: 12, edit: 200, text: '最后编辑的版本');
      await call('POST', payload: newest, token: 'device-b');
      final older = note(operation: 11, edit: 100, text: '较早编辑的版本');
      final late = await _body(await call('POST', payload: older));
      expect(late['item']['text'], '最后编辑的版本');
      final duplicate = await _body(
        await call(
          'POST',
          token: 'device-b',
          payload: note(operation: 13, edit: 300, id: _fixtureId(55)),
        ),
      );
      expect(duplicate['item']['id'], annotation);
      final retried = await _body(
        await call('POST', token: 'device-b', payload: newest),
      );
      expect(retried['item']['revision'], duplicate['item']['revision']);
      final deleted = await _body(
        await call(
          'POST',
          payload: note(
            operation: 14,
            edit: 400,
            id: _fixtureId(55),
            deleted: true,
          ),
        ),
      );
      expect(deleted['item']['id'], annotation);
      expect(deleted['item']['selection'], isNull);
      final delayed = await _body(
        await call('POST', payload: note(operation: 15, edit: 500)),
      );
      expect(delayed['item']['deleted'], isTrue);
      final recreated = await _body(
        await call(
          'POST',
          payload: note(operation: 16, edit: 600, id: _fixtureId(56)),
        ),
      );
      expect(recreated['item']['id'], _fixtureId(56));
    },
  );

  test(
    'soft delete, restoration and purge enforce book lifecycle generations',
    () async {
      await call('POST', payload: note(operation: 20, edit: 100));
      await call('POST', payload: bookAction(21, deleted: true));
      final rejected = await _body(
        await call('POST', payload: note(operation: 22, edit: 200)),
      );
      expect(rejected['rejected'], 'book_generation');
      final restored = await _body(
        await call('POST', payload: bookAction(23, deleted: false)),
      );
      expect(restored['item']['generation'], 1);
      final stale = await _body(
        await call('POST', payload: note(operation: 24, edit: 300)),
      );
      expect(stale['rejected'], 'book_generation');
      final current = await _body(
        await call(
          'POST',
          payload: note(operation: 25, edit: 400, generation: 1),
        ),
      );
      expect(current['item']['id'], annotation);
      await call('POST', payload: bookAction(26, deleted: true, generation: 1));
      await call(
        'POST',
        payload: bookAction(27, deleted: true, generation: 1, purge: true),
      );
      final cannotRestore = await _body(
        await call(
          'POST',
          payload: bookAction(28, deleted: false, generation: 1),
        ),
      );
      expect(cannotRestore['item']['purged'], isTrue);
      final full = await _body(await call('GET'));
      final tombstone = full['items'].singleWhere(
        (item) => item['kind'] == 'note',
      );
      expect(tombstone['deleted'], isTrue);
      expect(tombstone['selection'], isNull);
      final reset = await _body(await call('GET', suffix: '?cursor=99999'));
      expect(reset['reset'], isTrue);
    },
  );
}

String _hash(String input) => sha256.convert(utf8.encode(input)).toString();
String _fixtureId(int number) => number.toRadixString(16).padLeft(32, '0');
Future<dynamic> _body(Response response) async {
  expect(response.statusCode, 200);
  return jsonDecode(await response.readAsString());
}
