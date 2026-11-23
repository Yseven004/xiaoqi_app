import Flutter
import ImageIO
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let deviceOcr = DeviceOcr()
  private let companionBrightness = CompanionBrightness()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "xiaoqi_app/fast_ocr", binaryMessenger: messenger)
      .setMethodCallHandler { [deviceOcr] call, result in
        deviceOcr.handle(call, result: result)
      }
    FlutterMethodChannel(name: "xiaoqi_app/runtime_config", binaryMessenger: messenger)
      .setMethodCallHandler { [companionBrightness] call, result in
        guard call.method == "setCompanionBrightness" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let arguments = call.arguments as? [String: Any]
        let value = (arguments?["brightness"] as? NSNumber)?.doubleValue
        companionBrightness.set(value)
        result(nil)
      }
  }
}

private final class CompanionBrightness: NSObject {
  private weak var adjustedScreen: UIScreen?
  private var originalBrightness: CGFloat?
  private var requestedBrightness: CGFloat?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(sceneWillDeactivate(_:)),
      name: UIScene.willDeactivateNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sceneDidActivate(_:)),
      name: UIScene.didActivateNotification, object: nil
    )
  }

  func set(_ value: Double?) {
    requestedBrightness = value.flatMap { $0.isFinite ? CGFloat(min(1, max(0.05, $0))) : nil }
    guard requestedBrightness != nil else {
      restore()
      return
    }
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive && $0.windows.contains { $0.isKeyWindow } }
    if let scene = scene { apply(to: scene.screen) }
  }

  @objc private func sceneWillDeactivate(_ notification: Notification) {
    guard let scene = notification.object as? UIWindowScene,
      scene.screen === adjustedScreen
    else { return }
    restore()
  }

  @objc private func sceneDidActivate(_ notification: Notification) {
    guard let scene = notification.object as? UIWindowScene,
      scene.windows.contains(where: { $0.isKeyWindow })
    else { return }
    apply(to: scene.screen)
  }

  private func apply(to screen: UIScreen) {
    guard let requested = requestedBrightness else { return }
    if adjustedScreen !== screen {
      restore()
      adjustedScreen = screen
      originalBrightness = screen.brightness
    }
    screen.brightness = requested
  }

  private func restore() {
    if let screen = adjustedScreen, let original = originalBrightness {
      screen.brightness = original
    }
    adjustedScreen = nil
    originalBrightness = nil
  }
}

