import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/attachment_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

const _anchor = 'amber telescope';
const _answer = 'The amber telescope was set to 27 degrees.';

List<int> _sampleEpub() {
  final contents = <String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '''
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="Book/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
''',
    'Book/content.opf': '''
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book">markitdown-fixture</dc:identifier>
    <dc:title>Test Book</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="last" href="end.xhtml" media-type="application/xhtml+xml"/>
    <item id="first" href="start.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="first"/><itemref idref="last"/></spine>
</package>
''',
    'Book/end.xhtml':
        '''
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>The final chapter</h1><p>$_answer</p>
</body></html>
''',
    'Book/start.xhtml':
        '''
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>The first chapter</h1>${List.generate(3000, (i) => '<p>Earlier note $i.</p>').join()}
</body></html>
''',
  };
  final archive = Archive();
  for (final entry in contents.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encode(archive);
}

Future<Map<String, dynamic>> _json(Response response) async =>
    (jsonDecode(await response.readAsString()) as Map).cast<String, dynamic>();

void main() {
  for (final readingBook in [true, false]) {
    final profile = readingBook
        ? AttachmentService.readingBookMarkItDownProfile
        : AttachmentService.documentMarkItDownProfile;
    test(
      'real MarkItDown $profile upload is searchable by Agent',
      () async {
        final temporaryDirectory = await Directory.systemTemp.createTemp(
          'xiaoqi-markitdown-runtime-',
        );
        final store = CloudStore(root: temporaryDirectory.path);
        final attachments = AttachmentService(store);
        addTearDown(() async {
          await attachments.close();
          store.close();
          await temporaryDirectory.delete(recursive: true);
        });

        final uploaded = await attachments.upload(
          Request(
            'POST',
            Uri.parse('http://localhost/v1/attachments'),
            headers: {
              'content-type': readingBook
                  ? 'application/epub+zip'
                  : 'text/html',
              'x-xiaoqi-filename': readingBook
                  ? 'fixture.epub'
                  : 'fixture.html',
              'x-xiaoqi-attachment-profile': profile,
            },
            body: readingBook
                ? _sampleEpub()
                : utf8.encode('<h1>The final chapter</h1><p>$_answer</p>'),
          ),
          'owner',
        );
        final first = await _json(uploaded);
        expect(uploaded.statusCode, 202, reason: first.toString());
        final id = first['id'] as String;
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        var status = first;
        while (!const {
              'ready',
              'failed',
              'cancelled',
            }.contains(status['status']) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          status = await _json(await attachments.status('owner', id));
        }
        expect(status['ready'], isTrue, reason: status.toString());
        expect(status['coverage'], 'full');
        expect(status['parser_profile'], profile);
        expect((await attachments.status('other', id)).statusCode, 404);

        final runtime = GenkitXiaoqiAgentRuntime(
          store,
          ImageService(store),
          attachments: attachments,
        );
        final result = await runtime.readTaskMaterial(
          tenantId: 'owner',
          materials: [
            {
              'id': 'fictional-book',
              'name': 'fixture.md',
              'kind': 'document',
              'attachment_id': id,
            },
          ],
          materialId: 'fictional-book',
          mode: 'query',
          query: _anchor,
        );
        expect(result['text'], contains(_answer));
        expect(result['text'], contains('The final chapter'));
        expect(result['text'], isNot(contains('<h1>')));
        if (readingBook) {
          final firstPage = await attachments.material(
            'owner',
            id,
            mode: 'pages',
            pages: [1],
          );
          expect(firstPage['text'], contains('The first chapter'));
        }
      },
      skip: Platform.environment['XIAOQI_BOOK_MARKITDOWN_PYTHON'] == null
          ? 'Requires the pinned MarkItDown Python environment'
          : false,
    );
  }
}
