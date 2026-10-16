import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/capability_tag_text_controller.dart';

void main() {
  test('old local capability records retain their enabled default', () {
    final record = CapabilityRecord.fromJson({
      'id': 'existing',
      'kind': 'skill',
      'name': '已有技能',
      'description': '保留',
      'current_version_id': 'v1',
      'versions': [
        {
          'id': 'v1',
          'content': 'original',
          'files': {'references/note.md': 'saved'},
        },
      ],
    });
    final restored = CapabilityRecord.fromJson(
      record.copyWith(showInMenu: false).toJson(),
    );
    expect(restored.origin, 'local');
    expect(restored.enabled, isTrue);
    expect(restored.currentVersion!.content, 'original');
    expect(restored.currentVersion!.files['references/note.md'], 'saved');
  });

  test(
    'server installation provenance and component checks survive cache updates',
    () {
      final record = CapabilityRecord.fromJson({
        'id': 'imported',
        'kind': 'plugin',
        'origin': 'github',
        'enabled': false,
        'source': {'commit': 'fixed-sha'},
        'compatibility': {
          'status': 'partial',
          'warnings': ['MCP 暂不支持'],
        },
        'cloud_revision': 7,
      });
      final restored = CapabilityRecord.fromJson(
        record.copyWith(showInMenu: false).toJson(),
      );
      expect(restored.origin, 'github');
      expect(restored.enabled, isFalse);
      expect(restored.source, record.source);
      expect(restored.compatibility, record.compatibility);
      expect(restored.cloudRevision, 7);
    },
  );

  Map<String, Object?> selection(String id, {String type = 'skill'}) => {
    'id': id,
    'type': type,
    'name': id,
    'version_id': 'version-$id',
  };

  test('skill and plugin selections retain their pinned versions', () {
    final controller = CapabilityTagTextController()..text = '请处理材料';
    addTearDown(controller.dispose);
    controller.insertCapability(selection('reader'));
    controller.insertCapability(selection('writer', type: 'plugin'));
    final metadata = controller.messageMetadata()!;
    expect(metadata['selected_capabilities'], [
      selection('reader'),
      selection('writer', type: 'plugin'),
    ]);
    expect(controller.messageText, '请处理材料');
    final restored = CapabilityTagTextController();
    addTearDown(restored.dispose);
    restored.setMessage(controller.messageText, metadata);
    expect(restored.messageMetadata(), metadata);
    restored.clearCapabilities();
    expect(restored.messageMetadata(), isNull);
    expect(restored.messageText, '请处理材料');
  });

  test('reselection updates a version without duplicating it', () {
    final controller = CapabilityTagTextController();
    addTearDown(controller.dispose);
    controller.insertCapability(selection('reader'));
    controller.insertCapability(selection('writer', type: 'plugin'));
    controller.insertCapability({...selection('reader'), 'version_id': 'new'});
    final selections =
        controller.messageMetadata()!['selected_capabilities'] as List;
    expect(selections, hasLength(2));
    expect(selections.last['version_id'], 'new');
    controller.insertCapability({'type': 'action', 'id': 'create-image'});
    expect(controller.messageMetadata()!['selected_capabilities'], isNull);
  });

  test('selection cap matches server limit and snapshot retains selection', () {
    final controller = CapabilityTagTextController();
    addTearDown(controller.dispose);
    for (var i = 0; i < 17; i++) {
      controller.insertCapability(selection('skill-$i'));
    }
    expect(
      controller.messageMetadata()!['selected_capabilities'],
      hasLength(16),
    );
    final snapshot = controller.snapshot();
    controller.clearCapabilities();
    controller.restore(snapshot);
    expect(
      controller.messageMetadata()!['selected_capabilities'],
      hasLength(16),
    );
  });
}
