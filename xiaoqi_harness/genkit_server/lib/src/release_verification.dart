/// Operator-selected live checks; a deferred check is never recorded as passed.
enum ReleaseVerificationProfile {
  full,
  nonImage;

  static ReleaseVerificationProfile fromArguments(List<String> arguments) {
    if (arguments.isEmpty) return full;
    if (arguments.length == 1 && arguments.single == '--non-image')
      return nonImage;
    throw const FormatException('Expected no arguments or --non-image');
  }

  String get label => this == full ? 'full' : 'non-image';
  bool get requiresImageProvider => this == full;

  List<String> get capabilityScenarios => [
    if (this == full) ...['implicit-skill', 'explicit-plugin'],
    'unrelated',
    'ordinary-answer',
    'text-only-skill',
  ];

  List<String> get curatedPackages => [
    if (this == full) 'study-notes-studio',
    'book-to-skill',
  ];

  Map<String, Object> report({required bool curated}) {
    final all = curated ? full.curatedPackages : full.capabilityScenarios;
    final selected = curated ? curatedPackages : capabilityScenarios;
    return {
      'verification_profile': label,
      'suite': curated ? 'official_catalog' : 'capability_chain',
      'deferred_checks': [
        for (final check in all.where((check) => !selected.contains(check)))
          {
            'check': check,
            'status': 'deferred_by_user',
            'verified': false,
            'reason': 'image_service_deferred_by_user',
          },
      ],
    };
  }
}
