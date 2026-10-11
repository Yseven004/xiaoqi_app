import 'dart:convert';
import 'dart:io';

/// Monitors image generation failures and emits structured logs for alerting.
/// Tracks failure rate by error type and triggers warnings when thresholds exceed.
class ImageGenerationMonitor {
  ImageGenerationMonitor({
    this.copyrightFailureThreshold = 0.05, // 5%
    this.emptyPromptThreshold = 0.10, // 10%
    this.overallFailureThreshold = 0.15, // 15%
    this.windowSize = 100, // last 100 requests
  });

  final double copyrightFailureThreshold;
  final double emptyPromptThreshold;
  final double overallFailureThreshold;
  final int windowSize;

  final _recentRequests = <ImageGenerationEvent>[];
  var _totalRequests = 0;
  var _totalFailures = 0;

  /// Record an image generation attempt.
  void recordAttempt({
    required String taskId,
    required String prompt,
    required ImageGenerationResult result,
    String? errorType,
    String? errorMessage,
  }) {
    _totalRequests++;

    final event = ImageGenerationEvent(
      taskId: taskId,
      prompt: prompt,
      result: result,
      errorType: errorType,
      errorMessage: errorMessage,
      timestamp: DateTime.now(),
    );

    _recentRequests.add(event);
    if (_recentRequests.length > windowSize) {
      _recentRequests.removeAt(0);
    }

    if (result == ImageGenerationResult.failed) {
      _totalFailures++;
    }

    _checkThresholds(event);
    _emitMetrics(event);
  }

  void _checkThresholds(ImageGenerationEvent event) {
    if (_recentRequests.length < 20) return; // Wait for enough samples

    final failures = _recentRequests.where((e) => e.result == ImageGenerationResult.failed);
    final copyrightFailures = failures.where((e) => e.errorType == 'copyright_restriction');
    final emptyPromptFailures = failures.where((e) => e.errorType == 'empty_prompt');

    final overallRate = failures.length / _recentRequests.length;
    final copyrightRate = copyrightFailures.length / _recentRequests.length;
    final emptyPromptRate = emptyPromptFailures.length / _recentRequests.length;

    // Alert on copyright restriction rate
    if (copyrightRate > copyrightFailureThreshold) {
      _emitAlert(
        level: 'warning',
        type: 'high_copyright_failure_rate',
        message: '版权审查失败率过高',
        details: {
          'rate': copyrightRate,
          'threshold': copyrightFailureThreshold,
          'window_size': _recentRequests.length,
          'failure_count': copyrightFailures.length,
        },
      );
    }

    // Alert on empty prompt rate
    if (emptyPromptRate > emptyPromptThreshold) {
      _emitAlert(
        level: 'info',
        type: 'high_empty_prompt_rate',
        message: '空提示词保护触发率过高，可能需要改进 UX 引导',
        details: {
          'rate': emptyPromptRate,
          'threshold': emptyPromptThreshold,
          'window_size': _recentRequests.length,
          'failure_count': emptyPromptFailures.length,
        },
      );
    }

    // Alert on overall failure rate
    if (overallRate > overallFailureThreshold) {
      _emitAlert(
        level: 'critical',
        type: 'high_overall_failure_rate',
        message: '图片生成整体失败率过高',
        details: {
          'rate': overallRate,
          'threshold': overallFailureThreshold,
          'window_size': _recentRequests.length,
          'failure_count': failures.length,
          'breakdown': {
            'copyright': copyrightFailures.length,
            'empty_prompt': emptyPromptFailures.length,
            'timeout': failures.where((e) => e.errorType == 'timeout').length,
            'api_error': failures.where((e) => e.errorType == 'api_error').length,
            'other': failures.where((e) =>
              e.errorType != 'copyright_restriction' &&
              e.errorType != 'empty_prompt' &&
              e.errorType != 'timeout' &&
              e.errorType != 'api_error'
            ).length,
          },
        },
      );
    }
  }

  void _emitMetrics(ImageGenerationEvent event) {
    try {
      stderr.writeln(
        jsonEncode({
          'component': 'image_generation_monitor',
          'event': 'attempt',
          'task_id': event.taskId,
          'result': event.result.name,
          'error_type': event.errorType,
          'prompt_length': event.prompt.length,
          'timestamp': event.timestamp.toUtc().toIso8601String(),
          'metrics': {
            'total_requests': _totalRequests,
            'total_failures': _totalFailures,
            'recent_window_size': _recentRequests.length,
            'recent_failure_rate': _recentRequests.isEmpty
                ? 0.0
                : _recentRequests.where((e) => e.result == ImageGenerationResult.failed).length /
                    _recentRequests.length,
          },
        }),
      );
    } on Object {
      // Logging must not break the request
    }
  }

  void _emitAlert({
    required String level,
    required String type,
    required String message,
    required Map<String, Object?> details,
  }) {
    try {
      stderr.writeln(
        jsonEncode({
          'component': 'image_generation_monitor',
          'event': 'alert',
          'level': level,
          'alert_type': type,
          'message': message,
          'details': details,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } on Object {
      // Logging must not break the request
    }
  }

  /// Get current statistics for debugging.
  Map<String, dynamic> getStats() {
    final failures = _recentRequests.where((e) => e.result == ImageGenerationResult.failed);
    final byErrorType = <String, int>{};

    for (final failure in failures) {
      final type = failure.errorType ?? 'unknown';
      byErrorType[type] = (byErrorType[type] ?? 0) + 1;
    }

    return {
      'total_requests': _totalRequests,
      'total_failures': _totalFailures,
      'overall_failure_rate': _totalRequests == 0 ? 0.0 : _totalFailures / _totalRequests,
      'recent_window': {
        'size': _recentRequests.length,
        'failures': failures.length,
        'failure_rate': _recentRequests.isEmpty ? 0.0 : failures.length / _recentRequests.length,
        'by_error_type': byErrorType,
      },
    };
  }
}

/// Result of an image generation attempt.
enum ImageGenerationResult {
  success,
  failed,
  skipped, // empty prompt protection
}

/// Image generation event for tracking.
class ImageGenerationEvent {
  const ImageGenerationEvent({
    required this.taskId,
    required this.prompt,
    required this.result,
    this.errorType,
    this.errorMessage,
    required this.timestamp,
  });

  final String taskId;
  final String prompt;
  final ImageGenerationResult result;
  final String? errorType;
  final String? errorMessage;
  final DateTime timestamp;
}

/// Common error type constants.
class ImageGenerationErrorType {
  static const copyrightRestriction = 'copyright_restriction';
  static const emptyPrompt = 'empty_prompt';
  static const timeout = 'timeout';
  static const apiError = 'api_error';
  static const networkError = 'network_error';
  static const promptTooLong = 'prompt_too_long';
  static const configurationError = 'configuration_error';
}
