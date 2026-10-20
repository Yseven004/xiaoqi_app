/// First-party API limits verified 2026-10-20. Token counts include reasoning
/// where the provider specifies it. The provider enforces the combined window;
/// byte counts and character counts are not substituted for its tokenizer.
class ModelLimits {
  const ModelLimits(this.contextTokens, this.maxOutputTokens, this.source);

  final int contextTokens;
  int get maxInputTokens => contextTokens;
  final int maxOutputTokens;
  final String source;

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

  static ModelLimits forModel(String model) => switch (model) {
    'deepseek-flash' => deepSeek,
    'mimo-v2.6-flash' => mimo,
    _ => throw ArgumentError.value(model, 'model', '型号没有已核实的官方限制'),
  };
}
