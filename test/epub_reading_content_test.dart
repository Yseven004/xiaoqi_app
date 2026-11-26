import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/models/xiaoqi_document.dart';
import 'package:xiaoqi_app/services/epub_document_service.dart';
import 'package:xiaoqi_app/services/source_document_loader.dart';
import 'package:xiaoqi_app/widgets/xiaoqi_document_block_view.dart';

List<int> sample() {
  final files = {
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="book/content.opf"/></rootfiles></container>',
    'book/content.opf':
        '''<package><metadata><title>Reader</title><creator>Author</creator><date>2026-08</date><publisher>P</publisher></metadata>
      <manifest><item id="body" href="section.xhtml" media-type="application/xhtml+xml"/>
      <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
      <item id="art" href="img.svg" media-type="image/svg+xml"/></manifest>
      <spine><itemref idref="nav"/><itemref idref="body"/></spine></package>''',
    'book/nav.xhtml':
        '''<html><body><nav epub:type="toc"><ol><li><a href="section.xhtml">Chapter</a><ol>
      <li><a href="section.xhtml#part">Part</a></li></ol></li></ol></nav>
      <nav hidden="hidden"><ol><li>Hidden landmarks</li></ol></nav></body></html>''',
    'book/section.xhtml':
        '''<html><body><h1>Chapter</h1><p id="part">One <a href="https://example.org/">two words</a> three.</p>
      <figure><img src="img.svg" alt="A diagram"/><figcaption aria-hidden="true">Figure 1</figcaption></figure>
      <p>Existing paragraph</p><pre><code>git clone source
  cd source</code></pre>
      <table><caption>Table 1</caption><thead><tr><th>A</th><th>B</th></tr></thead>
      <tbody><tr><td>1</td><td><a href="#part">Link</a></td></tr></tbody></table>
      <img src="https://example.org/no-download"/><p><a href="javascript:void(0)">No link</a></p></body></html>''',
    'book/img.svg':
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80"><script>bad()</script><image href="https://example.org/never"/><rect width="30" height="20" fill="red"/><style>.wire{stroke:#000000;marker-end:url(#tip)}</style><defs><marker id="tip" refX="8" refY="3" orient="auto" markerUnits="userSpaceOnUse" fill="#00ff00"><polygon points="0,0 8,3 0,6"/></marker></defs><line class="wire" x1="30" y1="40" x2="80" y2="40"/></svg>',
  };
  final archive = Archive();
  files.forEach(
    (path, data) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(data))),
  );
  return ZipEncoder().encode(archive);
}

