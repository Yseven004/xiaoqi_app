import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/skill_market.dart';

void main() {
  test(
    'layout survives normalization and legacy records default to horizontal',
    () {
      expect(
        normalizeSkillPresentation({'title': '阅读'})['image_layout'],
        'horizontal',
      );
      expect(
        normalizeSkillPresentation({'image_layout': 'grid'})['image_layout'],
        'grid',
      );
      expect(
        () => normalizeSkillPresentation({'image_layout': 'other'}),
        throwsFormatException,
      );
    },
  );
}
