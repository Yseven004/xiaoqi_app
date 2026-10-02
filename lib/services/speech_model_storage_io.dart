import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> installSpeechModelAsset(String assetPath) async {
  final supportDirectory = await getApplicationSupportDirectory();
  final modelDirectory =
      Directory(p.join(supportDirectory.path, 'speech_models'));
  await modelDirectory.create(recursive: true);

  final target = File(p.join(modelDirectory.path, p.basename(assetPath)));
  if (await target.exists() && await target.length() > 0) return target.path;

  final temporary = File('${target.path}.tmp');
  if (await temporary.exists()) await temporary.delete();
  final data = await rootBundle.load(assetPath);
  await temporary.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  if (await target.exists()) await target.delete();
  return (await temporary.rename(target.path)).path;
}
