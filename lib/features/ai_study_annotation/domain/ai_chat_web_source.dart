class AiChatWebSource {
  const AiChatWebSource({
    required this.title,
    required this.url,
    this.summary = '',
    this.snippet = '',
    this.siteName = '',
    this.siteIcon = '',
    this.date,
    this.authority,
  });

  final String title;
  final String url;
  final String summary;
  final String snippet;
  final String siteName;
  final String siteIcon;
  final DateTime? date;
  final int? authority;

  factory AiChatWebSource.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, Object?>.from(raw) : const {};
    return AiChatWebSource(
      title: map['title']?.toString().trim().isNotEmpty == true
          ? map['title'].toString().trim()
          : '网页来源',
      url: map['url']?.toString() ?? '',
      summary: map['summary']?.toString() ?? '',
      snippet: map['snippet']?.toString() ?? '',
      siteName: map['site_name']?.toString() ?? '',
      siteIcon: map['site_icon']?.toString() ?? '',
      date: DateTime.tryParse(map['date']?.toString() ?? ''),
      authority: map['authority'] is num
          ? (map['authority'] as num).toInt()
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    if (summary.isNotEmpty) 'summary': summary,
    if (snippet.isNotEmpty) 'snippet': snippet,
    if (siteName.isNotEmpty) 'site_name': siteName,
    if (siteIcon.isNotEmpty) 'site_icon': siteIcon,
    if (date != null) 'date': date!.toUtc().toIso8601String(),
    if (authority != null) 'authority': authority,
  };
}
