// 表情系统数据模型
//
// 定义8种基础表情及其视觉属性、动画参数和特殊表情规则。

/// 眼睛类型
enum EyeType {
  crescent,           // E1 月牙眼
  dots,               // E2 圆点眼
  asymmetric,         // E3 不对称眼睛
  horizontalLine,     // E4 横线眼
  droopy,             // E5 下垂眼
  largeWithHighlight, // E6 放大圆眼+高光
  furrowed,           // E7 皱眉眼
  tearShine,          // E8 泪光眼
}

/// 嘴巴类型
enum MouthType {
  upturned,       // E1 上扬嘴巴
  slightUpturn,   // E2 微上扬嘴巴
  flat,           // E3 抿嘴
  circle,         // E4 圆形嘴巴
  downward,       // E5 下弯嘴巴
  bigMouth,       // E6 大嘴巴
  wavy,           // E7 波浪嘴
  smile,          // E8 微笑
}

/// 基础动画类型
enum BaseAnimationType {
  breathe,    // 呼吸（透明度）
  shake,      // 摇晃（旋转）
  sway,       // 晃动（旋转）
  float,      // 浮动（Y轴平移）
  tremble,    // 颤抖（X轴平移）
  jump,       // 跳跃（Y轴平移，弹性）
  fastShake,  // 快速摇晃（旋转）
  scale,      // 缩放
}

/// 动画参数配置
class AnimationConfig {
  final BaseAnimationType type;
  final double amplitude; // 幅度：旋转为度数，平移为px，缩放为比例
  final Duration period;  // 完整周期

  const AnimationConfig({
    required this.type,
    required this.amplitude,
    required this.period,
  });
}

/// 8种表情枚举
enum EmotionType {
  e1Happy,     // 开心
  e2Calm,      // 平静（默认）
  e3Thinking,  // 思考
  e4Sleepy,    // 困倦
  e5Sad,       // 难过
  e6Excited,   // 兴奋
  e7Angry,     // 生气
  e8Touched,   // 感动
}

/// EmotionType 扩展方法
extension EmotionTypeExtension on EmotionType {
  /// 中文名称
  String get displayName {
    switch (this) {
      case EmotionType.e1Happy:
        return '开心';
      case EmotionType.e2Calm:
        return '平静';
      case EmotionType.e3Thinking:
        return '思考';
      case EmotionType.e4Sleepy:
        return '困倦';
      case EmotionType.e5Sad:
        return '难过';
      case EmotionType.e6Excited:
        return '兴奋';
      case EmotionType.e7Angry:
        return '生气';
      case EmotionType.e8Touched:
        return '感动';
    }
  }

  /// 是否为特殊表情（E6/E7/E8）
  bool get isSpecial {
    switch (this) {
      case EmotionType.e6Excited:
      case EmotionType.e7Angry:
      case EmotionType.e8Touched:
        return true;
      default:
        return false;
    }
  }

  /// 特殊表情的持续时间（非特殊表情返回 null）
  Duration? get specialDuration {
    switch (this) {
      case EmotionType.e6Excited:
        return const Duration(seconds: 5);
      case EmotionType.e7Angry:
        return const Duration(seconds: 10);
      case EmotionType.e8Touched:
        return const Duration(seconds: 3);
      default:
        return null;
    }
  }

  /// 特殊表情的覆盖优先级（数字越大越优先）
  int get priority {
    switch (this) {
      case EmotionType.e6Excited:
        return 1;
      case EmotionType.e7Angry:
        return 2;
      case EmotionType.e8Touched:
        return 3;
      default:
        return 0;
    }
  }

  /// 眼睛类型
  EyeType get eyeType {
    switch (this) {
      case EmotionType.e1Happy:
        return EyeType.crescent;
      case EmotionType.e2Calm:
        return EyeType.dots;
      case EmotionType.e3Thinking:
        return EyeType.asymmetric;
      case EmotionType.e4Sleepy:
        return EyeType.horizontalLine;
      case EmotionType.e5Sad:
        return EyeType.droopy;
      case EmotionType.e6Excited:
        return EyeType.largeWithHighlight;
      case EmotionType.e7Angry:
        return EyeType.furrowed;
      case EmotionType.e8Touched:
        return EyeType.tearShine;
    }
  }

