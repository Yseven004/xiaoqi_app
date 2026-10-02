import 'package:shared_preferences/shared_preferences.dart';

class CameraCapturePreferences {
  CameraCapturePreferences._();

  static const _levelPreferenceKey = 'viewfinder_level_enabled';
  static const _doublePageGuideSeenKey = 'double_page_guide_seen';
  static const _skipBatchReviewKey = 'book_capture_skip_batch_review';

  static Future<bool> loadLevelEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_levelPreferenceKey) ?? false;
  }

  static Future<void> saveLevelEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_levelPreferenceKey, enabled);
  }

  static Future<bool> loadDoublePageGuideSeen() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_doublePageGuideSeenKey) ?? false;
  }

  static Future<void> markDoublePageGuideSeen() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_doublePageGuideSeenKey, true);
  }

  static Future<bool> loadSkipBatchReview() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_skipBatchReviewKey) ?? false;
  }

  static Future<void> saveSkipBatchReview(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_skipBatchReviewKey, enabled);
  }
}
