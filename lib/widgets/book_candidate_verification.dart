import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_recognition.dart';

/// Presents book-matching confidence as a plain-language reason and next step.
///
/// Numeric recognition scores intentionally stay out of the UI: they are
/// useful for ranking candidates, but they are not a probability that the
/// edition is correct.
class BookCandidateVerification extends StatelessWidget {
  const BookCandidateVerification({
    super.key,
    required this.candidate,
    this.showGuidance = true,
  });

  final BookCandidate candidate;
  final bool showGuidance;

  @override
  Widget build(BuildContext context) {
    final needsReview = candidate.requiresManualReview;
    final foreground = needsReview
        ? BookFlowTheme.inkSecondary
        : BookFlowTheme.primary;
    final background = needsReview
        ? BookFlowTheme.warningSoft
        : BookFlowTheme.primarySoft;

    return Semantics(
      container: true,
      label: showGuidance
          ? '匹配依据：${candidate.verificationLabel}。${candidate.verificationGuidance}'
          : '匹配依据：${candidate.verificationLabel}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                child: Text(
                  candidate.verificationLabel,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            if (showGuidance) ...[
              const SizedBox(height: 5),
              Text(
                candidate.verificationGuidance,
                style: BookFlowTheme.caption,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
