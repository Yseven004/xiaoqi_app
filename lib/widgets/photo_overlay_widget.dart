import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../features/photo_editor/photo_editor_page.dart';
import '../services/robot_overlay.dart';


/// 照片悬浮预览层 - 支持多张照片、上滑删除、双指缩放、返回手势关闭
class PhotoOverlayWidget extends StatefulWidget {
  final List<String> imagePaths;
  final VoidCallback onClose;

  const PhotoOverlayWidget({
    super.key,
    required this.imagePaths,
    required this.onClose,
  });

  @override
  State<PhotoOverlayWidget> createState() => _PhotoOverlayWidgetState();
}

class _PhotoOverlayWidgetState extends State<PhotoOverlayWidget>
    with TickerProviderStateMixin {
  late AnimationController _bgController;
  late AnimationController _floatController;
  late List<AnimationController> _photoControllers;
  late List<AnimationController> _buttonControllers;
  late AnimationController _flyController;

  late Animation<double> _bgFade;
  late Animation<double> _floatAnim;

  int _currentPage = 0;
  late PageController _pageController;

  // 手势状态
  double _dragOffsetY = 0;
  double _dragOffsetX = 0;
  bool _isDragging = false;

  // 飞出动画目标值
  double _flyTargetX = 0;
  double _flyTargetY = -1000;
  double _flyRotation = 0;
  bool _isFlying = false;

  @override
  void initState() {
    super.initState();

    _pageController = PageController();

    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _bgFade = CurvedAnimation(parent: _bgController, curve: Curves.easeOut);

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _floatAnim = Tween<double>(begin: -8.0, end: 8.0).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut),
    );

    // 飞出动画控制器
    _flyController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _photoControllers = List.generate(
      widget.imagePaths.length,
      (index) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      ),
    );

    _buttonControllers = List.generate(
      2,
      (index) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1000),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAnimations();
    });
  }

  void _startAnimations() {
    _bgController.forward();
    for (var c in _photoControllers) {
      c.forward();
    }
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        for (var c in _buttonControllers) {
          c.forward();
        }
      }
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) {
        _floatController.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _bgController.dispose();
    _floatController.dispose();
    _flyController.dispose();
    for (var c in _photoControllers) {
      c.dispose();
    }
    for (var c in _buttonControllers) {
      c.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  void _handleClose() {
    _floatController.stop();
    _bgController.reverse().then((_) {
      widget.onClose();
    });
  }

  // 手势同步：手指移动多少，照片就移动多少
  void _onPanUpdate(DragUpdateDetails details) {
    if (_isFlying) return;
    setState(() {
      _dragOffsetX += details.delta.dx;
      _dragOffsetY += details.delta.dy;
      _isDragging = true;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isFlying) return;

    final velocity = details.primaryVelocity ?? 0;

    // 判断是否需要飞出删除：向上拖动超过阈值或快速向上甩
    if (_dragOffsetY < -150 || velocity < -800) {
      _flyAway();
    } else {
      // 弹回原位
      _snapBack();
    }
  }

  void _flyAway() {
    setState(() {
      _isFlying = true;
      // 根据当前拖动位置决定飞出方向和旋转角度
      _flyTargetX = _dragOffsetX * 2; // 水平方向延续
      _flyTargetY = -1500; // 向上飞出屏幕
      _flyRotation = (_dragOffsetX > 0 ? 1 : -1) * (pi / 4); // 飞出时旋转45度
    });

    _flyController.forward(from: 0).then((_) {
      _onDeletePhoto(_currentPage);
    });
  }

  void _snapBack() {
    // 弹回时不播放飞出动画，直接重置状态
    setState(() {
      _dragOffsetX = 0;
      _dragOffsetY = 0;
      _isDragging = false;
    });
  }

  // 根据拖动距离计算当前卡片的变换属性
  double get _currentOffsetX {
    if (_isFlying) {
      return _flyController.value * _flyTargetX;
    }
    return _dragOffsetX;
  }

  double get _currentOffsetY {
    if (_isFlying) {
      return _dragOffsetY + (_flyController.value * (_flyTargetY - _dragOffsetY));
    }
    return _dragOffsetY;
  }

  double get _currentRotation {
    if (_isFlying) {
      // 飞出时从当前拖动角度插值到目标旋转角度
      final dragRotation = (_dragOffsetX / 300).clamp(-0.3, 0.3);
      return dragRotation + (_flyController.value * (_flyRotation - dragRotation));
    }
    return (_dragOffsetX / 300).clamp(-0.3, 0.3);
  }

  double get _currentScale {
    if (_isFlying) {
      // 飞出时缩小
      return 1.0 - (_flyController.value * 0.5);
    }
    // 拖动时轻微缩小
    final dragScale = 1.0 - (_dragOffsetY.abs() / 1000).clamp(0.0, 0.1);
    return dragScale;
  }

  double get _currentOpacity {
    if (_isFlying) {
      return 1.0 - (_flyController.value * 0.8);
    }
    // 拖动时变透明
    if (_dragOffsetY < -30) {
      return (1.0 + (_dragOffsetY / 200)).clamp(0.5, 1.0);
    }
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final topPadding = MediaQuery.of(context).padding.top;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _bgController,
        _floatController,
        _flyController,
        ..._photoControllers,
        ..._buttonControllers,
      ]),
      builder: (context, child) {
        return Opacity(
          opacity: _bgFade.value,
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _handleClose();
            },
            child: GestureDetector(
              onTap: _handleClose,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Container(
                  color: Colors.black.withValues(alpha: 0.45 * _bgFade.value),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 8 * _bgFade.value,
                      sigmaY: 8 * _bgFade.value,
                    ),
                    child: Column(
                      children: [
                        SizedBox(height: topPadding + 30),

                        // 照片区域
                        Expanded(
                          child: _buildPhotoArea(screenWidth, screenHeight),
                        ),

                        // 指示器
                        if (widget.imagePaths.length > 1) ...[
                          const SizedBox(height: 16),
                          _buildPageIndicator(),
                          const SizedBox(height: 16),
                        ],

                        // 提示文字
                        if (_isDragging && !_isFlying && _dragOffsetY < -30)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '松手删除',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 14,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),

                        // 按钮区域
                        _buildFloatingActions(),
                        SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotoArea(double screenWidth, double screenHeight) {
    if (widget.imagePaths.length == 1) {
      return Center(
        child: Transform.translate(
          offset: Offset(0, _floatAnim.value),
          child: _buildSwipeablePhoto(0, screenWidth, screenHeight),
        ),
      );
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: widget.imagePaths.length,
      onPageChanged: (index) {
        setState(() => _currentPage = index);
      },
      itemBuilder: (context, index) {
        return Center(
          child: Transform.translate(
            offset: Offset(0, _floatAnim.value),
            child: _buildSwipeablePhoto(index, screenWidth, screenHeight),
          ),
        );
      },
    );
  }

  Widget _buildSwipeablePhoto(int index, double screenWidth, double screenHeight) {
    final slideAnim = Tween<Offset>(
      begin: Offset(1.8 + index * 0.08, 0.15 - index * 0.03),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _photoControllers[index],
      curve: Curves.elasticOut,
    ));

    final scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _photoControllers[index],
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
      ),
    );

    return SlideTransition(
      position: slideAnim,
      child: ScaleTransition(
        scale: scaleAnim,
        child: GestureDetector(
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onTap: _onPhotoTap,
          child: Transform.translate(
            offset: Offset(_currentOffsetX, _currentOffsetY),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001) // 透视效果
                ..rotateZ(_currentRotation) // 绕Z轴旋转（像扔卡片）
                ..setEntry(0, 0, _currentScale)
                ..setEntry(1, 1, _currentScale),
              child: Opacity(
                opacity: _currentOpacity,
                child: Container(
                  width: screenWidth * 0.82,
                  constraints: BoxConstraints(
                    maxHeight: screenHeight * 0.50,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 40,
                        offset: const Offset(0, 20),
                      ),
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.15),
                        blurRadius: 60,
                        offset: const Offset(0, 30),
                        spreadRadius: -10,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    File(widget.imagePaths[index].split('?').first),
                    key: ValueKey(widget.imagePaths[index]),
                    gaplessPlayback: true,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_photo_alternate_outlined, size: 56, color: AppColors.hint),
                            const SizedBox(height: 12),
                            const Text('图片加载失败', style: TextStyle(color: AppColors.textSecondary, fontSize: 14, decoration: TextDecoration.none)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onDeletePhoto(int index) {
    if (widget.imagePaths.length == 1) {
      _handleClose();
    } else {
      setState(() {
        widget.imagePaths.removeAt(index);
        if (_currentPage >= widget.imagePaths.length) {
          _currentPage = widget.imagePaths.length - 1;
        }
        _dragOffsetX = 0;
        _dragOffsetY = 0;
        _isDragging = false;
        _isFlying = false;
      });
      if (widget.imagePaths.isEmpty) {
        _handleClose();
      }
    }
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        widget.imagePaths.length,
        (index) => AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: _currentPage == index ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: _currentPage == index ? AppColors.accent : AppColors.accent.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(4),
            boxShadow: _currentPage == index
                ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.4), blurRadius: 6, offset: const Offset(0, 2))]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingActions() {
    final leftSlide = Tween<Offset>(
      begin: const Offset(-1.5, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _buttonControllers[0], curve: Curves.elasticOut));

    final rightSlide = Tween<Offset>(
      begin: const Offset(1.5, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _buttonControllers[1], curve: Curves.elasticOut));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          Expanded(
            child: SlideTransition(
              position: leftSlide,
              child: _FloatingActionButton(
                icon: Icons.auto_awesome_outlined,
                label: '一键生成笔记',
                onTap: _onGenerateNote,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SlideTransition(
              position: rightSlide,
              child: _FloatingActionButton(
                icon: Icons.psychology_outlined,
                label: '笔记分析',
                onTap: _onStartAnalysis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onGenerateNote() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('功能开发中，敬请期待~'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _onStartAnalysis() {
    debugPrint('[XiaoQi] PhotoOverlay: 笔记分析功能暂未实现');
  }

  void _onPhotoTap() {
    debugPrint('[XiaoQi] PhotoOverlay: 点击照片，打开编辑器');
    // 立即隐藏小七
    RobotOverlay.hide();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoEditorPage(
          imagePath: widget.imagePaths[_currentPage].split('?').first,
          onCompleted: (editedPath) {
            debugPrint('[XiaoQi] PhotoOverlay: 编辑完成: $editedPath');
            setState(() {
              widget.imagePaths[_currentPage] = editedPath;
            });
          },
          onCancelled: () {
            debugPrint('[XiaoQi] PhotoOverlay: 编辑取消');
          },
        ),
      ),
    );
  }
}

class _FloatingActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _FloatingActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, 4)),
            BoxShadow(color: AppColors.accent.withValues(alpha: 0.1), blurRadius: 24, offset: const Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary, decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }
}