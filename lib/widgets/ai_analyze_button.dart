import 'dart:async';
import 'package:flutter/material.dart';
import '../config/api_config.dart';
import '../config/colors.dart';
import '../models/ai_analysis_result.dart';
import '../models/note.dart';
import '../services/ai_service.dart';
import 'app_toast.dart';
import 'ai_usage_indicator.dart';

enum _ButtonState { available, loading, exhausted }

class AiAnalyzeButton extends StatefulWidget {
  final Note note;
  final void Function(AiAnalysisResult result) onAnalysisComplete;

  const AiAnalyzeButton({
    super.key,
    required this.note,
    required this.onAnalysisComplete,
  });

  @override
  State<AiAnalyzeButton> createState() => _AiAnalyzeButtonState();
}

class _AiAnalyzeButtonState extends State<AiAnalyzeButton>
    with TickerProviderStateMixin {
  final AiService _aiService = AiService();

  _ButtonState _state = _ButtonState.available;
  bool _isAnalyzing = false;
  String _loadingText = '正在分析...';
  Timer? _loadingTextTimer1;
  Timer? _loadingTextTimer2;
  int _todayUsage = 0;

  // 动效
  late AnimationController _glowController;
  late AnimationController _pressController;
  late Animation<double> _pressScaleAnimation;
  bool _glowShown = false;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _pressScaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeIn),
    );
    _checkAvailability();
    _startGlowIfNeeded();
  }

  @override
  void dispose() {
    _loadingTextTimer1?.cancel();
    _loadingTextTimer2?.cancel();
    _glowController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  Future<void> _checkAvailability() async {
    try {
      final count = await _aiService.getTodayUsageCount();
      if (!mounted) return;
      setState(() {
        _todayUsage = count;
        if (_todayUsage >= ApiConfig.dailyAiLimit) {
          _state = _ButtonState.exhausted;
        }
      });
    } catch (e) {
      debugPrint('[XiaoQi] AiAnalyzeBtn: 查询次数失败: $e');
    }
  }

  void _startGlowIfNeeded() {
    if (_glowShown) return;
    _glowShown = true;
    _glowController.forward().then((_) {
      if (mounted) _glowController.reverse();
    });
  }

  double _getGlowBlurRadius() {
    if (!_glowShown || _glowController.isCompleted || _glowController.isDismissed) {
      return 8;
    }
    return 8 + 8 * (1 - ((_glowController.value - 0.5).abs() * 2));
  }

  Future<void> _onTap() async {
    if (_state == _ButtonState.loading || _state == _ButtonState.exhausted) return;
    if (_isAnalyzing) return;

    setState(() {
      _state = _ButtonState.loading;
      _isAnalyzing = true;
      _loadingText = '正在分析...';
    });

    _startLoadingTextTimer();

    try {
      final result = await _aiService.analyzeNote(widget.note);

      if (!mounted) return;

      // 成功 → 计次
      await _aiService.recordUsage(widget.note.id!);
      final newCount = await _aiService.getTodayUsageCount();

      if (!mounted) return;

      _loadingTextTimer1?.cancel();
      _loadingTextTimer2?.cancel();
      setState(() {
        _isAnalyzing = false;
        _todayUsage = newCount;
        _state = newCount >= ApiConfig.dailyAiLimit ? _ButtonState.exhausted : _ButtonState.available;
      });

      // 微闪 → "✓ 分析完成" → 回调
      await _showSuccessAnimation();
      if (!mounted) return;

      widget.onAnalysisComplete(result);
    } on TimeoutException {
      if (!mounted) return;
      _handleError();
    } catch (e) {
      debugPrint('[XiaoQi] AiAnalyzeBtn: 分析异常: $e');
      if (!mounted) return;
      _handleError();
    }
  }

  void _startLoadingTextTimer() {
    _loadingTextTimer1?.cancel();
    _loadingTextTimer2?.cancel();
    // 2s 后切换
    _loadingTextTimer1 = Timer(const Duration(seconds: 2), () {
      if (mounted && _state == _ButtonState.loading) {
        setState(() => _loadingText = '深度分析中...');
      }
    });
    // 6s 后切换
    _loadingTextTimer2 = Timer(const Duration(seconds: 6), () {
      if (mounted && _state == _ButtonState.loading) {
        setState(() => _loadingText = '快好了...');
      }
    });
  }

  void _handleError() {
    _loadingTextTimer1?.cancel();
    _loadingTextTimer2?.cancel();
    setState(() {
      _isAnalyzing = false;
      _state = _todayUsage >= ApiConfig.dailyAiLimit ? _ButtonState.exhausted : _ButtonState.available;
    });
    if (mounted) {
      AppToast.show(context, 'AI服务暂时不可用，稍后再试');
    }
  }

  Future<void> _showSuccessAnimation() async {
    setState(() => _loadingText = '✓ 分析完成');
    await Future.delayed(const Duration(milliseconds: 400));
  }

  @override
  Widget build(BuildContext context) {
    final isDisabled = _state == _ButtonState.loading || _state == _ButtonState.exhausted;

    String buttonText;
    if (_state == _ButtonState.loading) {
      buttonText = _loadingText;
    } else if (_state == _ButtonState.exhausted) {
      buttonText = '✨ 今日次数已用完';
    } else {
      buttonText = '笔记分析';
    }

    Widget child;
    if (_state == _ButtonState.loading) {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.onAccent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _loadingText,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.hint,
            ),
          ),
        ],
      );
    } else {
      child = Text(
        buttonText,
        style: TextStyle(
          fontSize: 16,
          color: isDisabled ? AppColors.hint : AppColors.onAccent,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: (_) {
            if (!isDisabled) {
              _pressController.forward();
              _glowController.stop();
            }
          },
          onTapUp: (_) {
            if (!isDisabled) {
              _pressController.reverse();
            }
            _onTap();
          },
          onTapCancel: () {
            if (!isDisabled) {
              _pressController.reverse();
            }
          },
          child: Transform.scale(
            scale: _pressScaleAnimation.value,
            child: Container(
              height: 48,
              width: double.infinity,
              decoration: BoxDecoration(
                color: isDisabled ? AppColors.disabled : AppColors.accent,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadow,
                    offset: const Offset(0, 2),
                    blurRadius: _getGlowBlurRadius(),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
        AiUsageIndicator(usedCount: _todayUsage),
      ],
    );
  }
}
