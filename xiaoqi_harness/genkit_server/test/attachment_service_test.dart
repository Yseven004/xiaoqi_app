import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/attachment_service.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Exercises the process boundary without depending on host Poppler/Tesseract.
class _PdfCommands {
  int pages = 20;
  Set<int> native = {};
  Set<int> blanks = {};
  Set<int> ocrFailures = {};
  bool encrypted = false;
  bool damaged = false;
  final ocrPages = <int>[];
  final renderPages = <int>[];
  final commands = <String>[];
  final ocrResources = <(String, int)>[];
  Completer<void>? blockOcr;
  Completer<void>? ocrStarted;

  Future<AttachmentCommandResult> call(
    String command,
    List<String> arguments, {
    required Duration timeout,
    required String workingDirectory,
  }) async {
    commands.add(command);
    switch (command) {
      case 'pdfinfo':
        return AttachmentCommandResult(
          damaged ? 1 : 0,
          'Pages: $pages\nEncrypted: ${encrypted ? 'yes' : 'no'}\n',
        );
      case 'pdftotext':
        await File(arguments.last).writeAsString(
          '${List.generate(pages, (i) => native.contains(i + 1) ? 'Native page ${i + 1} 中文文档' : '').join('\f')}\f',
        );
        return const AttachmentCommandResult(0);
      case 'pdftoppm':
        final page = int.parse(arguments[arguments.indexOf('-f') + 1]);
        renderPages.add(page);
        await File('${arguments.last}.pgm').writeAsBytes([
          ...ascii.encode('P5\n20 20\n255\n'),
          ...List.filled(400, blanks.contains(page) ? 255 : 40),
        ]);
        return const AttachmentCommandResult(0);
      case 'tesseract':
        final page = int.parse(
          RegExp(r'render-(\d+)').firstMatch(arguments.first)!.group(1)!,
        );
        ocrPages.add(page);
        ocrResources.add((p.basename(workingDirectory), page));
        if (ocrStarted?.isCompleted == false) ocrStarted!.complete();
        await blockOcr?.future;
        return AttachmentCommandResult(
          ocrFailures.contains(page) ? 1 : 0,
          'OCR page $page 中文识别结果',
        );
    }
    throw StateError('Unexpected command $command');
  }
}

class _AttachmentRuntime implements XiaoqiAgentRuntime {
  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async => 'unused';
}

