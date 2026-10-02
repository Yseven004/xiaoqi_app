import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../config/colors.dart';
import '../services/database_service.dart';
import '../services/home_chat_model_preferences.dart';
import '../models/user.dart';
import '../widgets/app_toast.dart';
import '../widgets/home_chat_model_selector.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final DatabaseService _db = DatabaseService();
  final HomeChatModelPreferences _modelPreferences =
      HomeChatModelPreferences.instance;
  User? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _modelPreferences.load().catchError((_) {});
  }

  Future<void> _loadUser() async {
    final user = await _db.getUser();
    if (!mounted) return;
    setState(() => _user = user);
  }

  Future<void> _editNickname() async {
    final controller = TextEditingController(text: _user?.nickname ?? '同学');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          autofocus: false,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '请输入昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _db.upsertUser(result);
      await _loadUser();
    }
  }

  Future<void> _editHomeChatDefaults() async {
    await _modelPreferences.load();
    if (!mounted) return;
    final selection = await showModalBottomSheet<HomeChatModelSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => HomeChatModelSelectionSheet(
        initialSelection: _modelPreferences.defaultSelection.value,
      ),
    );
    if (selection == null) return;
    try {
      await _modelPreferences.saveDefault(selection);
    } catch (_) {
      if (mounted) AppToast.show(context, '新对话默认值保存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
      ),
      backgroundColor: AppColors.background,
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 头像
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Text(
                  '7',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 昵称
            GestureDetector(
              onTap: _editNickname,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _user?.nickname ?? '同学',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.edit,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '点击修改昵称',
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '新对话默认值',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<HomeChatModelSelection>(
              valueListenable: _modelPreferences.defaultSelection,
              builder: (context, selection, _) => Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE9EAEC)),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _editHomeChatDefaults,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          SvgPicture.asset(
                            selection.model.iconAsset,
                            width: 21,
                            height: 21,
                            colorFilter:
                                selection.model.id == HomeChatModelOption.mimo.id
                                ? const ColorFilter.mode(
                                    Color(0xFFFF6900),
                                    BlendMode.srcIn,
                                  )
                                : null,
                            excludeFromSemantics: true,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '新对话默认模型与思考程度',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${selection.model.name} · ${selection.reasoningLevel.label}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textTertiary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.chevron_right,
                            color: AppColors.textTertiary,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
