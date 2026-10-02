import 'package:flutter/material.dart';

import '../camera/camera_contract.dart';
import '../config/book_flow_theme.dart';
import '../models/capture_mode.dart';

class CameraLensSwitcher extends StatelessWidget {
  const CameraLensSwitcher({
    super.key,
    required this.lenses,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final List<CameraLensOption> lenses;
  final CameraLensOption? selected;
  final bool enabled;
  final ValueChanged<CameraLensOption> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final lens in lenses)
            Semantics(
              button: true,
              selected: selected?.id == lens.id,
              enabled: enabled,
              label: '${lens.displayLabel} 镜头',
              child: InkWell(
                key: Key('camera_lens_${lens.id}'),
                onTap: enabled ? () => onChanged(lens) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected?.id == lens.id
                        ? Colors.white
                        : Colors.transparent,
                  ),
                  child: Text(
                    lens.displayLabel,
                    style: TextStyle(
                      color: selected?.id == lens.id
                          ? Colors.black
                          : enabled
                          ? Colors.white
                          : Colors.white38,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 夸克式顶栏：← 返回 | 单页拍/双页拍 | 导入相册 + 设置
class ViewfinderCameraTopBar extends StatelessWidget {
  const ViewfinderCameraTopBar({
    super.key,
    required this.onBack,
    required this.enabled,
    required this.captureMode,
    required this.onCaptureModeChanged,
    required this.onImport,
    required this.onSettings,
  });

  final VoidCallback onBack;
  final bool enabled;
  final CaptureMode captureMode;
  final ValueChanged<CaptureMode> onCaptureModeChanged;
  final VoidCallback onImport;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BookFlowTheme.camera,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: 48,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    key: const Key('viewfinder_back'),
                    onPressed: enabled ? onBack : null,
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
                _CaptureModeToggle(
                  mode: captureMode,
                  enabled: enabled,
                  onChanged: onCaptureModeChanged,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    key: const Key('viewfinder_settings'),
                    onPressed: enabled ? onSettings : null,
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white,
                      size: 24,
                    ),
                    tooltip: '设置',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptureModeToggle extends StatelessWidget {
  const _CaptureModeToggle({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final CaptureMode mode;
  final bool enabled;
  final ValueChanged<CaptureMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF193033),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModePill(
            key: const Key('capture_mode_single'),
            label: '单页',
            selected: mode == CaptureMode.singlePage,
            enabled: enabled,
            onTap: () => onChanged(CaptureMode.singlePage),
          ),
          _ModePill(
            key: const Key('capture_mode_double'),
            label: '双页',
            selected: mode == CaptureMode.doublePage,
            enabled: enabled,
            onTap: () => onChanged(CaptureMode.doublePage),
          ),
        ],
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 38, minWidth: 66),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? BookFlowTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 夸克式底栏：居中快门 + 可选右侧 trailing（暂存托盘）
class ViewfinderCameraBottomBar extends StatelessWidget {
  const ViewfinderCameraBottomBar({
    super.key,
    required this.onShutter,
    required this.enabled,
    this.onImport,
    this.onHelp,
    this.captureMode = CaptureMode.singlePage,
    this.trailing,
  });

  final VoidCallback onShutter;
  final bool enabled;
  final VoidCallback? onImport;
  final VoidCallback? onHelp;
  final CaptureMode captureMode;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Equal Expanded sides keep the shutter optically centered when tray
    // mass sits on the right (Stack-centering reads left-heavy).
    final shutter = Semantics(
      button: true,
      enabled: enabled,
      label: '拍照',
      child: GestureDetector(
        key: const Key('viewfinder_shutter'),
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onShutter : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            padding: const EdgeInsets.all(5),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      height: 150,
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.menu_book_outlined, color: Colors.white, size: 19),
              SizedBox(width: 8),
              Text(
                '书籍识别',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Center(
                  child: IconButton(
                    key: const Key('viewfinder_import'),
                    tooltip: '从相册导入',
                    onPressed: enabled ? onImport : null,
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: const Color(0xFF193033),
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                ),
              ),
              shutter,
              Expanded(
                child: Center(
                  child:
                      trailing ??
                      IconButton(
                        key: const Key('viewfinder_help'),
                        tooltip: '拍摄帮助',
                        onPressed: enabled ? onHelp : null,
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: const Color(0xFF193033),
                          minimumSize: const Size(48, 48),
                        ),
                        icon: const Icon(Icons.help_outline_rounded),
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            captureMode == CaptureMode.doublePage
                ? '默认按左页 → 右页识别'
                : '请让单页完整进入取景框',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 闪光灯选择（UI 层，与 camera.FlashMode 解耦）
enum CameraFlashChoice { auto, on, off }

/// 夸克式设置面板：从顶部下拉的半透明深色面板 + 开灯 + 闪光灯
class ViewfinderCameraSettingsPanel extends StatelessWidget {
  const ViewfinderCameraSettingsPanel({
    super.key,
    required this.flashChoice,
    required this.onFlashChanged,
    required this.torchOn,
    required this.onTorchChanged,
    required this.levelEnabled,
    required this.onLevelChanged,
    this.skipBatchReview = false,
    this.onSkipBatchReviewChanged,
  });

  final CameraFlashChoice flashChoice;
  final ValueChanged<CameraFlashChoice> onFlashChanged;
  final bool torchOn;
  final ValueChanged<bool> onTorchChanged;
  final bool levelEnabled;
  final ValueChanged<bool> onLevelChanged;
  final bool skipBatchReview;
  final ValueChanged<bool>? onSkipBatchReviewChanged;

  static const _labelStyle = TextStyle(
    color: Colors.white,
    fontSize: 15,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE61A1A1A),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 56, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 开灯 (第一行) — 关闭/开启 双段药丸
              Row(
                children: [
                  const Icon(
                    Icons.flashlight_on,
                    color: Colors.white70,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('开灯', style: _labelStyle)),
                  _TorchSlidingPill(
                    key: const Key('viewfinder_torch'),
                    on: torchOn,
                    onChanged: onTorchChanged,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.screen_rotation_alt,
                    color: Colors.white70,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('水平辅助', style: _labelStyle)),
                  Switch.adaptive(
                    key: const Key('viewfinder_level'),
                    value: levelEnabled,
                    activeTrackColor: const Color(0xFF4ADE80),
                    onChanged: onLevelChanged,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.fact_check_outlined,
                    color: Colors.white70,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('拍摄后确认', style: _labelStyle)),
                  Switch.adaptive(
                    key: const Key('viewfinder_batch_review'),
                    value: !skipBatchReview,
                    activeTrackColor: BookFlowTheme.primary,
                    onChanged: (enabled) =>
                        onSkipBatchReviewChanged?.call(!enabled),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 闪光灯 (第二行) — 三段滑动药丸（自动=黄 / 开启=绿 / 关闭=灰）
              Row(
                children: [
                  const Icon(Icons.flash_on, color: Colors.white70, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('闪光灯', style: _labelStyle)),
                  _FlashSlidingPill(
                    key: const Key('viewfinder_flash'),
                    value: flashChoice,
                    onChanged: onFlashChanged,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 开灯：关闭 / 开启 双段滑动药丸（开启=绿）
// ---------------------------------------------------------------------------
class _TorchSlidingPill extends StatelessWidget {
  const _TorchSlidingPill({
    super.key,
    required this.on,
    required this.onChanged,
  });

  final bool on;
  final ValueChanged<bool> onChanged;

  static const _options = <(bool, String)>[(false, '关闭'), (true, '开启')];
  static const _green = Color(0xFF4CAF50);
  static const _dark = Color(0xFF555555);
  static const _bg = Color(0x33FFFFFF);
  static const _pillRadius = 14.0;
  static const _indRadius = 11.0;
  static const double _segW = 48;

  @override
  Widget build(BuildContext context) {
    final selIdx = on ? 1 : 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(_pillRadius),
      ),
      child: SizedBox(
        height: 28,
        width: _segW * 2,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              left: selIdx * _segW,
              top: 2,
              bottom: 2,
              width: _segW,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: on ? _green : _dark,
                  borderRadius: BorderRadius.circular(_indRadius),
                ),
              ),
            ),
            Row(
              children: [
                for (final (value, label) in _options)
                  SizedBox(
                    width: _segW,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(value),
                      child: Center(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: value == on
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 闪光灯：三段滑动药丸（关闭=灰 / 开启=绿 / 自动=黄）
// ---------------------------------------------------------------------------
class _FlashSlidingPill extends StatelessWidget {
  const _FlashSlidingPill({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final CameraFlashChoice value;
  final ValueChanged<CameraFlashChoice> onChanged;

  static const _options = <(CameraFlashChoice, String)>[
    (CameraFlashChoice.off, '关闭'),
    (CameraFlashChoice.on, '开启'),
    (CameraFlashChoice.auto, '自动'),
  ];

  static const _green = Color(0xFF4CAF50);
  static const _yellow = Color(0xFFF5C518);
  static const _dark = Color(0xFF555555);
  static const _bg = Color(0x33FFFFFF);
  static const _pillRadius = 14.0;
  static const _indRadius = 11.0;
  static const double _segW = 48;

  Color get _indicatorColor => switch (value) {
    CameraFlashChoice.auto => _yellow,
    CameraFlashChoice.on => _green,
    CameraFlashChoice.off => _dark,
  };

  @override
  Widget build(BuildContext context) {
    final selIdx = _options.indexWhere((o) => o.$1 == value).clamp(0, 2);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(_pillRadius),
      ),
      child: SizedBox(
        height: 28,
        width: _segW * 3,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              left: selIdx * _segW,
              top: 2,
              bottom: 2,
              width: _segW,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: _indicatorColor,
                  borderRadius: BorderRadius.circular(_indRadius),
                ),
              ),
            ),
            Row(
              children: [
                for (int i = 0; i < 3; i++)
                  SizedBox(
                    width: _segW,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(_options[i].$1),
                      child: Center(
                        child: Text(
                          _options[i].$2,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: i == selIdx
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