  /// 嘴巴类型
  MouthType get mouthType {
    switch (this) {
      case EmotionType.e1Happy:
        return MouthType.upturned;
      case EmotionType.e2Calm:
        return MouthType.upturned; // 默认就是微笑，不抿嘴
      case EmotionType.e3Thinking:
        return MouthType.flat;
      case EmotionType.e4Sleepy:
        return MouthType.circle;
      case EmotionType.e5Sad:
        return MouthType.downward;
      case EmotionType.e6Excited:
        return MouthType.bigMouth;
      case EmotionType.e7Angry:
        return MouthType.wavy;
      case EmotionType.e8Touched:
        return MouthType.smile;
    }
  }

  /// 基础动画配置
  AnimationConfig get animationConfig {
    switch (this) {
      case EmotionType.e1Happy:
        return const AnimationConfig(
          type: BaseAnimationType.shake,
          amplitude: 5.0,
          period: Duration(milliseconds: 1500),
        );
      case EmotionType.e2Calm:
        return const AnimationConfig(
          type: BaseAnimationType.breathe,
          amplitude: 0.15,
          period: Duration(milliseconds: 2000),
        );
      case EmotionType.e3Thinking:
        return const AnimationConfig(
          type: BaseAnimationType.sway,
          amplitude: 3.0,
          period: Duration(milliseconds: 2000),
        );
      case EmotionType.e4Sleepy:
        return const AnimationConfig(
          type: BaseAnimationType.float,
          amplitude: 3.0,
          period: Duration(milliseconds: 3000),
        );
      case EmotionType.e5Sad:
        return const AnimationConfig(
          type: BaseAnimationType.tremble,
          amplitude: 1.5,
          period: Duration(milliseconds: 400),
        );
      case EmotionType.e6Excited:
        return const AnimationConfig(
          type: BaseAnimationType.jump,
          amplitude: 8.0,
          period: Duration(milliseconds: 600),
        );
      case EmotionType.e7Angry:
        return const AnimationConfig(
          type: BaseAnimationType.fastShake,
          amplitude: 8.0,
          period: Duration(milliseconds: 800),
        );
      case EmotionType.e8Touched:
        return const AnimationConfig(
          type: BaseAnimationType.scale,
          amplitude: 0.08,
          period: Duration(milliseconds: 1500),
        );
    }
  }

  /// 根据情绪值映射到常规表情（非特殊表情）
  /// 90-100: E6/E1（20%概率E6，80%概率E1）
  /// 80-89: E1
  /// 60-79: E2
  /// 40-59: E3
  /// 20-39: E4
  /// 0-19: E5
  static EmotionType fromMoodScore(int moodScore) {
    final clamped = moodScore.clamp(0, 100);
    if (clamped >= 90) return EmotionType.e1Happy;
    if (clamped >= 80) return EmotionType.e1Happy;
    if (clamped >= 60) return EmotionType.e2Calm;
    if (clamped >= 40) return EmotionType.e3Thinking;
    if (clamped >= 20) return EmotionType.e4Sleepy;
    return EmotionType.e5Sad;
  }

  /// 表情 → 代表性情绪值（fromMoodScore 的逆向映射，取区间中点）
  int get representativeScore {
    switch (this) {
      case EmotionType.e1Happy:
        return 85;
      case EmotionType.e2Calm:
        return 70;
      case EmotionType.e3Thinking:
        return 50;
      case EmotionType.e4Sleepy:
        return 30;
      case EmotionType.e5Sad:
        return 15;
      case EmotionType.e6Excited:
        return 95;
      case EmotionType.e7Angry:
        return 10;
      case EmotionType.e8Touched:
        return 90;
    }
  }
}
