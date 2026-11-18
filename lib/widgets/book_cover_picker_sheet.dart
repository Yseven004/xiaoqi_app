import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/book_flow_theme.dart';
import '../models/book_recognition.dart';
import 'app_toast.dart';
import 'book_cover.dart';

Future<BookRecord?> showBookCoverPicker(
  BuildContext context, {
  required BookRecord initial,
  bool persistOnSelect = true,
}) => showDialog<BookRecord>(
  context: context,
  barrierDismissible: true,
  barrierColor: const Color(0x99000000),
  builder: (_) =>
      BookCoverPickerSheet(initial: initial, persistOnSelect: persistOnSelect),
);

Future<String> persistBookCoverImage(String sourcePath) async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = p.normalize(p.join(documents.path, 'book_covers'));
  final normalizedSource = p.normalize(p.absolute(sourcePath));
  final source = File(normalizedSource);
  if (!await source.exists()) throw StateError('找不到已选择的封面图片');
  await Directory(directory).create(recursive: true);
  final extension = p.extension(normalizedSource).toLowerCase();
  const allowedExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.heic',
    '.heif',
  };
  final safeExtension = allowedExtensions.contains(extension)
      ? extension
      : '.jpg';
  final target = p.join(
    directory,
    'cover_${DateTime.now().microsecondsSinceEpoch}$safeExtension',
  );
  try {
    return (await source.copy(target)).path;
  } catch (_) {
    final partial = File(target);
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
}

class BookCoverPickerSheet extends StatefulWidget {
  const BookCoverPickerSheet({
    super.key,
    required this.initial,
    required this.persistOnSelect,
  });

  final BookRecord initial;
  final bool persistOnSelect;

  @override
  State<BookCoverPickerSheet> createState() => _BookCoverPickerSheetState();
}

class _BookCoverPickerSheetState extends State<BookCoverPickerSheet> {
  final _picker = ImagePicker();
  bool _picking = false;

  bool get _hasOriginalCover => widget.initial.coverUrl.trim().isNotEmpty;

  void _restoreOriginal() {
    if (!_hasOriginalCover) return;
    Navigator.of(
      context,
    ).pop(widget.initial.copyWith(coverType: 'auto', coverPath: ''));
  }

  Future<void> _chooseUploadSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              minTileHeight: 56,
              title: const Text('从相册选择'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            ListTile(
              minTileHeight: 56,
              title: const Text('拍摄封面'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    await _pickImage(source);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1200,
        maxHeight: 1800,
      );
      if (file == null || !mounted) return;
      final coverPath = widget.persistOnSelect
          ? await persistBookCoverImage(file.path)
          : file.path;
      if (!mounted) {
        if (widget.persistOnSelect) {
          final storedImage = File(coverPath);
          if (await storedImage.exists()) await storedImage.delete();
        }
        return;
      }
      Navigator.of(context).pop(
        widget.initial.copyWith(coverType: 'uploaded', coverPath: coverPath),
      );
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '图片读取失败，请检查相册或相机权限后重试：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * .84;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440, maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('编辑封面', style: BookFlowTheme.heading),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Center(
                child: SizedBox(
                  width: 126,
                  height: 178,
                  child: BookCover(book: widget.initial, borderRadius: 8),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: !_picking && _hasOriginalCover
                          ? _restoreOriginal
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BookFlowTheme.ink,
                        minimumSize: const Size.fromHeight(52),
                        side: const BorderSide(color: Color(0xFFD5D8DE)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('恢复原封面'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const Key('book_cover_upload_button'),
                      onPressed: _picking ? null : _chooseUploadSource,
                      style: FilledButton.styleFrom(
                        backgroundColor: BookFlowTheme.ink,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(_picking ? '读取中…' : '上传封面'),
                    ),
                  ),
                ],
              ),
              if (!_hasOriginalCover) ...[
                const SizedBox(height: 8),
                const Text(
                  '这本书没有可恢复的原书封面。',
                  textAlign: TextAlign.center,
                  style: BookFlowTheme.caption,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
