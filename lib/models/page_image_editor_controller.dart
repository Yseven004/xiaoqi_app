import 'package:flutter/foundation.dart';

/// Selection state for page images, kept separate from drawing-tool state.
class PageImageEditorController extends ChangeNotifier {
  String? _selectedImageId;
  bool _editing = false;

  String? get selectedImageId => _selectedImageId;
  bool get isEditing => _editing;

  void selectForEditing(String id) {
    _selectedImageId = id;
    _editing = true;
    notifyListeners();
  }

  void lockSelection() {
    if (_selectedImageId == null || !_editing) return;
    _editing = false;
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedImageId == null && !_editing) return;
    _selectedImageId = null;
    _editing = false;
    notifyListeners();
  }

  void clearIfMissing(Iterable<String> ids) {
    if (_selectedImageId != null && !ids.contains(_selectedImageId)) {
      clearSelection();
    }
  }
}
