import 'dart:async';

import 'package:flutter/material.dart';

import '../services/online_book_search.dart';
import 'app_toast.dart';
import 'xiaoqi_switch_tile.dart';

class OnlineBookSearchSetting extends StatefulWidget {
  const OnlineBookSearchSetting({super.key});

  @override
  State<OnlineBookSearchSetting> createState() =>
      _OnlineBookSearchSettingState();
}

class _OnlineBookSearchSettingState extends State<OnlineBookSearchSetting> {
  final _search = OnlineBookSearch.instance;
  bool? _pending;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await _search.loadEnabled();
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_pending != null || _loading || _failed) return;
    setState(() => _pending = value);
    try {
      await _search.setEnabled(value);
    } on Object {
      if (mounted) AppToast.show(context, '设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool?>(
    valueListenable: _search.enabled,
    builder: (context, enabled, _) => XiaoqiSwitchTile(
      title: '网上找书',
      subtitle: _failed
          ? '设置读取失败，轻触重试'
          : _loading
          ? '正在读取设置…'
          : '查找并导入电子书',
      iconAsset: 'assets/images/online_book_search.svg',
      iconPadding: 5,
      value: _loading || _failed ? null : _pending ?? enabled,
      onChanged: _loading || _failed || _pending != null ? null : _toggle,
      onRetry: _failed ? _load : null,
    ),
  );
}
