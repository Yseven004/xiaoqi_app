List<String> parseCapabilityKeywords(Object? raw) {
  if (raw is! List || raw.length > 32) {
    throw const FormatException('能力关键词最多32个，使用文字列表');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final value in raw) {
    if (value is! String || value.length > 80) {
      throw const FormatException('每个能力关键词须为最多80字符的文字');
    }
    final term = value.trim();
    if (term.isNotEmpty && seen.add(term.toLowerCase())) result.add(term);
  }
  return result;
}
