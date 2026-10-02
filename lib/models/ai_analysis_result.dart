class AiAnalysisResult {
  final String whatRead;                // 📋 AI读到了
  final String goodPoints;              // ✅ 记得不错的地方
  final String missingPoints;           // ⚠️ 还可以补充
  final String understandingCorrection; // 💡 理解提醒
  final String thoughtQuestions;        // 🤔 想一想
  final String encouragingComment;      // 💬 一句话点评
  final String rawResponse;             // 原始响应（降级备用）

  const AiAnalysisResult({
    required this.whatRead,
    required this.goodPoints,
    required this.missingPoints,
    required this.understandingCorrection,
    required this.thoughtQuestions,
    required this.encouragingComment,
    required this.rawResponse,
  });

  /// 是否所有板块全空
  bool get isEmpty =>
      whatRead.trim().isEmpty &&
      goodPoints.trim().isEmpty &&
      missingPoints.trim().isEmpty &&
      understandingCorrection.trim().isEmpty &&
      thoughtQuestions.trim().isEmpty &&
      encouragingComment.trim().isEmpty;

  factory AiAnalysisResult.empty() {
    return const AiAnalysisResult(
      whatRead: '',
      goodPoints: '',
      missingPoints: '',
      understandingCorrection: '',
      thoughtQuestions: '',
      encouragingComment: '',
      rawResponse: '',
    );
  }

  @override
  String toString() {
    return 'AiAnalysisResult(whatRead: ${whatRead.length}chars, '
        'goodPoints: ${goodPoints.length}chars, '
        'missingPoints: ${missingPoints.length}chars, '
        'understanding: ${understandingCorrection.length}chars, '
        'questions: ${thoughtQuestions.length}chars, '
        'comment: ${encouragingComment.length}chars)';
  }
}
