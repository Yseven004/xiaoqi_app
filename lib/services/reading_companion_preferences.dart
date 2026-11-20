import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReadingCompanionPreferences {
  ReadingCompanionPreferences._();

  static final instance = ReadingCompanionPreferences._();
  static const _key = 'reading-companion.enabled';

  final _enabled = ValueNotifier<bool>(true);
  Future<void>? _loading;
  bool _loaded = false;

  ValueListenable<bool> get enabled => _enabled;

  Future<void> load() async {
    if (_loaded) return;
    await (_loading ??= _load());
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final enabled = preferences.getBool(_key) ?? true;
      _loaded = true;
      _enabled.value = enabled;
    } catch (_) {
      // A later call can retry loading the preference.
    } finally {
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
