/// 相机拍摄模式（传给后端做版面识别策略）。
enum CaptureMode {
  /// 单页拍：一页书/文档。
  singlePage,

  /// 双页拍：对开两页（占位，后续实现）。
  doublePage,
}

extension CaptureModeLabel on CaptureMode {
  String get label {
    switch (this) {
      case CaptureMode.singlePage:
        return '单页拍';
      case CaptureMode.doublePage:
        return '双页拍';
    }
  }
}
