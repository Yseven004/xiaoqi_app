import 'dart:async';

import 'package:flutter/material.dart';

import '../../../config/note_page_theme.dart';
import '../data/livekit_realtime_voice_session.dart';
import '../domain/realtime_voice_session.dart';
import '../domain/voice_context_snapshot.dart';

Future<void> showRealtimeVoiceSessionSheet({
  required BuildContext context,
  required VoiceContextSnapshot initialContext,
  RealtimeVoiceSession? session,
}) async {
  final activeSession = session ?? LiveKitRealtimeVoiceSession();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => RealtimeVoiceSheet(
      session: activeSession,
      initialContext: initialContext,
    ),
  );
  await activeSession.end();
  activeSession.dispose();
}

class RealtimeVoiceSheet extends StatefulWidget {
  const RealtimeVoiceSheet({
    super.key,
    required this.session,
    required this.initialContext,
  });

  final RealtimeVoiceSession session;
  final VoiceContextSnapshot initialContext;

  @override
  State<RealtimeVoiceSheet> createState() => _RealtimeVoiceSheetState();
}

class _RealtimeVoiceSheetState extends State<RealtimeVoiceSheet> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.session.start(context: widget.initialContext));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final state = session.state;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: const Color(0xFFF8F9FB),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0x22000000),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '实时语音共读',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: NotePageTheme.ink,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '结束语音',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  _StatusBanner(
                    state: state,
                    errorMessage: session.errorMessage,
                    budgetWarning: session.usage.budgetWarning,
                  ),
                  const SizedBox(height: 12),
                  _ContextCard(snapshot: session.context ?? widget.initialContext),
                  const SizedBox(height: 12),
                  _TranscriptList(transcripts: session.transcripts),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: state == RealtimeVoiceState.disconnected ||
                                  state == RealtimeVoiceState.error
                              ? null
                              : () => _toggleMute(session),
                          icon: Icon(
                            session.isMuted ? Icons.mic_off : Icons.mic,
                          ),
                          label: Text(session.isMuted ? '打开麦克风' : '静音'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: state == RealtimeVoiceState.speaking
                              ? () => unawaited(session.interrupt())
                              : state == RealtimeVoiceState.error
                              ? () => unawaited(
                                    session.start(
                                      context: session.context ?? widget.initialContext,
                                    ),
                                  )
                              : () => Navigator.of(context).pop(),
                          icon: Icon(
                            state == RealtimeVoiceState.speaking
                                ? Icons.stop_circle_outlined
                                : state == RealtimeVoiceState.error
                                ? Icons.refresh
                                : Icons.call_end,
                          ),
                          label: Text(
                            state == RealtimeVoiceState.speaking
                                ? '打断回答'
                                : state == RealtimeVoiceState.error
                                ? '重试连接'
                                : '结束对话',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: state == RealtimeVoiceState.speaking
                                ? NotePageTheme.ochre
                                : NotePageTheme.ink,
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本次仅发送当前页和选区；会话结束后不保存录音或长期转录。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: NotePageTheme.inkSecondary.withValues(alpha: .8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleMute(RealtimeVoiceSession session) async {
    if (session.isMuted) {
      await session.unmute();
    } else {
      await session.mute();
    }
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.state,
    required this.errorMessage,
    required this.budgetWarning,
  });

  final RealtimeVoiceState state;
  final String? errorMessage;
  final bool budgetWarning;

  @override
  Widget build(BuildContext context) {
    final (stateLabel, stateColor) = switch (state) {
      RealtimeVoiceState.connecting => ('正在连接实时语音…', const Color(0xFFB06B00)),
      RealtimeVoiceState.listening => ('正在聆听，你可以直接说话', const Color(0xFF287A55)),
      RealtimeVoiceState.thinking => ('小七正在整理当前页…', const Color(0xFF4F67A8)),
      RealtimeVoiceState.speaking => ('小七正在讲解，可随时打断', NotePageTheme.ochre),
      RealtimeVoiceState.reconnecting => ('网络波动，正在重连…', const Color(0xFFB06B00)),
      RealtimeVoiceState.ending => ('正在结束本次会话…', NotePageTheme.inkSecondary),
      RealtimeVoiceState.error => (errorMessage ?? '连接失败，请重试', const Color(0xFFB44848)),
      RealtimeVoiceState.disconnected => ('尚未连接', NotePageTheme.inkSecondary),
    };
    final label = budgetWarning && state != RealtimeVoiceState.error
        ? '本次会话将在约 1 分钟后结束，请先结束并重新开始'
        : stateLabel;
    final color = budgetWarning && state != RealtimeVoiceState.error
        ? const Color(0xFFB06B00)
        : stateColor;
    return Semantics(
      liveRegion: true,
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Expanded(child: Text(label, style: TextStyle(color: color, fontSize: 13))),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.snapshot});

  final VoiceContextSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final anchor = snapshot.pageAnchor.isEmpty ? '当前页' : snapshot.pageAnchor;
    final selection = snapshot.selectedText.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('讨论范围 · $anchor', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
              selection.isEmpty ? '当前页正文（版本 ${snapshot.version}）' : '已选文字：$selection',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: NotePageTheme.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList({required this.transcripts});

  final List<VoiceTranscript> transcripts;

  @override
  Widget build(BuildContext context) {
    if (transcripts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Text(
          '连接后，双方的临时转录会显示在这里。',
          textAlign: TextAlign.center,
          style: TextStyle(color: NotePageTheme.inkSecondary, fontSize: 12),
        ),
      );
    }
    final visible = transcripts.length <= 4
        ? transcripts
        : transcripts.sublist(transcripts.length - 4);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final item = visible[index];
          final isUser = item.speaker == VoiceSpeaker.user;
          return Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFFEDE7DC) : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(item.text, style: const TextStyle(fontSize: 13, height: 1.35)),
            ),
          );
        },
      ),
    );
  }
}
