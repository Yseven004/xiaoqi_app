import 'package:flutter/material.dart';

class AppTextInputDialog extends StatefulWidget {
  const AppTextInputDialog({
    super.key,
    required this.title,
    required this.label,
    this.initialText = '',
    this.actionLabel = '保存',
    this.maxLength,
  });

  final String title;
  final String label;
  final String initialText;
  final String actionLabel;
  final int? maxLength;

  @override
  State<AppTextInputDialog> createState() => _AppTextInputDialogState();
}

class _AppTextInputDialogState extends State<AppTextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: Text(widget.actionLabel),
      ),
    ],
  );
}
