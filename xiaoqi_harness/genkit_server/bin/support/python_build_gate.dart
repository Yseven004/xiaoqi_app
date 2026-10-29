import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> verifyCombinedBuild(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  final importer = CapabilityImportService(
    store,
    prepareDependencies: executor.prepareDependencies,
  );
  final sources = <String, String>{
    'SKILL.md':
        '---\nname: combined-build\ndescription: Use a long combined Python and npm build\n---\nRun scripts/use.py.\n',
    'pyproject.toml': '''[build-system]
requires=["setuptools==80.9.0"]
build-backend="setuptools.build_meta"
[project]
name="xiaoqi-combined-fixture"
version="1.0.0"
[tool.setuptools]
py-modules=["combo_module"]
''',
    'combo_module.py': 'message="combined-python-module"\n',
    'package.json': jsonEncode({
      'name': 'xiaoqi-combined-fixture',
      'version': '1.0.0',
      'scripts': {'build': 'node scripts/slow-build.cjs'},
    }),
    'scripts/slow-build.cjs': r'''
const fs=require('node:fs');
if(process.getuid()===0 || fs.existsSync('/var/run/docker.sock')) throw new Error('build escaped isolation');
for(const name of ['MIMO_API_KEY','DEEPSEEK_API_KEY','SANDBOX_RUNNER_TOKEN'])
 if(process.env[name]) throw new Error('host credential reached build');
const started=performance.now();
setTimeout(()=>{fs.mkdirSync('dist',{recursive:true});
 fs.writeFileSync('dist/combined.json',JSON.stringify({built:true,elapsed_ms:performance.now()-started}));
},125000);
''',
    'scripts/use.py': r'''
import combo_module,json,pathlib
assert '/.xiaoqi/python/' in combo_module.__file__,combo_module.__file__
build=json.loads(pathlib.Path('/workspace/skill/dist/combined.json').read_text())
assert build['built'] and build['elapsed_ms']>=125000
pathlib.Path('/workspace/output/combined.json').write_text(json.dumps({'python':combo_module.message,'node':build['built']}))
''',
  };
  final archive = Archive();
  for (final entry in sources.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  final inspection = await importer.inspectUpload(
    tenant,
    'combined-build.zip',
    ZipEncoder().encode(archive),
  );
  final candidate = (inspection['candidates'] as List).single as Map;
  if (candidate['status'] != 'supported')
    throw StateError('Combined build rejected by inspection');
  stdout.writeln(
    jsonEncode({'checkpoint': 'combined-build', 'minimum_build_seconds': 125}),
  );
  final installed = await importer.install(
    tenant,
    inspection['id'],
    candidate['id'],
  );
  final selected = SelectedSkills(store, tenant, [
    {
      'id': installed.value['id'],
      'version_id': installed.value['current_version_id'],
    },
  ]);
  final files = selected.files(selected.entries.values.single);
  final lock =
      jsonDecode(utf8.decode(files['.xiaoqi/dependency-lock.json']!)) as Map;
  if (!(lock['python'] as List).whereType<Map>().any(
        (entry) => entry['source'] == 'local_project',
      ) ||
      (lock['npm'] as Map).isEmpty ||
      !files.containsKey('dist/combined.json'))
    throw StateError(
      'Combined build did not preserve both installation phases',
    );
  const task = 'installed-combined-build';
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  await executor.execute(
    tenantId: tenant,
    taskId: task,
    code: '# installed combined build',
    language: 'python',
    scriptPath: 'scripts/use.py',
    authorizedDomains: [],
    materials: [],
    skillFiles: files,
    cancellation: CancellationController().token,
  );
  final artifact =
      (store.get('task/$tenant/$task')!.value['artifacts'] as List).single
          as Map;
  final result =
      jsonDecode(utf8.decode(store.getObject(artifact['object_key']))) as Map;
  if (result['python'] != 'combined-python-module' || result['node'] != true)
    throw StateError('Combined built skill could not execute offline');
}

Future<void> verifyPythonBuild(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  final importer = CapabilityImportService(
    store,
    prepareDependencies: executor.prepareDependencies,
  );
  Future<Map<String, dynamic>> inspect(Map<String, String> files) async {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.add(ArchiveFile.string(entry.key, entry.value));
    }
    return importer.inspectUpload(
      tenant,
      'python-build.zip',
      ZipEncoder().encode(archive),
    );
  }

  for (final modern in [true, false]) {
    final kind = modern ? 'pyproject' : 'setup';
    final sources = <String, String>{
      'SKILL.md':
          '---\nname: $kind-build\ndescription: Use a packaged Python module\n---\nRun scripts/use.py.\n',
      'Dockerfile': 'FROM scratch\n',
      if (modern)
        'pyproject.toml':
            '''[build-system]
requires=["setuptools==80.9.0"]
build-backend="setuptools.build_meta"
[project]
name="xiaoqi-$kind-fixture"
version="1.0.0"
dependencies=["pypdf==6.1.3; python_version >= '3.9'"]
[project.scripts]
fixture-cli="project_module:main"
[tool.setuptools.packages.find]
where=["src"]
''',
      if (!modern)
        'setup.py': r'''
import os
assert os.getuid()!=0 and not os.path.exists('/var/run/docker.sock')
assert not any(os.environ.get(key) for key in ['MIMO_API_KEY','DEEPSEEK_API_KEY','SANDBOX_RUNNER_TOKEN'])
from setuptools import setup
setup(name='xiaoqi-setup-fixture',version='1.0.0',py_modules=['project_module'],install_requires=['pypdf==6.1.3'],entry_points={'console_scripts':['fixture-cli=project_module:main']})
''',
      modern ? 'src/project_module/__init__.py' : 'project_module.py':
          "message='$kind-封装构建成功'\ndef main():\n    print(message)\n",
      'scripts/use.py': r'''
import json,pathlib,subprocess
import project_module
from pypdf import PdfWriter
assert '/.xiaoqi/python/' in project_module.__file__, project_module.__file__
assert subprocess.check_output(['fixture-cli'],text=True).strip()==project_module.message
writer=PdfWriter();writer.add_blank_page(width=120,height=80)
pathlib.Path('/workspace/output/python-build.json').write_text(json.dumps({'message':project_module.message,'pages':len(writer.pages)},ensure_ascii=False))
''',
    };
    final inspection = await inspect(sources);
    final candidate = (inspection['candidates'] as List).single as Map;
    if (candidate['status'] != 'supported')
      throw StateError('Python packaging candidate rejected: $kind');
    final installed = await importer.install(
      tenant,
      inspection['id'],
      candidate['id'],
    );
    final selected = SelectedSkills(store, tenant, [
      {
        'id': installed.value['id'],
        'version_id': installed.value['current_version_id'],
      },
    ]);
    final files = selected.files(selected.entries.values.single);
    final lock =
        jsonDecode(utf8.decode(files['.xiaoqi/dependency-lock.json']!)) as Map;
    final local = (lock['python'] as List)
        .whereType<Map>()
        .where((entry) => entry['source'] == 'local_project')
        .single;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(local['source_sha256'].toString()))
      throw StateError('Local Python source identity is missing');
    if (!(lock['python'] as List).whereType<Map>().any(
      (entry) =>
          entry['name'].toString().toLowerCase() == 'pypdf' &&
          entry['version'] == '6.1.3',
    ))
      throw StateError('Python project dependency was not installed');
    final task = '$kind-build-runtime';
    store.put('task/$tenant/$task', {
      'status': 'running',
      'artifacts': [],
      'events': [],
    }, null);
    await executor.execute(
      tenantId: tenant,
      taskId: task,
      code: '# installed Python project',
      language: 'python',
      scriptPath: 'scripts/use.py',
      authorizedDomains: [],
      materials: [],
      skillFiles: files,
      cancellation: CancellationController().token,
    );
    final artifact =
        (store.get('task/$tenant/$task')!.value['artifacts'] as List).single
            as Map;
    final result =
        jsonDecode(utf8.decode(store.getObject(artifact['object_key']))) as Map;
    if (result['message'] != '$kind-封装构建成功' || result['pages'] != 1)
      throw StateError('Installed Python project did not run offline');
  }
}
