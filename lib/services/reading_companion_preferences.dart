import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReadingCompanionPreferences {
  ReadingCompanionPreferences._();

  static final instance = ReadingCompanionPreferences._();
  static const _key = 'reading-companion.enabled';

  final _enabled = ValueNotifier<bool>(true);
  Future<void>? _loading;

  ValueListenable<bool> get enabled => _enabled;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _enabled.value = preferences.getBool(_key) ?? true;
    } catch (_) {
      _loading = null;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await load();
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_key, enabled)) {
      throw StateError('伴读设置保存失败');
    }
    _enabled.value = enabled;
  }
}
