import 'package:flutter/material.dart';

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
    builder: (dialogContext) => AlertDialog(
      title: const Text('导入书籍资料'),
      content: Text(
        canUpload
            ? '原文件可在后台上传，供伴读查找书内原文。导入成功就可以阅读。'
            : '登录后可开启整书云端准备。现在可以导入并在本机阅读。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('仅保存在本机'),
        ),
        if (canUpload)
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('导入并准备伴读'),
          ),
      ],
    ),
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
