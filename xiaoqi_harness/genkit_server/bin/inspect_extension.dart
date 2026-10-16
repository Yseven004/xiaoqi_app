import 'dart:convert';
import 'dart:io';
import '../lib/src/capability_import_service.dart';
import '../lib/src/store.dart';

/// Read-only public-repository smoke check; isolated scratch store, no install.
Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('xiaoqi-import-smoke-');
  final store = CloudStore(root: root.path);
  try {
    for (final url in args) {
      try {
        final result = await CapabilityImportService(
          store,
        ).inspect('smoke', url);
        stdout.writeln(jsonEncode(result));
      } catch (e) {
        stderr.writeln('$url: $e');
        exitCode = 1;
      }
    }
  } finally {
    store.close();
    await root.delete(recursive: true);
  }
}
