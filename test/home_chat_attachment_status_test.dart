import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/services/home_chat_attachment_preparer.dart';
import 'package:xiaoqi_app/widgets/home_chat_attachment_controls.dart';

const first = HomeChatAttachment(
  id: 'first',
  name: '中文资料.pdf',
  path: '/private/first.pdf',
  mimeType: 'application/pdf',
  byteLength: 2048,
  source: 'file',
);
const second = HomeChatAttachment(
  id: 'second',
  name: '另一份资料.docx',
  path: '/private/second.docx',
  mimeType:
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  byteLength: 4096,
  source: 'file',
);

void main() {
  testWidgets(
    'selection feedback appears on first frame and reports real upload progress',
    (tester) async {
      final states = ValueNotifier<Map<String, AttachmentPreparationState>>({});
      addTearDown(states.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: HomeChatAttachmentTray(
                attachments: const [first],
                onRemove: (_) {},
                preparationStates: states,
              ),
            ),
          ),
        ),
      );
      expect(find.text('正在准备'), findsOneWidget);
      states.value = {
        first.id: const AttachmentPreparationState(
          attachmentId: 'first',
          phase: 'copying',
          label: '正在准备文件',
        ),
      };
      await tester.pump();
      expect(find.text('正在准备文件'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      states.value = {
        first.id: const AttachmentPreparationState(
          attachmentId: 'first',
          phase: 'uploading',
          label: '正在上传 50%',
          progress: .5,
        ),
      };
      await tester.pump();
      expect(find.text('正在上传 50%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retry targets the failed attachment while other ready files remain available',
    (tester) async {
      final states = ValueNotifier<Map<String, AttachmentPreparationState>>({
        first.id: const AttachmentPreparationState(
          attachmentId: 'first',
          phase: 'failed',
          label: '读取失败',
          error: '连接中断，进度已保留',
          retryable: true,
        ),
        second.id: const AttachmentPreparationState(
          attachmentId: 'second',
          phase: 'ready',
          label: '已可阅读',
          ready: true,
        ),
      });
      addTearDown(states.dispose);
      String? retried;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: HomeChatAttachmentTray(
                attachments: const [first, second],
                onRemove: (_) {},
                preparationStates: states,
                onRetry: (attachment) => retried = attachment.id,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('重试'));
      expect(retried, first.id);
      expect(find.text('已可阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late preparation feedback from another conversation is not displayed',
    (tester) async {
      final states = ValueNotifier<Map<String, AttachmentPreparationState>>({
        second.id: const AttachmentPreparationState(
          attachmentId: 'second',
          phase: 'reading',
          label: '正在阅读',
        ),
      });
      addTearDown(states.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeChatMessageAttachments(
              attachments: const [second],
              preparationStates: states,
            ),
          ),
        ),
      );
      states.value = {
        ...states.value,
        first.id: const AttachmentPreparationState(
          attachmentId: 'first',
          phase: 'failed',
          label: '旧会话失败',
          error: '旧会话错误',
          retryable: true,
        ),
      };
      await tester.pump();
      expect(find.text('正在阅读'), findsOneWidget);
      expect(find.text('旧会话失败'), findsNothing);
      expect(find.text('准备失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
