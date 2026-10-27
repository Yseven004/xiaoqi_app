/// Reviewed public interfaces. Neither remote annotations nor tool names on
/// another endpoint can add an entry here. New parameters need a new review.
class TrustedMcpReadProfiles {
  static const id = 'deepwiki-public-documentation';
  static const version = '2026-10-28-repo-read-v1';
  static final endpoint = Uri.parse('https://mcp.deepwiki.com/mcp');
  static const tools = {
    'read_wiki_structure',
    'read_wiki_contents',
    'ask_wiki_question',
  };

  static bool matchesEndpoint(Uri url) => url == endpoint;

  static bool permits(
    String tool,
    Object? schema,
    Map<String, dynamic>? arguments,
  ) {
    if (!tools.contains(tool) || schema is! Map || schema['type'] != 'object')
      return false;
    if (!schema.keys.every(
      const {
        'type',
        'properties',
        'required',
        'additionalProperties',
        'description',
        'title',
        r'$schema',
      }.contains,
    ))
      return false;
    if (schema.containsKey('additionalProperties') &&
        schema['additionalProperties'] is! bool)
      return false;
    final properties = schema['properties'];
    final required = schema['required'];
    final question = tool == 'ask_wiki_question';
    final fields = question
        ? const {'repoName', 'question'}
        : const {'repoName'};
    if (properties is! Map ||
        properties.length != fields.length ||
        !properties.keys.every(fields.contains) ||
        required is! List ||
        required.length != fields.length ||
        required.toSet().length != fields.length ||
        !required.every(fields.contains))
      return false;
    if (arguments == null ||
        arguments.length != fields.length ||
        !arguments.keys.every(fields.contains))
      return false;
    if (!question)
      return _plainString(properties['repoName']) &&
          _repoName(arguments['repoName']);
    if (!_questionRepos(properties['repoName']) ||
        !_plainString(properties['question']) ||
        arguments['question'] is! String)
      return false;
    final repos = arguments['repoName'];
    return _repoName(repos) ||
        (repos is List &&
            repos.isNotEmpty &&
            repos.length <= 10 &&
            repos.every(_repoName));
  }

  static bool _plainString(Object? schema) =>
      schema is Map &&
      schema['type'] == 'string' &&
      schema.keys.every(const {'type', 'description', 'title'}.contains);

  static bool _questionRepos(Object? schema) {
    if (schema is! Map ||
        !schema.keys.every(const {'anyOf', 'description', 'title'}.contains))
      return false;
    final variants = schema['anyOf'];
    if (variants is! List || variants.length != 2) return false;
    return variants.where(_plainString).length == 1 &&
        variants
                .where(
                  (variant) =>
                      variant is Map &&
                      variant['type'] == 'array' &&
                      variant.keys.every(
                        const {
                          'type',
                          'items',
                          'description',
                          'title',
                        }.contains,
                      ) &&
                      _plainString(variant['items']),
                )
                .length ==
            1;
  }

  static bool _repoName(Object? value) {
    if (value is! String) return false;
    final name = value;
    return name.length <= 240 &&
        RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(name) &&
        !name.split('/').any((part) => part == '.' || part == '..');
  }
}
