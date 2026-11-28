import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Lets the current annotation editor handle Android Back before the keyboard.
class AnnotationEditorBack extends StatefulWidget {
  const AnnotationEditorBack({required this.child, super.key});

  final Widget child;

  @override
  State<AnnotationEditorBack> createState() => _AnnotationEditorBackState();
}

class _AnnotationEditorBackState extends State<AnnotationEditorBack> {
  static const _runtimeConfig = MethodChannel('xiaoqi_app/runtime_config');
  static _AnnotationEditorBackState? _owner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (ModalRoute.isCurrentOf(context) != true) {
      _releaseBack();
      return;
    }

    final register = _owner == null;
    _owner = this;
    if (register) unawaited(_setAndroidBackEnabled(true));
  }

  void _releaseBack() {
    if (!identical(_owner, this)) return;
    _owner = null;
    unawaited(_setAndroidBackEnabled(false));
  }

  static Future<void> _setAndroidBackEnabled(bool enabled) async {
    try {
      await _runtimeConfig.invokeMethod<void>(
        'setAnnotationEditorBackEnabled',
        {'enabled': enabled},
      );
    } on MissingPluginException {
      // The regular Flutter back handler remains available.
    } on PlatformException catch (error) {
      debugPrint('Unable to update annotation back handling: ${error.code}');
    }
  }

  @override
  void dispose() {
    _releaseBack();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
