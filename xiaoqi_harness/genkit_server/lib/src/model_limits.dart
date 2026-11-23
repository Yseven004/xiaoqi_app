/// Provider limits, or explicitly labelled application budgets where that
/// deployment's exact limits have not been verified. The provider enforces its
/// window; byte/character counts are not substituted for its tokenizer.
class ModelLimits {
  const ModelLimits(
    this.contextTokens,
    this.maxOutputTokens,
    this.source, {
    this.applicationBudget = false,
  });

  final int contextTokens;
  int get maxInputTokens => contextTokens;
  final int maxOutputTokens;
  final String source;
  final bool applicationBudget;

  static const deepSeek = ModelLimits(
    1048576,
    393216,
    'https://api-docs.deepseek.com/api/create-chat-completion/',
  );
  static const mimo = ModelLimits(
    1048576,
    131072,
    'https://mimo.mi.com/models/en-US/mimo-v2.6-flash',
  );
  static const siliconFlowBookSearchModel = 'deepseek-ai/DeepSeek-V4.1-Flash';
  // Conservative local budgets, NOT DeepSeek's first-party API ceilings.
  // SiliconFlow documents max_tokens separately from reasoning tokens.
  static const siliconFlowBookSearch = ModelLimits(
    32768,
    8192,
    'Application budget; https://docs.siliconflow.cn/docs/api/chat-completions-post',
    applicationBudget: true,
  );

  static ModelLimits forModel(String model) => switch (model) {
    'deepseek-flash' => deepSeek,
    'mimo-v2.6-flash' => mimo,
    siliconFlowBookSearchModel => siliconFlowBookSearch,
    _ => throw ArgumentError.value(model, 'model', '型号没有已核实的官方限制'),
  };
}
