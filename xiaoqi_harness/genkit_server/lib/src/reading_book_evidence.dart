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
      if (item['presentation'] == 'a2ui') 'presentation': 'a2ui',
    };
    final existing = references.indexWhere(
      (ref) =>
          ref['source_version'] == revision &&
          ref['page'] == page &&
          ref['chapter_id'] == reference['chapter_id'] &&
          ref['quote'] == excerpt,
    );
    if (existing < 0 && references.length < 8) {
      references.add(reference);
    } else if (existing >= 0 && reference['presentation'] == 'a2ui') {
      references[existing] = reference;
    }
  }
  return references;
}

final _hash = RegExp(r'^[a-f0-9]{64}$');

/// Verifies an explicit request in the current user text. Book excerpts and
/// quoted example requests cannot authorize a source display.
bool explicitlyRequestsReadingSource(String userText) {
  final text = userText
      .split(RegExp(r'^### 用户选中的原文\s*$', multiLine: true))
      .first
      .replaceAll(_quotedSourceRequest, '')
      .trim();
  return !_declinesReadingSource.hasMatch(text) &&
      (_explicitReadingSource.hasMatch(text) ||
          _shortReadingSource.hasMatch(text));
}

final _quotedSourceRequest = RegExp(
  r'```[\s\S]*?(?:```|$)|^[ \t]*>[^\r\n]*|“[^”]*”|「[^」]*」|《[^》]*》|"[^"]*"',
  multiLine: true,
);
final _declinesReadingSource = RegExp(
  r'(?:不(?:要|用|必|需(?:要)?)|别|无需)[^。！？!?；;，,\n]{0,16}(?:出处|来源|参考文献|引用|原文链接|页码)'
  r"|\b(?:don't|do not|without|omit|skip|no)\b[^.!?;,\n]{0,20}\b(?:sources?|citations?|references?|page numbers?)\b",
  caseSensitive: false,
);
final _explicitReadingSource = RegExp(
  r'(?:给(?:我|出|个|一下|下)|只要|想要|需要|想看|提供|列(?:出|一下)|附(?:上|带)|标(?:注|明)|注明|展示|出示|发给我|核(?:对|实|查)|告诉我)'
  r'[^。！？!?；;\n]{0,24}(?:出处|来源|参考文献|引文链接|引用|原文链接|页码)'
  r'|(?:出处|来源|原文(?:出处|链接))\s*(?:是(?:什么|哪里|哪儿)|在(?:哪里|哪儿|哪一页)|呢|[？?])'
  r'|(?:出自|引自)\s*哪(?:里|儿|一页|一章|段)|原文在哪(?:里|儿)|(?:在哪|见于哪)(?:一|几|个)?[页章节]|第几页(?:[？?]|$)'
  r'|\b(?:show|provide|list|give|attach|include|send|link to)\b[^.!?;\n]{0,24}\b(?:sources?|citations?|references?|page numbers?)\b'
  r'|\b(?:cite|reference) (?:it|this|that)\b|\b(?:what (?:is|are) (?:the|your) sources?|which page)\b',
  caseSensitive: false,
);
final _shortReadingSource = RegExp(
  r'^(?:(?:这句|这段|这话)的?)?(?:出处|来源|参考文献|原文出处|原文链接|引用链接)[？?。]?$'
  r'|^(?:sources?|citations?|references?)\s*[?.]?$',
  caseSensitive: false,
);

String? _bounded(Object? raw, int limit) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return String.fromCharCodes(raw.trim().runes.take(limit));
}
