import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/online_book_search.dart';
import 'app_toast.dart';

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
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _search.enabled,
    builder: (context, enabled, _) {
      final value = _pending ?? enabled ?? false;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 64,
        leading: Container(
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SvgPicture.asset(
            'assets/images/online_book_search.svg',
            excludeFromSemantics: true,
          ),
        ),
        title: const Text(
          '网上找书',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          _failed ? '设置读取失败，轻触重试' : '查找并导入电子书',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Switch(
          value: value,
          activeThumbColor: Colors.white,
          activeTrackColor: const Color(0xFF289B4C),
          onChanged: _loading || _failed || _pending != null ? null : _toggle,
        ),
        onTap: _failed
            ? _load
            : _loading || _pending != null
            ? null
            : () => _toggle(!value),
      );
    },
  );
}