List<int> _lateChapterBook({bool missingLeading = false}) {
  final files = {
    'META-INF/container.xml':
        '<container><rootfile full-path="book.opf"/></container>',
    'book.opf': '''
<package><metadata><title>Late chapter</title></metadata><manifest>
<item id="early" href="early.xhtml" media-type="application/xhtml+xml"/>
<item id="late" href="late.xhtml" media-type="application/xhtml+xml"/>
<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="early"/><itemref idref="late"/></spine></package>
''',
    'nav.xhtml': '''
<html><body><nav epub:type="toc"><ol>
<li><a href="early.xhtml">Early</a></li>
<li><a href="late.xhtml#section">Late</a></li>
</ol></nav></body></html>
''',
    if (!missingLeading)
      'early.xhtml': '''
<html><body><span role="doc-pagebreak"></span><p>Earlier</p>
<svg width="10" height="10"><rect width="10" height="10" fill="blue"/></svg>
</body></html>
''',
    'late.xhtml': '''
<html><body><h1>Late</h1><span role="doc-pagebreak"></span>
<p id="section">读到这里时，正文应保持原样。</p>
<svg width="10" height="10"><rect width="10" height="10" fill="red"/></svg>
<span role="doc-pagebreak" aria-label="42"></span>
</body></html>
''',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return ZipEncoder().encode(archive);
}

BookSourceRecord _readerSource(File file) => BookSourceRecord(
  id: 3,
  bookId: 1,
  kind: 'file',
  displayName: 'Late chapter',
  filePath: file.path,
  fileSize: file.lengthSync(),
  contentHash: 'test',
  status: 'ready',
  format: 'epub',
  createdAt: '0',
  updatedAt: '0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cold reader exposes target before reading a missing earlier chapter',
    () async {
      final directory = await Directory.systemTemp.createTemp('epub-target-');
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/book.epub',
      ).writeAsBytes(_lateChapterBook(missingLeading: true));
      final load = await SourceDocumentLoader.openEpubReader(
        _readerSource(file),
        initialChapterId: 'epub:late',
      );
      await expectLater(
        load.updates,
        emitsInOrder([
          predicate<EpubReaderUpdate>((update) {
            final preview = update.preview!;
            final chapter = update.document.chapters.single;
            expect(chapter.id, 'epub:late');
            expect(chapter.plainText, contains('读到这里时，正文应保持原样。'));
            expect(preview.spine.map((item) => item.chapterId), [
              'epub:early',
              'epub:late',
            ]);
            expect(preview.outline.last.fragment, 'section');
            expect(
              chapter.blocks
                  .firstWhere((block) => block.kind == 'page_break')
                  .originalPageLabel,
              isNull,
            );
            return true;
          }),
          emitsError(isA<StateError>()),
          emitsDone,
        ]),
      );
    },
  );

  test(
    'prioritized previews keep source anchors and canonical page numbering',
    () async {
      final directory = await Directory.systemTemp.createTemp('epub-full-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = _lateChapterBook();
      final file = await File(
        '${directory.path}/book.epub',
      ).writeAsBytes(bytes);
      const service = EpubDocumentService();
      var target = 'epub:late';
      final previews = <EpubReaderPreview>[];
      final complete = await service.parseForReader(
        file.path,
        takeTarget: () {
          final next = target;
          target = '';
          return next.isEmpty ? null : next;
        },
        publish: (preview) {
          previews.add(preview);
          if (previews.length == 1) target = 'epub:early';
        },
      );
      expect(previews.map((preview) => preview.document.chapters.single.id), [
        'epub:late',
        'epub:early',
      ]);
      final late = previews.first.document.chapters.single;
      expect(
        late.fragmentBlocks['section'],
        complete.resolveReadingLink('late.xhtml#section')?.blockId,
      );
      expect(complete.toJson(), service.parseBytes(bytes).toJson());
      expect(
        complete.chapters.last.blocks
            .where((block) => block.kind == 'page_break')
            .map((block) => block.originalPageLabel),
        ['3', '42'],
      );
      expect(
        late.blocks
            .where((block) => block.kind == 'page_break')
            .map((block) => block.originalPageLabel),
        [null, '42'],
      );
      final previewAsset = previews.first.document.assets.single;
      final canonicalAsset = complete.assets.last;
      expect(complete.assets.map((asset) => asset.id), [
        'epub-inline:0',
        'epub-inline:1',
      ]);
      expect(
        previewAsset.id,
        isNot(isIn(complete.assets.map((asset) => asset.id))),
      );
      expect(previewAsset.bytes, canonicalAsset.bytes);
    },
  );

  test('warmed EPUB exposes only the complete persistent document', () async {
    final directory = await Directory.systemTemp.createTemp('epub-cache-');
    addTearDown(() => directory.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getTemporaryDirectory') return directory.path;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final file = await File(
      '${directory.path}/book.epub',
    ).writeAsBytes(_lateChapterBook());
    final source = _readerSource(file);
    await SourceDocumentLoader.prepareReaderCache(source);
    final load = await SourceDocumentLoader.openEpubReader(
      source,
      initialChapterId: 'epub:late',
    );
    final cacheDir = load.layoutCache!.parent;
    expect(await File('${cacheDir.path}/document.json').exists(), isTrue);
    final update = await load.updates.single;
    expect(update.preview, isNull);
    expect(update.document.chapters.map((chapter) => chapter.id), [
      'epub:early',
      'epub:late',
    ]);
  });

  test(
    'an existing multi-megabyte SQLite revision reads across UTF-8 boundaries',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final service = DatabaseService()..useDatabaseForTesting(db);
      addTearDown(() async {
        service.useDatabaseForTesting(null);
        await db.close();
      });
      await service.createForTesting(db);
      final content = '阅读📖' * 240001;
      final document = XiaoqiDocument(
        format: 'epub',
        structureVersion: 2,
        title: 'Sample',
        author: '',
        language: 'zh',
        chapters: [
          XiaoqiDocumentChapter(
            id: 'c',
            title: 'C',
            href: 'c',
            html: '',
            plainText: content,
            order: 0,
          ),
        ],
      );
      await db.insert('book_source_document_revisions', {
        'source_id': 1,
        'base_content_hash': 'hash',
        'document_hash': 'rev',
        'document_json': document.toJson(),
        'created_at': '0',
        'updated_at': '0',
        'is_active': 1,
      });
      const source = BookSourceRecord(
        id: 1,
        bookId: 1,
        kind: 'file',
        displayName: 'Sample',
        filePath: '',
        fileSize: 0,
        contentHash: 'hash',
        status: 'ready',
        format: 'epub',
        createdAt: '0',
        updatedAt: '0',
      );
      final restored = await BookLibraryService(
        databaseService: service,
      ).loadBookSourceRevision(source);
      expect(restored?.chapters.single.plainText, content);
    },
  );
  test(
    'native EPUB restores reading structure, local artwork and bounded links',
    () {
      final d = const EpubDocumentService().parseBytes(sample());
      expect(d.outline.map((e) => e.title), ['Chapter', 'Part']);
      final toc = d.chapters.first.blocks.where((b) => b.kind == 'list_item');
      expect(toc.map((b) => b.text), ['Chapter', 'Part']);
      expect(toc.map((b) => b.attributes['listDepth']), ['0', '1']);
      final b = d.chapters.last.blocks;
      final paragraph = b.firstWhere((b) => b.text.startsWith('One'));
      final link = paragraph.linkRanges.single;
      expect(paragraph.text.substring(link.start, link.end), 'two words');
      expect(link.target, 'https://example.org/');
      expect(
        d.resolveReadingLink(toc.last.linkRanges.single.target)?.blockId,
        paragraph.id,
      );
      expect(
        b.firstWhere((b) => b.text == 'Existing paragraph').id,
        'epub:body:block:2',
      );
      expect(
        b.firstWhere((b) => b.kind == 'code').text,
        'git clone source\n  cd source',
      );
      expect(b.where((b) => b.kind == 'caption').map((e) => e.text), [
        'Figure 1',
        'Table 1',
      ]);
      final table = b.singleWhere((b) => b.kind == 'table');
      expect(jsonDecode(table.attributes['rows']!), [
        ['A', 'B'],
        ['1', 'Link'],
      ]);
      expect(
        jsonDecode(table.attributes['cellLinks']!)['1:1'][0][2],
        'book/section.xhtml#part',
      );
      expect(b.last.linkRanges, isEmpty);
      expect(d.assets.length, 1);
      final safeSvg = utf8.decode(d.assets.single.bytes);
      expect(safeSvg, contains('<rect'));
      expect(safeSvg, isNot(contains('https://example.org')));
      expect(safeSvg, isNot(contains('<script')));
      final roundtrip = XiaoqiDocument.fromJson(d.toJson());
      expect(
        roundtrip.resolveReadingLink('book/section.xhtml#part')?.blockId,
        paragraph.id,
      );
    },
  );

  test(
    'an edited legacy EPUB passage and annotations keep their old owner',
    () async {
      final dir = await Directory.systemTemp.createTemp('epub-restore-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/book.epub').writeAsBytes(sample());
      final legacy = <String, String>{};
      final d = const EpubDocumentService().parseBytes(
        sample(),
        legacyText: legacy,
      );
      final chapters = [
        for (final ch in d.chapters)
          XiaoqiDocumentChapter(
            id: ch.id,
            title: ch.title,
            href: ch.href,
            html: '',
            plainText: '',
            order: ch.order,
            blocks: [
              for (final entry in legacy.entries.where(
                (e) => e.key.startsWith('${ch.id}:'),
              ))
                XiaoqiDocumentBlock(
                  id: entry.key,
                  kind:
                      ch.blocks
                          .where((b) => b.id == entry.key)
                          .firstOrNull
                          ?.kind ??
                      'paragraph',
                  text: entry.value == 'Existing paragraph'
                      ? 'My correction'
                      : entry.value,
                ),
            ],
          ),
      ];
      final stored = XiaoqiDocument(
        format: 'epub',
        title: 'Reader',
        author: 'Author',
        language: '',
        chapters: chapters,
      );
      final restored = await upgradeStoredEpub((file.path, stored));
      expect(restored.structureVersion, EpubDocumentService.structureVersion);
      expect(
        restored.chapters.last.blocks.any(
          (b) => b.id == 'epub:body:block:2' && b.text == 'My correction',
        ),
        isTrue,
      );
      expect(restored.assets, isNotEmpty);
      final annotated = XiaoqiDocument(
        format: 'epub',
        title: 'Reader',
        author: '',
        language: '',
        chapters: chapters,
        annotations: {
          'unmapped': {'text': 'Part'},
        },
      );
      expect(await upgradeStoredEpub((file.path, annotated)), same(annotated));
    },
  );

  test(
    'the Flutter SVG renderer draws the original arrowhead off the line axis',
    () async {
      final asset = const EpubDocumentService()
          .parseBytes(sample())
          .assets
          .single;
      final info = await vg.loadPicture(
        SvgBytesLoader(Uint8List.fromList(asset.bytes)),
        null,
      );
      try {
        final img = await info.picture.toImage(100, 80);
        try {
          final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          // At x=73 an authored triangle spans y=37..43, while the line alone only spans y=39.5..40.5.
          final offset = (42 * 100 + 73) * 4;
          expect(data!.getUint8(offset + 3), greaterThan(20));
          expect(data.getUint8(offset + 1), greaterThan(data.getUint8(offset)));
        } finally {
          img.dispose();
        }
      } finally {
        info.picture.dispose();
      }
    },
  );
  testWidgets('a link on a sliced page activates without toggling the reader', (
    tester,
  ) async {
    final block = const EpubDocumentService()
        .parseBytes(sample())
        .chapters
        .last
        .blocks
        .firstWhere((b) => b.linkRanges.isNotEmpty);
    String? opened;
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: XiaoqiDocumentBlockView(
              block: block,
              textOffset: 4,
              textOverride: 'two words',
              onLinkTap: (url) => opened = url,
              onTextTap: () => toggles++,
            ),
          ),
        ),
      ),
    );
    final rich = find.byType(EditableText);
    await tester.tapAt(tester.getTopLeft(rich) + const Offset(16, 12));
    await tester.pump();
    expect(opened, 'https://example.org/');
    expect(toggles, 0);
  });
}
