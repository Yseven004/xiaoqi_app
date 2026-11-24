import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

/// Returns false if the system denies album access.
Future<bool> saveImageToGallery({
  required Future<Uint8List> Function() loadImage,
  required String filename,
}) async {
  const request = PermissionRequestOption(
    iosAccessLevel: IosAccessLevel.addOnly,
    androidPermission: AndroidPermission(
      type: RequestType.image,
      mediaLocation: false,
    ),
  );
  var permission = await PhotoManager.getPermissionState(
    requestOption: request,
  );
  if (!permission.hasAccess) {
    permission = await PhotoManager.requestPermissionExtend(
      requestOption: request,
    );
  }
  if (!permission.hasAccess) return false;

  await PhotoManager.editor.saveImage(
    await loadImage(),
    filename: filename,
    title: filename,
    relativePath: Platform.isAndroid ? 'Pictures/Xiaoqi' : null,
  );
  return true;
}
