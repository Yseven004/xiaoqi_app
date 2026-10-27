import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Exercises actual format readers in successive offline Docker workspaces.
Future<void> verifyBinaryArtifacts(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  for (final office in [true, false]) {
    final task = office ? 'office-file-roundtrip' : 'graphics-file-roundtrip';
    final key = 'task/$tenant/$task';
    store.put(key, {'status': 'running', 'artifacts': [], 'events': []}, null);
    final files = <String, List<int>>{
      'requirements.txt': utf8.encode(
        office
            ? 'openpyxl==3.1.5\npython-docx==1.2.0\n'
            : 'pypdf==6.1.3\nPillow==11.3.0\n',
      ),
    };
    files.addAll(await executor.prepareDependencies(tenant, files));
    final names = office
        ? ['data.xlsx', 'document.docx']
        : ['pages.pdf', 'pixels.png'];
    final script = office ? _office : _graphics;
    List<Map> artifacts() =>
        (store.get(key)!.value['artifacts'] as List).cast<Map>();
    Future<void> run(String stage, {List<String>? ids, Map? versions}) async {
      await executor.execute(
        tenantId: tenant,
        taskId: task,
        language: 'python',
        code: '$script\n${_verifyVersions}',
        arguments: [stage, jsonEncode(versions ?? {})],
        authorizedDomains: [],
        materials: [],
        skillFiles: files,
        artifactIds: ids,
        cancellation: CancellationController().token,
      );
    }

    await run('create', ids: []);
    final original = {
      for (final name in names)
        name: artifacts().singleWhere((a) => a['name'] == name),
    };
    await run(
      'edit',
      ids: original.values.map((a) => a['id'].toString()).toList(),
    );
    final edited = {
      for (final name in names)
        name: artifacts().lastWhere((a) => a['name'] == name),
    };
    for (final name in names) {
      if (original[name]!['id'] == edited[name]!['id'] ||
          original[name]!['sha256'] == edited[name]!['sha256']) {
        throw StateError('Edited binary version did not change: $name');
      }
    }
    // Default inputs must resolve to the latest same-name version.
    await run('latest');
    final versions = {
      for (final name in names)
        name: [original[name]!['id'], edited[name]!['id']],
    };
    await run(
      'versions',
      ids: versions.values
          .expand((ids) => ids)
          .map((id) => id.toString())
          .toList(),
      versions: versions,
    );
    final foreignTask = '$task-unrelated';
    store.put('task/$tenant/$foreignTask', {
      'status': 'running',
      'artifacts': [],
      'events': [],
    }, null);
    var rejected = false;
    try {
      await executor.execute(
        tenantId: tenant,
        taskId: foreignTask,
        language: 'python',
        code: 'raise AssertionError("foreign artifact reached sandbox")',
        authorizedDomains: [],
        materials: [],
        skillFiles: {},
        artifactIds: [original.values.first['id'].toString()],
        cancellation: CancellationController().token,
      );
    } on StateError catch (error) {
      rejected = error.message.toString().contains('不属于当前任务');
    }
    if (!rejected)
      throw StateError('Cross-task artifact selection was not rejected');
  }
}

const _common = r'''
import json, pathlib, sys
out = pathlib.Path('/workspace/output')
stage = sys.argv[1]
manifest = json.loads(pathlib.Path('/workspace/input_manifest.json').read_text())
inputs = manifest['inputs']
def by_name(name):
    rows = [item for item in inputs if item['name'] == name]
    assert len(rows) == 1, (name, len(rows))
    return pathlib.Path(rows[0]['path'])
def by_id(identity):
    return pathlib.Path(next(item['path'] for item in inputs if item['id'] == identity))
''';

const _office =
    _common +
    r'''
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font
from docx import Document
def check(name, path, modified):
    if name.endswith('.xlsx'):
        wb = load_workbook(path)
        ws = wb.active
        assert ws['A1'].value == '中文表格' and ws['A1'].font.bold
        assert ws['A2'].value == (5 if modified else 1)
        assert ws['B1'].value == '=SUM(A2:A3)'
        wb.close()
    else:
        doc = Document(path)
        assert doc.paragraphs[0].text == '中文标题'
        assert doc.paragraphs[1].text == ('修改后正文' if modified else '原始正文')
        assert doc.tables[0].cell(0,0).text == ('修改后单元格' if modified else '原始单元格')
if stage == 'create':
    wb = Workbook(); ws = wb.active
    ws['A1'] = '中文表格'; ws['A1'].font = Font(bold=True)
    ws['A2'] = 1; ws['A3'] = 2; ws['B1'] = '=SUM(A2:A3)'
    wb.save(out/'data.xlsx'); wb.close()
    doc = Document(); doc.add_heading('中文标题',0); doc.add_paragraph('原始正文')
    doc.add_table(rows=1,cols=1).cell(0,0).text = '原始单元格'
    doc.save(out/'document.docx')
elif stage == 'edit':
    check('data.xlsx', by_name('data.xlsx'), False)
    check('document.docx', by_name('document.docx'), False)
    wb = load_workbook(by_name('data.xlsx')); wb.active['A2'] = 5
    wb.save(out/'data.xlsx'); wb.close()
    doc = Document(by_name('document.docx')); doc.paragraphs[1].text = '修改后正文'
    doc.tables[0].cell(0,0).text = '修改后单元格'; doc.save(out/'document.docx')
''';

const _graphics =
    _common +
    r'''
from pypdf import PdfReader, PdfWriter
from PIL import Image
def check(name, path, modified):
    if name.endswith('.pdf'):
        reader = PdfReader(path, strict=True)
        assert len(reader.pages) == 1
        assert reader.pages[0].rotation == (90 if modified else 0)
        assert reader.metadata.title == ('修改后文档' if modified else '原始文档')
    else:
        with Image.open(path) as image:
            assert image.format == 'PNG' and image.mode == 'RGBA' and image.size == (8,6)
            assert image.getpixel((2,3)) == ((255,0,0,128) if modified else (10,20,30,255))
            assert image.getpixel((0,0)) == (10,20,30,255)
if stage == 'create':
    writer = PdfWriter(); writer.add_blank_page(width=120,height=80)
    writer.add_metadata({'/Title':'原始文档'}); writer.write(out/'pages.pdf')
    Image.new('RGBA',(8,6),(10,20,30,255)).save(out/'pixels.png')
elif stage == 'edit':
    check('pages.pdf',by_name('pages.pdf'),False)
    check('pixels.png',by_name('pixels.png'),False)
    writer = PdfWriter(clone_from=by_name('pages.pdf')); writer.pages[0].rotate(90)
    writer.add_metadata({'/Title':'修改后文档'}); writer.write(out/'pages.pdf')
    with Image.open(by_name('pixels.png')) as image:
        image.putpixel((2,3),(255,0,0,128)); image.save(out/'pixels.png')
''';

const _verifyVersions = r'''
if stage == 'latest':
    for item in inputs: check(item['name'], pathlib.Path(item['path']), True)
    assert len(inputs) == 2
elif stage == 'versions':
    versions = json.loads(sys.argv[2])
    assert len(inputs) == 4
    for name, identities in versions.items():
        check(name, by_id(identities[0]), False)
        check(name, by_id(identities[1]), True)
print('BINARY_FORMAT_STAGE_VERIFIED:'+stage)
''';
