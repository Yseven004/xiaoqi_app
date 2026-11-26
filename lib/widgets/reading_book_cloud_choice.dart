import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_source.dart';
import '../services/reading_book_preparation.dart';
import 'app_toast.dart';

typedef ReadingBookCloudChoice = ({bool enabled, String? accountEmail});

Future<ReadingBookCloudChoice?> showReadingBookCloudChoice(
  BuildContext context,
) async {
  final email = (await ReadingBookPreparation.instance.chosenAccount())?.trim();
  final accountEmail = email != null && email.isNotEmpty ? email : null;
  final canUpload = accountEmail != null;
  if (!context.mounted) return null;
  final enabled = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black38,
    builder: (dialogContext) {
      final dark = Theme.of(dialogContext).brightness == Brightness.dark;
      final surface = dark ? const Color(0xFF222222) : BookFlowTheme.surface;
      final ink = dark ? Colors.white : BookFlowTheme.ink;
      final secondaryInk = dark
          ? const Color(0xFFC6C6C6)
          : BookFlowTheme.inkSecondary;
      final border = BorderSide(
        color: dark ? const Color(0xFF515151) : const Color(0xFFE0E0E0),
      );
      final buttonShape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      );
      const buttonSize = Size.fromHeight(48);
      const buttonPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 8);
      final localOnly = TextButton(
        onPressed: () => Navigator.pop(dialogContext, false),
        style: TextButton.styleFrom(
          foregroundColor: ink,
          side: border,
          minimumSize: buttonSize,
          padding: buttonPadding,
          shape: buttonShape,
        ),
        child: const Text('仅保存在本机', textAlign: TextAlign.center),
      );
      return AlertDialog(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        constraints: const BoxConstraints(maxWidth: 420),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: border,
        ),
        scrollable: true,
        title: const Text('导入书籍资料'),
        titleTextStyle: BookFlowTheme.heading.copyWith(color: ink),
        content: Text(
          canUpload
              ? '原文件可在后台上传，供伴读查找书内原文。导入成功就可以阅读。'
              : '登录后可开启整书云端准备。现在可以导入并在本机阅读。',
        ),
        contentTextStyle: BookFlowTheme.body.copyWith(color: secondaryInk),
        actionsAlignment: MainAxisAlignment.start,
        actions: [
          if (canUpload)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: localOnly),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: ink,
                        foregroundColor: surface,
                        minimumSize: buttonSize,
                        padding: buttonPadding,
                        elevation: 0,
                        shape: buttonShape,
                      ),
                      child: const Text('导入并准备伴读', textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
            )
          else
            localOnly,
        ],
      );
    },
  );
  return enabled == null
      ? null
      : (enabled: enabled, accountEmail: accountEmail);
}

Future<void> saveReadingBookCloudChoice(
  BuildContext? context,
  BookSourceRecord source,
  ReadingBookCloudChoice choice,
) async {
  try {
    await ReadingBookPreparation.instance.recordImport(
      source,
      cloudEnabled: choice.enabled,
      accountEmail: choice.accountEmail,
    );
  } on Object {
    if (context != null && context.mounted) {
      AppToast.show(context, '资料已导入，云端准备暂不可用');
    }
  }
}
