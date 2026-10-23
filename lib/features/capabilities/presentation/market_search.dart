/// Search metadata stays separate from the skill body and private file contents.
List<String> marketSearchTerms(Object? value) {
  final values = value is String
      ? value.split(RegExp(r'[,，、;；\n]'))
      : value is Iterable
      ? value.whereType<String>()
      : const <String>[];
  final seen = <String>{};
  return [
    for (final term in values.map((value) => value.trim()))
      if (term.isNotEmpty && seen.add(normalizeMarketSearch(term))) term,
  ];
}

String normalizeMarketSearch(String value) => String.fromCharCodes(
  value.runes.map(
    (rune) => rune >= 0xFF01 && rune <= 0xFF5E
        ? rune - 0xFEE0
        : rune == 0x3000
        ? 0x20
        : rune,
  ),
).toLowerCase().replaceAll(RegExp(r'[\s_\-，,、;；]+'), ' ').trim();

class MarketSearchDocument {
  const MarketSearchDocument({
    required this.name,
    required this.description,
    required this.author,
    this.aliases = const [],
    this.keywords = const [],
    this.capabilities = const [],
  });

  final String name, description, author;
  final List<String> aliases, keywords, capabilities;

  /// All space-separated terms must match. No inferred synonyms or body search.
  int? score(String query) {
    final normalized = normalizeMarketSearch(query);
    if (normalized.isEmpty) return query.trim().isEmpty ? 0 : null;
    final fields = [
      (normalizeMarketSearch(name), 1000),
      for (final alias in aliases) (normalizeMarketSearch(alias), 900),
      for (final keyword in keywords) (normalizeMarketSearch(keyword), 600),
      for (final capability in capabilities)
        (normalizeMarketSearch(capability), 550),
      (normalizeMarketSearch(description), 200),
      (normalizeMarketSearch(author), 100),
    ];
    var total = 0;
    for (final term in normalized.split(' ').toSet()) {
      final field = fields
          .where((field) => field.$1.contains(term))
          .firstOrNull;
      if (field == null) return null;
      total += field.$2;
    }
    if (fields.first.$1 == normalized) {
      total += 500;
    } else if (aliases.any(
      (alias) => normalizeMarketSearch(alias) == normalized,
    )) {
      total += 400;
    }
    return total;
  }
}
