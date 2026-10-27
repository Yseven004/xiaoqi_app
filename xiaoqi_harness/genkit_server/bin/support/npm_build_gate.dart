import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> verifyNpmBuild(
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
        '---\nname: isolated-build\ndescription: Use a built local module\n---\nRun scripts/use.cjs.\n',
    'package.json': jsonEncode({
      'name': 'xiaoqi-build-fixture',
      'version': '1.0.0',
      'dependencies': {'esbuild': '0.25.12'},
      'devDependencies': {'picocolors': '1.1.1'},
      'scripts': {
        'postinstall': './scripts/install.sh',
        'build': 'node scripts/build.cjs',
      },
    }),
    'src/index.ts': 'export const message: string = "隔离构建成功";\n',
    'scripts/install.sh': '#!/bin/sh\nset -eu\nnode scripts/install.cjs\n',
    'scripts/install.cjs': r'''
const fs = require('node:fs');
for (const name of ['MIMO_API_KEY','DEEPSEEK_API_KEY','SANDBOX_RUNNER_TOKEN']) {
  if (process.env[name]) throw new Error('host credential reached installer');
}
if (process.getuid() === 0 || fs.existsSync('/var/run/docker.sock')) throw new Error('installer escaped its isolation');
fs.mkdirSync('dist',{recursive:true});
const marker = 'dist/install-count.json';
const prior = fs.existsSync(marker) ? JSON.parse(fs.readFileSync(marker)) : 0;
fs.writeFileSync(marker,JSON.stringify(prior+1));
''',
    'scripts/build.cjs': r'''
const fs = require('node:fs');
// esbuild's postinstall replaces this JS launcher with an ELF executable.
if (!fs.readFileSync('node_modules/esbuild/bin/esbuild').subarray(0,4).equals(Buffer.from([127,69,76,70]))) {
  throw new Error('dependency lifecycle did not prepare its native executable');
}
require('esbuild').buildSync({entryPoints:['src/index.ts'],outfile:'dist/index.cjs',bundle:true,platform:'node',format:'cjs'});
''',
    'scripts/use.cjs': r'''
const fs = require('node:fs');
const moduleResult = require('../dist/index.cjs');
const count = JSON.parse(fs.readFileSync('/workspace/skill/dist/install-count.json'));
if (count !== 1 || moduleResult.message !== '隔离构建成功') throw new Error('built result changed');
if (fs.existsSync('/workspace/skill/node_modules/picocolors')) throw new Error('build-only dependency was not pruned');
if (!require('esbuild').transformSync('const value: number = 42',{loader:'ts'}).code.includes('42')) throw new Error('installed native dependency cannot execute');
if (require('node:child_process').execFileSync('esbuild',['--version'],{encoding:'utf8'}).trim()!=='0.25.12') throw new Error('installed CLI shim did not run');
fs.writeFileSync('/workspace/output/build-result.json',JSON.stringify({message:moduleResult.message,install_count:count}));
''',
  };
  Future<Map<String, dynamic>> inspect(Map<String, String> files) async {
    final archive = Archive();
    for (final entry in files.entries) {
      final file = ArchiveFile.string(entry.key, entry.value);
      if (entry.key == 'scripts/install.sh') file.mode = 0x1ed;
      archive.add(file);
    }
    return importer.inspectUpload(
      tenant,
      'npm-build.zip',
      ZipEncoder().encode(archive),
    );
  }

  final inspection = await inspect(sources);
  final candidate = (inspection['candidates'] as List).single as Map;
  if (candidate['status'] != 'supported')
    throw StateError('Buildable npm skill rejected by inspection');
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
  if (!files.containsKey('dist/index.cjs') ||
      files.keys.any((name) => name.startsWith('.xiaoqi/built/'))) {
    throw StateError(
      'Built module was not delivered at its package-relative path',
    );
  }
  final lock =
      jsonDecode(utf8.decode(files['.xiaoqi/dependency-lock.json']!)) as Map;
  if ((lock['npm']['packages']['node_modules/esbuild']
          as Map)['hasInstallScript'] !=
      true) {
    throw StateError('Gate did not exercise a registry dependency lifecycle');
  }
  const task = 'installed-npm-build';
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  await executor.execute(
    tenantId: tenant,
    taskId: task,
    code: '// installed built skill',
    language: 'javascript',
    scriptPath: 'scripts/use.cjs',
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
  if (result['message'] != '隔离构建成功' || result['install_count'] != 1)
    throw StateError('Installed build did not run offline');
  final failedSources = {
    ...sources,
    'package.json': jsonEncode({
      'name': 'xiaoqi-build-fixture',
      'version': '2.0.0',
      'scripts': {'build': 'node scripts/build.cjs'},
    }),
    'scripts/build.cjs': "throw new Error('expected-build-failure');\n",
  };
  final failedInspection = await inspect(failedSources);
  final failedCandidate =
      (failedInspection['candidates'] as List).single as Map;
  var failed = false;
  try {
    await importer.install(
      tenant,
      failedInspection['id'],
      failedCandidate['id'],
      updateId: installed.value['id'],
      expectedRevision: installed.revision,
    );
  } on Object catch (error) {
    failed = error.toString().contains('expected-build-failure');
  }
  if (!failed ||
      store
              .get('cap/$tenant/${installed.value['id']}')!
              .value['current_version_id'] !=
          installed.value['current_version_id']) {
    throw StateError('Failed build replaced the healthy installed version');
  }
}
