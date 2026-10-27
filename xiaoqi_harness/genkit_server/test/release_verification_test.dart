import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/release_verification.dart';

void main() {
  test(
    'default verification still requires every image and non-image check',
    () {
      final profile = ReleaseVerificationProfile.fromArguments([]);
      expect(profile, ReleaseVerificationProfile.full);
      expect(profile.requiresImageProvider, true);
      expect(profile.capabilityScenarios, hasLength(5));
      expect(profile.curatedPackages, ['study-notes-studio', 'book-to-skill']);
      expect(profile.report(curated: false)['deferred_checks'], isEmpty);
    },
  );

  test(
    'non-image profile preserves other checks and explicitly defers image checks',
    () {
      final profile = ReleaseVerificationProfile.fromArguments(['--non-image']);
      expect(profile.requiresImageProvider, false);
      expect(profile.capabilityScenarios, [
        'unrelated',
        'ordinary-answer',
        'text-only-skill',
      ]);
      expect(profile.curatedPackages, ['book-to-skill']);
      final deferred = [
        ...(profile.report(curated: false)['deferred_checks'] as List),
        ...(profile.report(curated: true)['deferred_checks'] as List),
      ].cast<Map>();
      expect(deferred.map((check) => check['check']), [
        'implicit-skill',
        'explicit-plugin',
        'study-notes-studio',
      ]);
      expect(
        deferred.every(
          (check) =>
              check['verified'] == false &&
              check['status'] == 'deferred_by_user',
        ),
        true,
      );
    },
  );

  test(
    'unknown or repeated profile arguments fail before executing checks',
    () {
      for (final arguments in [
        ['--skip-all'],
        ['--non-image', '--non-image'],
        ['--non-image=false'],
      ]) {
        expect(
          () => ReleaseVerificationProfile.fromArguments(arguments),
          throwsFormatException,
        );
      }
    },
  );
}
