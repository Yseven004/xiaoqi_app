import 'package:flutter/foundation.dart';

enum DrawingTool {
  browse,
  ballpoint,
  pencil,
  highlighter,
  laser,
  eraser,
  lasso,
  text,
}

enum EraserMode { free, stroke }

enum LassoMode { free, rectangle, all }

/// Pure interaction state for the drawing toolbar. Keeping it outside the
/// page widget makes mode transitions deterministic and cheap to test.
class PageAnnotationToolController extends ChangeNotifier {
  DrawingTool _activeTool = DrawingTool.browse;
  DrawingTool _lastEditingTool = DrawingTool.ballpoint;
  EraserMode _eraserMode = EraserMode.free;
  LassoMode _lassoMode = LassoMode.free;
  final Map<DrawingTool, int> _penColors = {
    DrawingTool.ballpoint: 0xFF1A1A1A,
    DrawingTool.pencil: 0xFF1A1A1A,
    DrawingTool.highlighter: 0xFFF6C945,
    DrawingTool.laser: 0xFFC54237,
  };
  final Map<DrawingTool, double> _penWidths = {
    DrawingTool.ballpoint: 3.5,
    DrawingTool.pencil: 3.5,
    DrawingTool.highlighter: 16,
    // Laser width is a fixed visual parameter. Color can change, width cannot.
    DrawingTool.laser: 2,
  };
  double _eraserRadius = 22;
  bool _isToolOptionsOpen = false;
  bool _isTransformMode = false;
  bool _isAnnotationDragging = false;
  int _textActivationVersion = 0;
  Set<String> _selectedAnnotationIds = <String>{};

  DrawingTool get activeTool => _activeTool;
  DrawingTool get lastEditingTool => _lastEditingTool;
  EraserMode get eraserMode => _eraserMode;
  LassoMode get lassoMode => _lassoMode;
  bool get isBrowseMode => _activeTool == DrawingTool.browse;
  bool get handIsSlashed => !isBrowseMode;
  bool get isToolOptionsOpen => _isToolOptionsOpen;
  bool get isTransformMode => _isTransformMode;
  bool get isAnnotationActionBarVisible =>
      _selectedAnnotationIds.isNotEmpty && !_isAnnotationDragging;
  int get textActivationVersion => _textActivationVersion;
  int colorFor(DrawingTool tool) => _penColors[tool] ?? 0xFF1A1A1A;
  double widthFor(DrawingTool tool) => _penWidths[tool] ?? 2.2;
  double get eraserRadius => _eraserRadius;
  Set<String> get selectedAnnotationIds =>
      Set.unmodifiable(_selectedAnnotationIds);

  void selectTool(DrawingTool tool) {
    if (tool == DrawingTool.browse) {
      _activeTool = DrawingTool.browse;
      _isToolOptionsOpen = false;
    } else {
      _activeTool = tool;
      _lastEditingTool = tool;
      _isToolOptionsOpen = false;
      _isTransformMode = false;
      if (tool == DrawingTool.text) _textActivationVersion++;
    }
    notifyListeners();
  }

  void toggleBrowse() {
    if (isBrowseMode) {
      _activeTool = _lastEditingTool;
      _isToolOptionsOpen = false;
      _isTransformMode = false;
    } else {
      _activeTool = DrawingTool.browse;
      _isToolOptionsOpen = false;
      _isTransformMode = false;
      _selectedAnnotationIds = <String>{};
    }
    notifyListeners();
  }

  void toggleToolOptions() {
    const supportsOptions = {
      DrawingTool.ballpoint,
      DrawingTool.pencil,
      DrawingTool.highlighter,
      DrawingTool.laser,
      DrawingTool.eraser,
      DrawingTool.lasso,
    };
    if (!supportsOptions.contains(_activeTool)) return;
    _isToolOptionsOpen = !_isToolOptionsOpen;
    notifyListeners();
  }

  void setEraserMode(EraserMode mode) {
    _eraserMode = mode;
    notifyListeners();
  }

  void setLassoMode(LassoMode mode) {
    _lassoMode = mode;
    notifyListeners();
  }

  void setPenColor(int colorValue) {
    if (!_penColors.containsKey(_activeTool)) return;
    _penColors[_activeTool] = colorValue;
    notifyListeners();
  }

  void setPenWidth(double width) {
    if (!_penWidths.containsKey(_activeTool) ||
        _activeTool == DrawingTool.laser) {
      return;
    }
    _penWidths[_activeTool] = width.clamp(.5, 64).toDouble();
    notifyListeners();
  }

  void setEraserRadius(double radius) {
    _eraserRadius = radius.clamp(10, 64).toDouble();
    notifyListeners();
  }

  void selectAnnotations(Set<String> ids) {
    _selectedAnnotationIds = {...ids};
    _isTransformMode = false;
    _isAnnotationDragging = false;
    notifyListeners();
  }

  void clearSelection() {
    _selectedAnnotationIds = <String>{};
    _isTransformMode = false;
    _isAnnotationDragging = false;
    notifyListeners();
  }

  void beginAnnotationDrag() {
    if (_selectedAnnotationIds.isEmpty) return;
    _isAnnotationDragging = true;
    notifyListeners();
  }

  void endAnnotationDrag() {
    if (!_isAnnotationDragging) return;
    _isAnnotationDragging = false;
    notifyListeners();
  }

  void enterTransformMode() {
    if (_selectedAnnotationIds.isEmpty) return;
    _isTransformMode = true;
    notifyListeners();
  }
}
