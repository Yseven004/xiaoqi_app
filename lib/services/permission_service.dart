import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static final PermissionService _instance = PermissionService._internal();

  factory PermissionService() => _instance;

  PermissionService._internal();

  /// 请求相机权限
  Future<bool> requestCameraPermission() async {
    try {
      final status = await Permission.camera.status;
      debugPrint('[XiaoQi] Permission: 相机权限状态=$status');

      if (status.isGranted) return true;

      if (status.isPermanentlyDenied) return false;

      final result = await Permission.camera.request();
      debugPrint('[XiaoQi] Permission: 请求相机权限结果=$result');
      return result.isGranted;
    } catch (e) {
      debugPrint('[XiaoQi] Permission: 请求相机权限异常: $e');
      return false;
    }
  }

  /// 是否已有相机权限（不弹系统对话框）。
  Future<bool> isCameraGranted() async {
    try {
      return (await Permission.camera.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 请求相册权限
  Future<bool> requestGalleryPermission() async {
    try {
      final status = await Permission.photos.status;
      debugPrint('[XiaoQi] Permission: 相册权限状态=$status');

      if (status.isGranted) return true;

      if (status.isPermanentlyDenied) return false;

      final result = await Permission.photos.request();
      debugPrint('[XiaoQi] Permission: 请求相册权限结果=$result');
      return result.isGranted;
    } catch (e) {
      debugPrint('[XiaoQi] Permission: 请求相册权限异常: $e');
      return false;
    }
  }

  /// 显示权限被拒绝的提示弹窗
  void showPermissionDeniedDialog(
    BuildContext context,
    String permissionName,
  ) {
    final operation =
        permissionName == '相机' ? '拍照' : '选择图片';

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('权限提示'),
          content: Text('需要$permissionName权限才能$operation哦'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
    debugPrint('[XiaoQi] Permission: 显示$permissionName权限拒绝弹窗');
  }
}