private final class DeviceOcr {
  private static let languages = ["zh-Hans", "zh-Hant", "en", "ja"]
  private let executor = DispatchQueue(
    label: "xiaoqi_app.fast_ocr", qos: .userInitiated, autoreleaseFrequency: .workItem
  )
  // Method-channel handlers and completions run on the main queue.
  private var jobs: [UUID: VisionJob] = [:]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let jobId = arguments?["jobId"] as? String
    switch call.method {
    case "cancelRecognition":
      if let jobId = jobId {
        for job in jobs.values where job.id == jobId { job.cancel() }
      }
      result(nil)
    case "recognizeChineseText", "recognizePage":
      guard let path = arguments?["imagePath"] as? String, !path.isEmpty else {
        result(FlutterError(code: "invalid_image", message: "未指定待识别的图片", details: nil))
        return
      }
      let submitted = arguments?["languages"] as? [String] ?? []
      let languages = call.method == "recognizeChineseText"
        ? ["zh-Hans", "en"]
        : submitted.isEmpty ? Self.languages : submitted
      let job = VisionJob(id: jobId)
      let token = UUID()
      jobs[token] = job
      executor.async {
        let value: Any
        do {
          value = try self.readPage(path: path, languages: languages, job: job)
        } catch let error as DeviceOcrError {
          value = FlutterError(code: error.code, message: error.message, details: nil)
        } catch {
          value = FlutterError(code: "ocr_failed", message: "本机文字识别失败", details: nil)
        }
        DispatchQueue.main.async {
          self.jobs.removeValue(forKey: token)
          if job.isCancelled {
            result(FlutterError(code: "cancelled", message: "本机文字识别已停止", details: nil))
          } else {
            result(value)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readPage(path: String, languages: [String], job: VisionJob) throws -> [String: Any] {
    try job.checkActive()
    let started = ProcessInfo.processInfo.systemUptime
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw DeviceOcrError(code: "invalid_image", message: "无法打开待识别的图片")
    }

    let request = makeRequest()
    let supported: [String]
    if #available(iOS 15.0, *) {
      supported = try request.supportedRecognitionLanguages()
    } else {
      supported = try VNRecognizeTextRequest.supportedRecognitionLanguages(
        for: request.recognitionLevel, revision: request.revision
      )
    }
    var match: [String: String] = [:]
    var unsupported: [String] = []
    for language in languages where match[language] == nil && !unsupported.contains(language) {
      if Self.languages.contains(language),
        let actual = supported.first(where: { canonicalLanguage($0) == language }) {
        match[language] = actual
      } else {
        unsupported.append(language)
      }
    }
    guard !match.isEmpty else {
      throw DeviceOcrError(
        code: "unsupported_language", message: "此设备的本机 OCR 暂不支持：\(unsupported.joined(separator: "、"))"
      )
    }

    // Vision permits pairing Chinese with English. Give Japanese its own request
    // so the system never silently drops it from a Chinese request.
    let nonJapanese = languages.filter { $0 != "ja" }
      .compactMap { match[$0] }
      .reduce(into: [String]()) { values, language in
        if !values.contains(language) { values.append(language) }
      }
    var requests: [VNRecognizeTextRequest] = []
    if !nonJapanese.isEmpty {
      request.recognitionLanguages = nonJapanese
      requests.append(request)
    }
    if let japanese = match["ja"] {
      let japaneseRequest = makeRequest()
      japaneseRequest.recognitionLanguages = [japanese]
      requests.append(japaneseRequest)
    }
    try job.bind(requests)
    defer { job.unbind() }
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform(requests)
    try job.checkActive()

    let lines = try mergeLines(requests, job: job)
    if lines.isEmpty && !unsupported.isEmpty {
      throw DeviceOcrError(
        code: "unsupported_language", message: "未识别到文字，此系统未提供：\(unsupported.joined(separator: "、"))"
      )
    }
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let rows: [[String: Any]] = lines.map { item in
      let rect = item.bounds
      return [
        "text": item.text,
        "left": Double(rect.minX * width),
        "top": Double((1 - rect.maxY) * height),
        "right": Double(rect.maxX * width),
        "bottom": Double((1 - rect.minY) * height),
        "confidence": Double(item.confidence),
        "angle": 0.0,
      ]
    }
    return [
      "fullText": lines.map(\.text).joined(separator: "\n"),
      "lines": rows,
      "imageWidth": image.width,
      "imageHeight": image.height,
      "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
      "appliedRotation": 0,
      "unsupportedLanguages": unsupported,
    ]
  }

  private func makeRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    if let revision = VNRecognizeTextRequest.supportedRevisions.last {
      request.revision = revision
    }
    return request
  }

  private func canonicalLanguage(_ identifier: String) -> String {
    switch identifier.lowercased() {
    case "zh-hans", "zh-cn", "zh-hans-cn": return "zh-Hans"
    case "zh-hant", "zh-tw", "zh-hk", "zh-hant-tw": return "zh-Hant"
    default: return String(identifier.split(separator: "-").first ?? "")
    }
  }

  private struct Line {
    let text: String
    let bounds: CGRect
    let confidence: Float

    var score: Float {
      // Kana in the Japanese pass is useful evidence when both passes detect
      // the same line of visually similar Han characters.
      let hasKana = text.unicodeScalars.contains {
        (0x3041...0x30FA).contains($0.value) || (0xFF66...0xFF9F).contains($0.value)
      }
      return confidence + (hasKana ? 0.12 : 0)
    }
  }

  private func mergeLines(_ requests: [VNRecognizeTextRequest], job: VisionJob) throws -> [Line] {
    var merged: [Line] = []
    for request in requests {
      try job.checkActive()
      for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !text.isEmpty, !bounds.isEmpty, !bounds.isNull else { continue }
        let line = Line(text: text, bounds: bounds, confidence: candidate.confidence)
        let matching = merged.firstIndex { previous in
          let overlap = previous.bounds.intersection(bounds)
          guard !overlap.isNull else { return false }
          // Compare whole lines so short fragments cannot replace a longer line.
          return overlap.width >= 0.7 * max(previous.bounds.width, bounds.width)
            && overlap.height >= 0.6 * max(previous.bounds.height, bounds.height)
        }
        if let index = matching {
          if merged[index].score < line.score { merged[index] = line }
        } else {
          merged.append(line)
        }
      }
    }
    return merged
  }
}

private struct DeviceOcrError: Error {
  let code: String
  let message: String
}

private final class VisionJob {
  let id: String?
  private let lock = NSLock()
  private var cancelled = false
  private var requests: [VNRecognizeTextRequest] = []

  init(id: String?) { self.id = id }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func checkActive() throws {
    if isCancelled {
      throw DeviceOcrError(code: "cancelled", message: "本机文字识别已停止")
    }
  }

  func bind(_ requests: [VNRecognizeTextRequest]) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled {
      throw DeviceOcrError(code: "cancelled", message: "本机文字识别已停止")
    }
    self.requests = requests
  }

  func unbind() {
    lock.lock()
    requests.removeAll()
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let running = requests
    lock.unlock()
    for request in running { request.cancel() }
  }
}
