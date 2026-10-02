import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HomeChatReasoningLevel { low, medium, high }

extension HomeChatReasoningLevelLabel on HomeChatReasoningLevel {
  String get label => switch (this) {
    HomeChatReasoningLevel.low => '低',
    HomeChatReasoningLevel.medium => '中',
    HomeChatReasoningLevel.high => '高',
  };

  static HomeChatReasoningLevel? parse(String? value) => switch (value) {
    'low' => HomeChatReasoningLevel.low,
    'medium' => HomeChatReasoningLevel.medium,
    'high' => HomeChatReasoningLevel.high,
    _ => null,
  };
}

class HomeChatModelOption {
  const HomeChatModelOption({
    required this.id,
    required this.name,
    required this.provider,
    required this.iconAsset,
    required this.defaultReasoningLevel,
    this.supportsMedium = true,
  });

  final String id;
  final String name;
  final String provider;
  final String iconAsset;
  final HomeChatReasoningLevel defaultReasoningLevel;
  final bool supportsMedium;

  bool supports(HomeChatReasoningLevel level) =>
      supportsMedium || level != HomeChatReasoningLevel.medium;

  HomeChatReasoningLevel normalize(HomeChatReasoningLevel level) =>
      supports(level) ? level : defaultReasoningLevel;

  static const deepSeek = HomeChatModelOption(
    id: 'deepseek-flash',
    name: 'DeepSeek-V4.1-Flash',
    provider: 'DeepSeek',
    iconAsset: 'assets/images/model_provider_deepseek.svg',
    defaultReasoningLevel: HomeChatReasoningLevel.medium,
  );

  static const mimo = HomeChatModelOption(
    id: 'mimo-v2.6-flash',
    name: 'MiMo-V2.6-Flash',
    provider: 'Xiaomi',
    iconAsset: 'assets/images/model_provider_xiaomi.svg',
    defaultReasoningLevel: HomeChatReasoningLevel.high,
    supportsMedium: false,
  );

  static const options = <HomeChatModelOption>[deepSeek, mimo];

  static HomeChatModelOption fromId(String? id) => options.firstWhere(
    (option) => option.id == id,
    orElse: () => deepSeek,
  );
}

class HomeChatModelSelection {
  const HomeChatModelSelection({
    required this.model,
    required this.reasoningLevel,
  });

  static const initial = HomeChatModelSelection(
    model: HomeChatModelOption.deepSeek,
    reasoningLevel: HomeChatReasoningLevel.medium,
  );

  final HomeChatModelOption model;
  final HomeChatReasoningLevel reasoningLevel;

  HomeChatModelSelection withModel(HomeChatModelOption next) =>
      HomeChatModelSelection(
        model: next,
        reasoningLevel: next.normalize(reasoningLevel),
      );

  HomeChatModelSelection withReasoning(HomeChatReasoningLevel next) =>
      HomeChatModelSelection(
        model: model,
        reasoningLevel: model.normalize(next),
      );
}

class HomeChatModelPreferences {
  HomeChatModelPreferences._();

  static final instance = HomeChatModelPreferences._();
  static const _modelKey = 'home_chat.default_model.v1';
  static const _reasoningKey = 'home_chat.default_reasoning.v1';

  final ValueNotifier<HomeChatModelSelection> defaultSelection =
      ValueNotifier(HomeChatModelSelection.initial);
  Future<void>? _loading;
  bool _loaded = false;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    final model = HomeChatModelOption.fromId(
      preferences.getString(_modelKey),
    );
    final level = HomeChatReasoningLevelLabel.parse(
      preferences.getString(_reasoningKey),
    );
    defaultSelection.value = HomeChatModelSelection(
      model: model,
      reasoningLevel: model.normalize(level ?? model.defaultReasoningLevel),
    );
    _loaded = true;
  }

  Future<void> saveDefault(HomeChatModelSelection selection) async {
    await load();
    final normalized = selection.withReasoning(selection.reasoningLevel);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_modelKey, normalized.model.id);
    await preferences.setString(
      _reasoningKey,
      normalized.reasoningLevel.name,
    );
    defaultSelection.value = normalized;
  }
}
