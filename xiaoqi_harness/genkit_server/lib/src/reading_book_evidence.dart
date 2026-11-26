/// Public reading locators come from the book index, which has already
/// resolved the current account's authorized source. Model text and tool
/// arguments cannot add items to this list.
List<Map<String, Object?>> readingBookEvidence(
  Map<String, dynamic> result, {
  Iterable<Map<String, Object?>> previous = const [],
}) {
  final references = <Map<String, Object?>>[...previous];
  final candidates = <Object?>[
    if ((result['matches'] ?? result['segments']) case final List matched)
      ...matched,
    if (result['nearby_context'] case final List neighbors) ...neighbors,
  ];
  for (final item in candidates.whereType<Map>()) {
    if (references.length >= 8) break;
    final revision = item['source_version'];
    if (revision is! String || !_hash.hasMatch(revision)) continue;
    final originalPage = item['page'];
    final page = originalPage is int && originalPage > 0 ? originalPage : null;
    final chapter = _bounded(item['chapter_id'], 512);
    if (page == null && chapter == null) continue;
    final excerpt = _bounded(item['quote'], 240);
    final href = _bounded(item['href'], 1024);
    final label = _bounded(item['locator'], 160);
    final reference = {
      'source_version': revision,
      if (page != null) 'page': page,
      if (page == null && chapter != null) 'chapter_id': chapter,
      if (page == null && href != null) 'href': href,
      if (excerpt != null) 'quote': excerpt,
      if (label != null) 'locator': label,
    };
    if (!references.any(
      (ref) =>
          ref['source_version'] == revision &&
          ref['page'] == page &&
          ref['chapter_id'] == reference['chapter_id'] &&
          ref['quote'] == excerpt,
    )) {
      references.add(reference);
    }
  }
  return references;
}

final _hash = RegExp(r'^[a-f0-9]{64}$');

String? _bounded(Object? raw, int limit) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return String.fromCharCodes(raw.trim().runes.take(limit));
}