void main() {
  late Directory directory;
  late CloudStore store;
  late AttachmentService service;
  late _PdfCommands commands;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-attachments-');
    store = CloudStore(root: directory.path);
    commands = _PdfCommands();
    service = AttachmentService(store, commandRunner: commands.call);
  });

  tearDown(() async {
    if (commands.blockOcr?.isCompleted == false) commands.blockOcr!.complete();
    await service.close();
    store.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> body(Response response) async =>
      (jsonDecode(await response.readAsString()) as Map)
          .cast<String, dynamic>();

  Future<Map<String, dynamic>> upload({
    String tenant = 'owner',
    String name = 'sample.pdf',
    String mime = 'application/pdf',
    List<int>? bytes,
  }) async {
    final response = await service.upload(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/attachments'),
        headers: {
          'content-type': mime,
          'x-xiaoqi-filename': Uri.encodeComponent(name),
        },
        body: bytes ?? ascii.encode('%PDF-1.4\nfixture'),
      ),
      tenant,
    );
    final result = await body(response);
    expect(response.statusCode, anyOf(200, 202), reason: jsonEncode(result));
    return result;
  }

  Future<Map<String, dynamic>> waitStatus(
    String id, {
    Set<String> terminal = const {'ready', 'failed', 'cancelled'},
  }) async {
    for (var i = 0; i < 500; i++) {
      final result = await body(await service.status('owner', id));
      if (terminal.contains(result['status'])) return result;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw StateError('Attachment did not settle');
  }

  test(
    'script materials preserve owned source bytes and reject another tenant',
    () async {
      final bytes = ascii.encode('%PDF-1.4\nprivate-source');
      final id = (await upload(bytes: bytes))['id'] as String;
      final material = await service.scriptMaterial('owner', id);
      expect(material['name'], 'sample.pdf');
      expect(base64Decode(material['base64']), bytes);
      await expectLater(
        service.scriptMaterial('other', id),
        throwsA(isA<AttachmentFailure>()),
      );
    },
  );

  test(
    'script material size limit is checked before reading the source',
    () async {
      final bytes = List<int>.filled(20 * 1024 * 1024 + 1, 32);
      bytes.setRange(0, 9, ascii.encode('%PDF-1.4\n'));
      final id = (await upload(bytes: bytes))['id'] as String;
      await expectLater(
        service.scriptMaterial('owner', id),
        throwsFormatException,
      );
    },
  );

  test(
    'native PDFs extract once and never OCR unselected blank pages',
    () async {
      commands.native = {1, 2, 3, 6, 11, 15, 18, 20};
      final id = (await upload())['id'] as String;
      final material = await service.material('owner', id);
      expect(material['coverage'], 'partial');
      expect(material['text'], contains('Native page 20'));
      expect(commands.ocrPages, isEmpty);
      expect(commands.commands.where((c) => c == 'pdftotext'), hasLength(1));
      expect((await waitStatus(id))['ready'], true);
      await service.material('owner', id);
      expect(commands.commands.where((c) => c == 'pdftotext'), hasLength(1));
    },
  );

  test(
    'scanned PDFs read three initial representative pages then precise pages on demand',
    () async {
      commands.pages = 100;
      final id = (await upload())['id'] as String;
      final overview = await service.material('owner', id);
      expect(commands.ocrPages.length, 3);
      expect(overview['read_pages'], [1, 2, 51]);
      expect(overview['coverage'], 'partial');
      final requested = await service.material(
        'owner',
        id,
        mode: 'pages',
        pages: [45, 46],
      );
      expect(requested['read_pages'], [45, 46]);
      expect(requested['text'], contains('[第 45 页; ocr]'));
      expect(commands.ocrPages.length, 5);
      await service.material('owner', id, mode: 'pages', pages: [45, 46]);
      expect(commands.ocrPages.length, 5);
      expect(commands.commands, isNot(contains('ocrmypdf')));
    },
  );

  test(
    'mixed text, scan and actual blank pages preserve original positions',
    () async {
      commands.pages = 3;
      commands.native = {1};
      commands.blanks = {2};
      final id = (await upload())['id'] as String;
      final result = await service.material('owner', id);
      expect(result['coverage'], 'full');
      expect(commands.ocrPages, [3]);
      final segments = (result['segments'] as List).cast<Map>();
      expect(segments.map((s) => s['page']), [1, 2, 3]);
      expect(segments.map((s) => s['source']), ['native', 'blank', 'ocr']);
      expect(segments[1]['text'], isEmpty);
    },
  );

  test(
    'blank front pages expand cold overview up to readable representatives',
    () async {
      commands.pages = 100;
      commands.blanks = {1, 2};
      final id = (await upload())['id'] as String;
      final overview = await service.material('owner', id);
      expect(commands.renderPages, [1, 2, 51, 26, 100]);
      expect(commands.ocrPages, [51, 26, 100]);
      expect(overview['read_pages'], [1, 2, 51, 26, 100]);
      expect(overview['coverage'], 'partial');
    },
  );

  test(
    'query misses expand unread pages and never assert complete search',
    () async {
      commands.pages = 100;
      final id = (await upload())['id'] as String;
      await service.material('owner', id);
      final query = await service.material(
        'owner',
        id,
        mode: 'query',
        query: 'topic-not-in-any-fixture',
      );
      expect(query['read_pages'], [3, 4, 5, 6, 7, 8, 9, 10]);
      expect(query['text'], contains('OCR page 3'));
      expect(query['search_incomplete'], true);
      expect(query['next_pages'], [11, 12, 13, 14, 15, 16, 17, 18]);
      final next = await service.material(
        'owner',
        id,
        mode: 'query',
        query: 'topic-not-in-any-fixture',
      );
      expect(next['read_pages'], [11, 12, 13, 14, 15, 16, 17, 18]);
      expect(commands.ocrPages.length, 19);
    },
  );

  test('blank cold scan stops after at most eight attempts', () async {
    commands.pages = 100;
    commands.blanks = Set.of(List.generate(100, (i) => i + 1));
    final id = (await upload())['id'] as String;
    await expectLater(
      service.material('owner', id),
      throwsA(isA<AttachmentFailure>()),
    );
    expect(commands.renderPages.length, 8);
    expect(commands.ocrPages, isEmpty);
  });

  test('empty documents report a recoverable quality failure', () async {
    commands.pages = 2;
    commands.blanks = {1, 2};
    final id = (await upload())['id'] as String;
    await expectLater(
      service.material('owner', id),
      throwsA(
        isA<AttachmentFailure>().having(
          (e) => e.code,
          'code',
          'no_readable_text',
        ),
      ),
    );
    final status = await waitStatus(id);
    expect(status['status'], 'failed');
    expect(status['completed_pages'], [1, 2]);
    expect(commands.ocrPages, isEmpty);
  });

  test(
    'cancel during OCR preserves extracted pages and immediate retry resumes',
    () async {
      commands.pages = 3;
      commands.native = {1};
      commands.blockOcr = Completer<void>();
      commands.ocrStarted = Completer<void>();
      final id = (await upload())['id'] as String;
      final reading = service.material('owner', id);
      final cancelled = expectLater(
        reading,
        throwsA(
          isA<AttachmentFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await commands.ocrStarted!.future;
      final result = await body(await service.cancel('owner', id));
      expect(result['completed_pages'], [1]);
      expect(result['status'], 'cancelled');
      final retry = service.material('owner', id);
      commands.blockOcr!.complete();
      await cancelled;
      expect((await retry)['coverage'], 'full');
      expect(commands.commands.where((c) => c == 'pdftotext'), hasLength(1));
    },
  );

  test(
    'a failed OCR retains earlier pages and reprocesses only missing pages',
    () async {
      commands.pages = 3;
      commands.native = {1};
      commands.ocrFailures = {3};
      final id = (await upload())['id'] as String;
      await expectLater(
        service.material('owner', id),
        throwsA(
          isA<AttachmentFailure>().having((e) => e.code, 'code', 'ocr_failed'),
        ),
      );
      final failed = await waitStatus(id);
      expect(failed['completed_pages'], [1, 2]);
      commands.ocrFailures.clear();
      expect((await service.material('owner', id))['coverage'], 'full');
      expect(commands.ocrPages.where((n) => n == 2), hasLength(1));
      expect(commands.ocrPages.where((n) => n == 3), hasLength(2));
    },
  );

  test(
    'cache ownership and content hashing prevent cross-tenant access',
    () async {
      final bytes = utf8.encode('中文文档');
      final own = await upload(
        name: '中文.txt',
        mime: 'text/plain',
        bytes: bytes,
      );
      final id = own['id'] as String;
      expect((await service.status('another', id)).statusCode, 404);
      final again = await service.upload(
        Request(
          'POST',
          Uri.parse('http://localhost/'),
          headers: {
            'content-type': 'text/plain',
            'x-xiaoqi-filename': Uri.encodeComponent('renamed.txt'),
          },
          body: bytes,
        ),
        'owner',
      );
      expect((await body(again))['cache_hit'], true);
      final other = await upload(
        tenant: 'another',
        name: 'copy.txt',
        mime: 'text/plain',
        bytes: bytes,
      );
      expect(other['id'], isNot(id));
    },
  );

  test(
    'concurrent identical uploads share a single committed resource',
    () async {
      final results = await Future.wait([
        upload(
          name: 'first.txt',
          mime: 'text/plain',
          bytes: utf8.encode('identical'),
        ),
        upload(
          name: 'second.txt',
          mime: 'text/plain',
          bytes: utf8.encode('identical'),
        ),
      ]);
      expect(results[0]['id'], results[1]['id']);
      expect(store.list('attachment/'), hasLength(1));
      expect(results.where((r) => r['cache_hit'] == true), hasLength(1));
    },
  );

  test(
    'one-page worker turns allow a new overview during a long full read',
    () async {
      commands.pages = 20;
      final first = (await upload())['id'] as String;
      await service.material('owner', first);
      commands.blockOcr = Completer<void>();
      commands.ocrStarted = Completer<void>();
      final full = service.material('owner', first, mode: 'full');
      await commands.ocrStarted!.future;
      final second =
          (await upload(bytes: ascii.encode('%PDF-1.4\nsecond')))['id']
              as String;
      final overview = service.material('owner', second);
      commands.blockOcr!.complete();
      expect((await overview)['coverage'], 'partial');
      expect((await full)['coverage'], 'full');
      final firstSecond = commands.ocrResources.indexWhere(
        (event) => event.$1 == second,
      );
      final lastFirst = commands.ocrResources.lastIndexWhere(
        (event) => event.$1 == first,
      );
      expect(firstSecond, lessThan(lastFirst));
      expect(
        commands.ocrResources.where((event) => event.$1 == second),
        hasLength(3),
      );
    },
  );

  test(
    'expanded public reads clear stale readiness until their pages finish',
    () async {
      commands.pages = 20;
      final id = (await upload())['id'] as String;
      await service.material('owner', id);
      expect((await waitStatus(id))['ready'], true);
      commands.blockOcr = Completer<void>();
      commands.ocrStarted = Completer<void>();
      final started = await body(
        await service.read(
          Request(
            'POST',
            Uri.parse('http://localhost/'),
            body: jsonEncode({
              'mode': 'pages',
              'pages': [4, 5],
            }),
          ),
          'owner',
          id,
        ),
      );
      expect(started['ready'], false);
      await commands.ocrStarted!.future;
      expect((await body(await service.status('owner', id)))['ready'], false);
      commands.blockOcr!.complete();
      final ready = await waitStatus(id);
      expect(ready['ready'], true);
      expect(ready['completed_pages'], containsAll([4, 5]));
    },
  );

  test(
    'client segments retain Unicode and explicit pages never truncate content',
    () async {
      final record = await upload(
        name: '演示.pptx',
        mime:
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        bytes: [80, 75, 3, 4],
      );
      final id = record['id'] as String;
      final text = List.filled(60000, '中').join();
      final response = await service.submitSegments(
        Request(
          'PUT',
          Uri.parse('http://localhost/'),
          body: jsonEncode({
            'full': true,
            'segments': [
              {'index': 0, 'locator': '第 1 张幻灯片', 'text': text},
              {'index': 1, 'locator': '第 2 张幻灯片', 'text': '结束'},
            ],
          }),
        ),
        'owner',
        id,
      );
      expect(response.statusCode, 200);
      final overview = await service.material('owner', id);
      expect(overview['text_truncated'], true);
      final exact = await service.material(
        'owner',
        id,
        mode: 'pages',
        pages: [1],
      );
      expect((exact['segments'] as List).first['text'], text);
      expect(exact['text_truncated'], false);
      expect(exact['total_pages'], 2);
    },
  );

  test(
    'invalid segments cannot replace a previously prepared document',
    () async {
      final id =
          (await upload(
                name: 'sample.txt',
                mime: 'text/plain',
                bytes: utf8.encode('hello'),
              ))['id']
              as String;
      Future<Response> submit(List<Map<String, dynamic>> segments) =>
          service.submitSegments(
            Request(
              'PUT',
              Uri.parse('http://localhost/'),
              body: jsonEncode({'full': true, 'segments': segments}),
            ),
            'owner',
            id,
          );
      expect(
        (await submit([
          {'index': 0, 'locator': '段落 1', 'text': 'hello'},
        ])).statusCode,
        200,
      );
      expect(
        (await submit([
          {'index': 1, 'locator': '段落 2', 'text': 'bad index'},
        ])).statusCode,
        400,
      );
      expect((await service.material('owner', id))['text'], contains('hello'));
    },
  );

  test(
    'PDF limits, damaged and encrypted files are explicit failures',
    () async {
      commands.pages = 501;
      final id = (await upload())['id'] as String;
      expect((await waitStatus(id))['error_code'], 'page_limit');
      expect(commands.ocrPages, isEmpty);
      commands.pages = 1;
      commands.encrypted = true;
      final encrypted =
          (await upload(bytes: ascii.encode('%PDF-1.4\nencrypted')))['id']
              as String;
      expect(
        (await waitStatus(encrypted))['error_code'],
        'invalid_or_encrypted_pdf',
      );
      commands.encrypted = false;
      commands.damaged = true;
      final damaged =
          (await upload(bytes: ascii.encode('%PDF-1.4\ndamaged')))['id']
              as String;
      expect(
        (await waitStatus(damaged))['error_code'],
        'invalid_or_encrypted_pdf',
      );
    },
  );

  test(
    'oversized, incomplete and bad-hash uploads leave no resource',
    () async {
      Future<Response> invalid(Map<String, String> headers, String body) =>
          service.upload(
            Request(
              'POST',
              Uri.parse('http://localhost/'),
              headers: {
                'content-type': 'text/plain',
                'x-xiaoqi-filename': 'sample.txt',
                ...headers,
              },
              body: Stream<List<int>>.value(utf8.encode(body)),
            ),
            'owner',
          );
      expect(
        (await invalid({
          'content-length': '${AttachmentService.maxFileBytes + 1}',
        }, 'x')).statusCode,
        413,
      );
      expect((await invalid({'content-length': '10'}, 'x')).statusCode, 400);
      expect(
        (await invalid({
          'x-xiaoqi-sha256': List.filled(64, '0').join(),
        }, 'x')).statusCode,
        400,
      );
      expect(store.list('attachment/'), isEmpty);
      expect(
        Directory(p.join(directory.path, 'attachments'))
            .listSync()
            .whereType<Directory>()
            .where((d) => p.basename(d.path).startsWith('.upload-')),
        isEmpty,
      );
    },
  );

  test(
    'restart keeps native/OCR cache, removes staging, and allows resuming',
    () async {
      commands.pages = 3;
      commands.native = {1, 2, 3};
      final id = (await upload())['id'] as String;
      await service.material('owner', id);
      await service.close();
      final key = store.list('attachment/').single.$1;
      final current = store.get(key)!;
      store.put(key, {
        ...current.value,
        'status': 'processing',
      }, current.revision);
      final staging = Directory(
        p.join(directory.path, 'attachments', '.upload-dead'),
      )..createSync();
      File(p.join(staging.path, 'source')).writeAsStringSync('incomplete');
      service = AttachmentService(store, commandRunner: commands.call);
      final result = await service.material('owner', id);
      expect(result['coverage'], 'full');
      expect(commands.commands.where((c) => c == 'pdftotext'), hasLength(1));
      expect(staging.existsSync(), false);
    },
  );

  test('24-hour expiry removes original and segments on recovery', () async {
    final id =
        (await upload(
              name: 'expired.txt',
              mime: 'text/plain',
              bytes: utf8.encode('old'),
            ))['id']
            as String;
    await service.close();
    final entry = store.list('attachment/').single;
    store.put(entry.$1, {
      ...entry.$2.value,
      'expires_at': 1,
    }, entry.$2.revision);
    service = AttachmentService(store, commandRunner: commands.call);
    expect((await service.status('owner', id)).statusCode, 404);
    expect(store.list('attachment/'), isEmpty);
    final originals = Directory(p.join(directory.path, 'attachments'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'source');
    expect(originals, isEmpty);
  });

  test(
    'validated images become ready and are read only by their tenant',
    () async {
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE9sAAAAASUVORK5CYII=',
      );
      final id =
          (await upload(
                name: 'photo.png',
                mime: 'image/png',
                bytes: image,
              ))['id']
              as String;
      final result = await service.material('owner', id);
      expect(result['kind'], 'image');
      expect(result['coverage'], 'full');
      expect(
        (await service.imagePart('owner', id))['image_url']['url'],
        startsWith('data:image/png;base64,'),
      );
      await expectLater(
        service.imagePart('another', id),
        throwsA(isA<AttachmentFailure>()),
      );
      expect(commands.commands, isEmpty);
    },
  );

  test(
    'unified API enforces contract and tenant ownership for every resource operation',
    () async {
      final api = XiaoqiApi(store, _AttachmentRuntime(), attachments: service);
      for (final tenant in ['owner', 'another']) {
        store.put('device/${sha256.convert(utf8.encode('token-$tenant'))}', {
          'tenant_id': tenant,
          'device_id': 'device-$tenant',
          'revoked_at': null,
        }, null);
      }
      Future<Response> call(
        String method,
        String path, {
        String? tenant = 'owner',
        String contract = apiContractVersion,
        Object? body,
        Map<String, String> headers = const {},
      }) => api.router.call(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {
            if (tenant != null) 'authorization': 'Bearer token-$tenant',
            'x-xiaoqi-contract': contract,
            ...headers,
          },
          body: body,
        ),
      );
      expect(
        (await call('POST', '/v1/attachments', tenant: null)).statusCode,
        401,
      );
      expect(
        (await call('POST', '/v1/attachments', contract: 'old')).statusCode,
        426,
      );
      final uploaded = await body(
        await call(
          'POST',
          '/v1/attachments',
          headers: {
            'content-type': 'text/plain',
            'x-xiaoqi-filename': 'test.txt',
          },
          body: 'hello',
        ),
      );
      final path = '/v1/attachments/${uploaded['id']}';
      for (final operation in [
        ('GET', path),
        ('PUT', '$path/segments'),
        ('POST', '$path/read'),
        ('DELETE', path),
      ]) {
        expect(
          (await call(
            operation.$1,
            operation.$2,
            tenant: 'another',
            body: '{}',
          )).statusCode,
          404,
        );
      }
      expect(
        (await call(
          'PUT',
          '$path/segments',
          body: jsonEncode({
            'full': true,
            'segments': [
              {'index': 0, 'locator': 'segment 1', 'text': 'hello'},
            ],
          }),
        )).statusCode,
        200,
      );
      expect(
        (await call(
          'POST',
          '$path/read',
          body: jsonEncode({'mode': 'overview'}),
        )).statusCode,
        202,
      );
      expect((await body(await call('GET', path)))['ready'], true);
      expect((await call('DELETE', path)).statusCode, 200);
      expect(
        (await service.material('owner', uploaded['id'] as String))['text'],
        contains('hello'),
      );
      expect((await call('POST', '/v1/pdf-ocr/jobs')).statusCode, 404);
      await api.close();
    },
  );
}
