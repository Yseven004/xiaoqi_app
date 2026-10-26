import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/market_skill_editor.dart';

CapabilityDraft _plugin({bool withMcp = false}) => CapabilityDraft(
  id: 'mcp-entry-test',
  kind: CapabilityKind.plugin,
  name: 'reader',
  description: '读取资料',
  content: '{"name":"reader"}',
  files: withMcp
      ? {
          '.mcp.json': base64Encode(
            utf8.encode(
              '{"mcpServers":{"reading":{"url":"https://mcp.example.com"}}}',
            ),
          ),
        }
      : const {},
  updatedAt: DateTime.utc(2026, 10, 24),
);

void main() {
  testWidgets(
    'MCP service entry is only inserted after a declaration is detected',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: MarketSkillEditor(draft: _plugin())),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接 MCP 服务'), findsOneWidget);
      expect(find.text('已识别 MCP 服务'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: MarketSkillEditor(
            key: const ValueKey('with-mcp'),
            draft: _plugin(withMcp: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接 MCP 服务'), findsOneWidget);
      expect(find.text('已识别 MCP 服务'), findsOneWidget);
    },
  );
}
