import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../config/api_config.dart';
import '../../models/ocr_layout.dart';
import '../../utils/document_quad_detector.dart';
import 'async_request_gate.dart';
import 'document_recognition_plugin.dart';
import 'markdown_blocks_codec.dart';

class DocumentRecognitionException implements Exception {
  final String message;
  const DocumentRecognitionException(this.message);
  @override
  String toString() => message;
}

/// 视觉大模型文档识别实现。
///
/// 流程：本地预处理（透视拉平 + 缩放，全部为后台 isolate 内的 OpenCV
/// 原生调用）→ 直连硅基流动视觉大模型（默认 Qwen3-VL-8B，速度快）→
/// 模型返回结构化书页 JSON → 校验后保存为 [BookPageDocument]。
///
/// 提示词要求模型把书页上的 emoji/特殊符号逐字原样保留，不得省略或改写。
///
/// 线程约束：像素级处理严禁在主 isolate 执行（Android 上 root isolate 即
/// 平台主线程，长计算会阻塞输入派发触发 ANR）。全部经 [Isolate.run] 在
/// worker isolate 中完成，且只用 OpenCV 原生算子（毫秒级），不使用
/// package:image 的纯 Dart 像素算法。
class VlmDocumentRecognizer implements DocumentRecognitionPlugin {
  VlmDocumentRecognizer({
    String? endpoint,
    String? apiKey,
    String? model,
    http.Client? httpClient,
    Duration? timeout,
    this.enablePreprocess = true,
    this.strictPageDewarp = false,
    this.visualContentHint = false,
    String? figureModel,
    String? figureFallbackModel,
  }) : _endpoint = endpoint ?? ApiConfig.vlmEndpoint,
       _apiKey = apiKey ?? ApiConfig.vlmApiKey,
       _model = model ?? ApiConfig.vlmModel,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout ?? const Duration(seconds: 120),
       _figureModel = figureModel ?? ApiConfig.vlmFigureModel,
       _figureFallbackModel =
           figureFallbackModel ?? ApiConfig.vlmFigureFallbackModel;

  final String _endpoint;
  final String _apiKey;
  final String _model;
  final http.Client _httpClient;
  final Duration _timeout;
  final bool enablePreprocess;

  /// 图示场景提取（第二阶段）专用模型；留空跟随 [_model]。
  final String _figureModel;

  /// 图示提取失败（超时、HTTP 错误或结构不合规）后的兜底模型；
  /// 留空表示不兜底。
  final String _figureFallbackModel;

  /// For a page that was split from a spread, only accept a detector result
  /// that is large enough to be the complete page. This restores perspective
  /// correction without reintroducing the old inner-callout crop bug.
  final bool strictPageDewarp;

  /// Strengthens the user message for a retry after local OCR suspected a
  /// table or figure but the first VLM response contained none. The system
  /// prompt stays untouched; this only nudges attention to visual blocks.
  final bool visualContentHint;

  static const int _maxSide = 1600;
  static const int _maxTokens = 6144;
  static const int _maxFigureTokens = 3072;
  static const Duration _figureTimeout = Duration(seconds: 25);

  /// 兜底模型（如 32B 稠密版）生成速度更慢，允许更长的超时。
  static const Duration _figureFallbackTimeout = Duration(seconds: 40);
  static const int _jpegQuality = 88;
  static final AsyncRequestGate _requestGate = AsyncRequestGate(1);

  /// 图示裁块请求远小于整页请求；允许两张图并行补提取，避免多图页
  /// 串行排队成倍拉长总耗时。整页请求仍保持全局 1 并发。
  static final AsyncRequestGate _figureRequestGate = AsyncRequestGate(2);

  @visibleForTesting
  static const String recognitionSystemPrompt =
      r'''你是只依据图像工作的书页 OCR 与版面分析引擎。输出一个 JSON 对象。
要求：
1) 只转录图片中清晰可见的文字；禁止补写、改写、总结、翻译或重复；
2) 每个自然段必须是一个独立 block。禁止按视觉换行拆段，也禁止合并相邻自然段；
3) block.type 只能是 title、paragraph、secondary、list_item、quote、table、figure、
chart、page_header、sidebar；明显比正文更细或更浅的整段使用 secondary；
4) 有边框或无边框的表格、左右对应列、按同一横行配对的内容，必须使用一个
type 为 table 的 block，不能改写为列表或连续段落。table_rows 是二维字符串数组：
每个内层数组对应原图的一行，每个元素对应同一列的一个单元格；空单元格保留为空字符串。
首行是列标题时 table_header_rows 为 1，否则为 0。table block 的 text 设为空字符串；
5) 表单表格即使只有表头、空白填写格或横线，也必须输出 table：保留可见列数和
行数，空白单元格写 ""，不得因没有文字而省略整张表；
6) 曲线图、坐标图、流程图、示意图、框图等非纯文字视觉内容必须输出一个 figure 或
chart block，其 x、y、width、height 覆盖整个图形（含坐标轴、箭头和图内文字），不得把
图题或周围正文当作图的替代品，也不得省略该 block；text 只填写图外图题；
7) figure/chart 在本次整页识别中只输出准确边界、图外图题和 figure_kind，不要展开图内
元素，也不要把图内文字重复为正文。figure_kind 只能是 diagram、chart、callout、illustration；
图内结构会由后续独立步骤提取，以免整页 JSON 过长；
8) 照片、绘画等无法用上述基本元素可靠重建的复杂插图仍输出 figure，figure_kind 使用
illustration，并在 text 中仅写可见图题；不得臆造图中内容；
9) first_line_indent 只能为 0 或 2。原书自然段首行明显空两个汉字格时为 2，
包括整段加粗但仍连续行文的正文；填写项、短标签、例子引出行、标题、页眉、侧栏、列表一律为 0；
10) font_weight 只能为 light、regular、bold；font_style 只能为 normal、italic。
字重和斜体必须按图片实际排印判断，浅色细体不能当成普通正文；
11) 图片中的 emoji、颜文字、特殊符号必须逐字原样保留，
禁止省略、禁止替换为文字说明、禁止统一改写；
12) 条目、标题或段落前确实可见的装饰图标与符号必须原样保留；
无法辨认时不得猜测、替换或补写 emoji；
13) 页眉使用 page_header，侧边竖排章节栏使用 sidebar。它们不能混入正文；
书页页码只放在顶层 page_number，默认在页面底部居中，不创建页码 block；
14) x、y、width、height 是各 block 在整页中的 0~1 相对坐标；阅读顺序由 order
从 1 递增。正文必须按原书从上到下排列；
15) 输出前必须检查：若多个短文本在相同 y 位置形成两列或多列，不得按“先整列左边、
再整列右边”的顺序输出 paragraph，必须合并为一个 table 并按横行写入 table_rows；
16) 只输出合法 JSON，不要 Markdown、代码围栏、解释或前言。结构必须为：
{"schema_version":2,"blocks":[{"order":1,"text":"","type":"paragraph","first_line_indent":2,"font_weight":"regular","font_style":"normal","x":0.1,"y":0.1,"width":0.8,"height":0.1},{"order":2,"text":"图题","type":"figure","figure_kind":"diagram","x":0.1,"y":0.3,"width":0.8,"height":0.2}],"page_number":null}。''';

  @visibleForTesting
  static const String figureSceneSystemPrompt =
      r'''你是只依据输入图像工作的图表结构提取引擎。输入图像只包含一个图表、流程图、示意图或框图。
只输出合法 JSON，不要代码围栏、解释或前言。
1) figure_kind 只能是 diagram、chart、callout、illustration；figure_aspect_ratio 是图形宽高比，范围 0.5~4；
2) figure_elements 按从底到顶的绘制顺序列出可见元素，kind 只能是 text、rect、rounded_rect、ellipse、line、arrow、polyline、curve；
3) 所有坐标都是图内 0~1 相对坐标，最多保留 3 位小数。rect/ellipse 使用 x、y、width、height；line/arrow/polyline/curve 使用 points:[[x,y],...]；
4) text 使用 text、x、y、width、height、text_role（title/label/caption/secondary）和 text_align（left/center/right）；
5) 保留所有清晰可见的图内文字、边框、轴线、箭头、连接关系和主要曲线。相邻共线线段应合并；一条曲线最多使用 12 个采样点；每幅图最多 80 个元素；不要输出装饰噪点；
6) 照片或绘画等无法可靠重建的内容使用 illustration，figure_elements 置空，不得臆造。
结构：{"figure_kind":"diagram","figure_aspect_ratio":1.8,"figure_elements":[{"kind":"rect","x":0.1,"y":0.1,"width":0.8,"height":0.8},{"kind":"text","text":"图内文字","x":0.2,"y":0.3,"width":0.6,"height":0.2,"text_role":"label","text_align":"center"}]}。''';

  @override
  Future<DocumentRecognitionResult> recognize(String imagePath) async {
    final totalTimer = Stopwatch()..start();
    final apiKey = _apiKey.isNotEmpty
        ? _apiKey
        : await ApiConfig.resolveVlmApiKey();
    if (apiKey.isEmpty) {
      throw const DocumentRecognitionException('未配置视觉模型密钥，请检查本机 vision.env 配置');
    }

    final sourceBytes = await File(imagePath).readAsBytes();
    final preprocessTimer = Stopwatch()..start();
    final processed = await Isolate.run(
      () => processPageBytes(
        sourceBytes,
        dewarp: enablePreprocess,
        strictPageDewarp: strictPageDewarp,
      ),
    );
    preprocessTimer.stop();

    var displayPath = await _writeDisplayImage(processed);
    if (displayPath.isEmpty) displayPath = imagePath;
    final payload = base64Encode(processed);

    debugPrint(
      '[VlmRecognizer] model=$_model display=$displayPath '
      'payloadBytes=${processed.length}',
    );

    final queueTimer = Stopwatch()..start();
    final requestTimer = Stopwatch();
    final response = await _requestGate.run(() async {
      queueTimer.stop();
      requestTimer.start();
      try {
        return await _httpClient
            .post(
              Uri.parse(_endpoint),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode({
                'model': _model,
                'messages': [
                  {'role': 'system', 'content': recognitionSystemPrompt},
                  {
                    'role': 'user',
                    'content': [
                      {
                        'type': 'image_url',
                        'image_url': {'url': 'data:image/jpeg;base64,$payload'},
                      },
                      {'type': 'text', 'text': _userInstruction()},
                    ],
                  },
                ],
                'temperature': 0.1,
                'max_tokens': _maxTokens,
              }),
            )
            .timeout(
              _timeout,
              onTimeout: () {
                throw TimeoutException('文档识别超时，请重试');
              },
            );
      } finally {
        requestTimer.stop();
      }
    });

    if (response.statusCode != 200) {
      throw DocumentRecognitionException(
        '文档识别接口返回 ${response.statusCode}：${_errorMessage(response)}',
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = (decoded is Map) ? decoded['choices'] : null;
    final message = (choices is List && choices.isNotEmpty)
        ? choices[0]['message']
        : null;
    final content = (message is Map) ? message['content'] : null;
    if (content == null || content.toString().trim().isEmpty) {
      throw const DocumentRecognitionException('文档识别返回内容为空，请重试');
    }

    final rawContent = content.toString().trim();
    var document = parseStructuredResponse(rawContent);
    final figureSceneTimer = Stopwatch()..start();
    final figureScenes = await _attachFigureScenes(document, processed, apiKey);
    figureSceneTimer.stop();
    document = figureScenes.document;
    final blocks = document.blocks;
    if (blocks.isEmpty) {
      throw const DocumentRecognitionException('未识别到文字，请重新拍照');
    }
    final markdown = document.compatibilityMarkdown.isNotEmpty
        ? document.compatibilityMarkdown
        : MarkdownBlocksCodec.toMarkdown(blocks);

    return DocumentRecognitionResult(
      markdown: markdown,
      blocks: blocks,
      displayImagePath: displayPath,
      pageNumber: document.pageNumber,
      rawResponse: rawContent,
      pageDocument: document.copyWith(compatibilityMarkdown: markdown),
      diagnostics: {
        'route': 'vlm',
        'paragraph_count': blocks.where((block) => block.isParagraph).length,
        'indented_paragraph_count': blocks
            .where((block) => block.isParagraph && block.firstLineIndent == 2)
            .length,
        'table_count': blocks.where((block) => block.isTable).length,
        'figure_count': blocks.where((block) => block.isFigure).length,
        'renderable_figure_count': blocks
            .where((block) => block.hasRenderableFigure)
            .length,
        'figure_scene_attempt_count': figureScenes.attempted,
        'figure_scene_success_count': figureScenes.completed,
        'figure_scene_request_count': figureScenes.requestCount,
        'figure_scene_detail': figureScenes.detail,
        'figure_scene_ms': figureSceneTimer.elapsedMilliseconds,
        'input_bytes': sourceBytes.length,
        'processed_bytes': processed.length,
        'preprocess_ms': preprocessTimer.elapsedMilliseconds,
        'queue_ms': queueTimer.elapsedMilliseconds,
        'request_ms': requestTimer.elapsedMilliseconds,
        'total_ms': totalTimer.elapsedMilliseconds,
      },
    );
  }

  String _userInstruction() {
    if (!visualContentHint) return '请识别这一个书页并只返回约定的 JSON。';
    return '请识别这一个书页并只返回约定的 JSON。'
        '注意：本页疑似包含表格或图示。必须为每个表格（含只有表头和空白填写格的表单）'
        '输出一个 table block，空白格保留为空字符串单元格，不得省略整表；'
        '曲线图、坐标图、流程图、示意图必须输出 figure 或 chart block，'
        '其 x、y、width、height 必须覆盖整个图形区域，后续步骤会单独提取图内结构；'
        '只抄图题、不返回完整图形边界不算完成。';
  }

  /// Extracts each figure in a focused second pass. The crop is an in-memory
  /// model input only: it is never persisted or shown in the frontend.
  ///
  /// 每个图示独立走"主模型 → 兜底模型"降级链（见
  /// [recognizeFigureSceneWithFallback]），多个图示经 [_figureRequestGate]
  /// 两两并行；单图失败只影响该图示的可绘性，不会丢弃正文。
  Future<_FigureSceneBatch> _attachFigureScenes(
    BookPageDocument document,
    Uint8List processedImage,
    String apiKey,
  ) async {
    final indexes = <int>[
      for (var index = 0; index < document.blocks.length; index++)
        if (document.blocks[index].isFigure &&
            !document.blocks[index].hasRenderableFigure &&
            document.blocks[index].figureKind != 'illustration')
          index,
    ];
    if (indexes.isEmpty) {
      return _FigureSceneBatch(
        document: document,
        attempted: 0,
        completed: 0,
        requestCount: 0,
        detail: const [],
      );
    }
    final rects = [
      for (final index in indexes)
        [
          document.blocks[index].x,
          document.blocks[index].y,
          document.blocks[index].width,
          document.blocks[index].height,
        ],
    ];
    late final List<Uint8List?> crops;
    try {
      crops = await Isolate.run(
        () => _extractFigureCropBytes(processedImage, rects),
      );
    } catch (error) {
      debugPrint('[VlmRecognizer] figure crop skipped: $error');
      return _FigureSceneBatch(
        document: document,
        attempted: 0,
        completed: 0,
        requestCount: 0,
        detail: const [],
      );
    }
    final outcomes = await Future.wait([
      for (var cropIndex = 0; cropIndex < crops.length; cropIndex++)
        recognizeFigureSceneWithFallback(
          crops[cropIndex],
          apiKey,
          document.blocks[indexes[cropIndex]],
        ),
    ]);
    final updated = [...document.blocks];
    var attempted = 0;
    var completed = 0;
    var requestCount = 0;
    final detail = <String>[];
    for (var outcomeIndex = 0; outcomeIndex < outcomes.length; outcomeIndex++) {
      final outcome = outcomes[outcomeIndex];
      if (outcome.attempts == 0) continue;
      attempted++;
      requestCount += outcome.attempts;
      detail.add(
        '${outcome.models.map(_shortModelName).join('→')}:'
        '${outcome.scene != null ? 'ok' : 'fail'}:${outcome.elapsedMs}ms',
      );
      final scene = outcome.scene;
      if (scene != null) {
        updated[indexes[outcomeIndex]] = scene;
        completed++;
      }
    }
    debugPrint(
      '[VlmRecognizer] figure scenes: $completed/$attempted ok, '
      'requests=$requestCount, detail=${detail.join(' | ')}',
    );
    return _FigureSceneBatch(
      document: document.copyWith(blocks: updated),
      attempted: attempted,
      completed: completed,
      requestCount: requestCount,
      detail: detail,
    );
  }

  /// 对单个图示裁块执行"主模型 → 兜底模型"提取链。
  ///
  /// 超时、HTTP 错误、JSON 不合法或无可绘元素都会触发下一次尝试；
  /// 全部失败时 [FigureSceneOutcome.scene] 为 null，调用方只放弃该图示的
  /// 可绘结构，不得让整页识别失败。
  @visibleForTesting
  Future<FigureSceneOutcome> recognizeFigureSceneWithFallback(
    Uint8List? figureBytes,
    String apiKey,
    OcrBlock source,
  ) async {
    if (figureBytes == null) {
      return (
        scene: null,
        models: const <String>[],
        attempts: 0,
        elapsedMs: 0,
      );
    }
    final timer = Stopwatch()..start();
    final models = <String>[];
    OcrBlock? scene;
    for (final attempt in _figureAttemptPlan()) {
      models.add(attempt.model);
      try {
        final candidate = await _recognizeFigureScene(
          figureBytes,
          apiKey,
          source,
          model: attempt.model,
          timeout: attempt.timeout,
        );
        if (candidate.hasRenderableFigure ||
            candidate.figureKind == 'illustration') {
          scene = candidate;
          break;
        }
        debugPrint(
          '[VlmRecognizer] figure attempt unusable (${attempt.model}): '
          'no renderable elements',
        );
      } catch (error) {
        // A slow or malformed figure response must not discard the page text;
        // try the fallback model before giving up on this figure.
        debugPrint(
          '[VlmRecognizer] figure attempt failed (${attempt.model}): $error',
        );
      }
    }
    timer.stop();
    return (
      scene: scene,
      models: List<String>.unmodifiable(models),
      attempts: models.length,
      elapsedMs: timer.elapsedMilliseconds,
    );
  }

  /// 主模型（默认跟随整页模型）失败后追加一次兜底模型；未配置或与主模型
  /// 相同则只有一次尝试。
  List<({String model, Duration timeout})> _figureAttemptPlan() {
    final primary = _figureModel.isNotEmpty ? _figureModel : _model;
    final plan = <({String model, Duration timeout})>[
      (model: primary, timeout: _figureTimeout),
    ];
    if (_figureFallbackModel.isNotEmpty && _figureFallbackModel != primary) {
      plan.add(
        (model: _figureFallbackModel, timeout: _figureFallbackTimeout),
      );
    }
    return plan;
  }

  static String _shortModelName(String model) {
    final slash = model.indexOf('/');
    return slash < 0 ? model : model.substring(slash + 1);
  }

  Future<OcrBlock> _recognizeFigureScene(
    Uint8List figureBytes,
    String apiKey,
    OcrBlock source, {
    required String model,
    required Duration timeout,
  }) async {
    final payload = base64Encode(figureBytes);
    final response = await _figureRequestGate.run(
      () => _httpClient
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'system', 'content': figureSceneSystemPrompt},
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/jpeg;base64,$payload'},
                    },
                    {'type': 'text', 'text': '提取这一个图形并只返回约定的 JSON。'},
                  ],
                },
              ],
              'temperature': 0,
              'max_tokens': _maxFigureTokens,
              // 图示场景协议是"结构输出失败"的重灾区；语法约束可从解码端
              // 杜绝围栏、前言等非法 JSON（硅基流动已验证支持）。
              'response_format': {'type': 'json_object'},
            }),
          )
          .timeout(
            timeout,
            onTimeout: () {
              throw TimeoutException('图示结构提取超时');
            },
          ),
    );
    if (response.statusCode != 200) {
      throw DocumentRecognitionException(
        '图示结构接口返回 ${response.statusCode}：${_errorMessage(response)}',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = decoded is Map ? decoded['choices'] : null;
    final message = choices is List && choices.isNotEmpty
        ? choices[0]['message']
        : null;
    final content = message is Map ? message['content'] : null;
    if (content == null || content.toString().trim().isEmpty) {
      throw const DocumentRecognitionException('图示结构返回内容为空');
    }
    return parseFigureSceneResponse(content.toString(), source);
  }

  @visibleForTesting
  static OcrBlock parseFigureSceneResponse(String raw, OcrBlock source) {
    final decoded = jsonDecode(_stripCodeFences(raw));
    if (decoded is! Map) {
      throw const DocumentRecognitionException('图示结构返回格式不正确');
    }
    final scene = OcrBlock.fromJson({
      ...Map<String, dynamic>.from(decoded),
      'id': source.id,
      'text': source.text,
      'type': source.type,
      'x': source.x,
      'y': source.y,
      'width': source.width,
      'height': source.height,
      'first_line_indent': source.firstLineIndent,
      'font_weight': source.fontWeightRole,
      'font_style': source.fontStyleRole,
    });
    return scene.copyWith(
      figureElements: scene.figureElements.take(80).toList(growable: false),
    );
  }

  // ===========================================================================
  // 后台 isolate 图像处理（仅 OpenCV 原生算子，禁止 package:image）
  // ===========================================================================

  /// 解码 → （可选）四角检测 + 透视拉平 + 裁边 → 长边缩放到 [_maxSide] →
  /// JPEG 编码。返回的 bytes 同时用作模型输入与展示底图。
  ///
  /// 顶层函数：[Isolate.run] 的入口必须是静态/顶层可调用对象。
  static Uint8List processPageBytes(
    Uint8List source, {
    bool dewarp = true,
    bool strictPageDewarp = false,
  }) {
    final src = cv.imdecode(source, cv.IMREAD_COLOR);
    if (src.isEmpty) {
      throw const DocumentRecognitionException('无法解码图片');
    }
    cv.Mat? warped;
    try {
      if (dewarp) {
        warped = _tryDewarp(src, strictPageDewarp: strictPageDewarp);
      }
      final base = warped ?? src;
      final resized = _limitSide(base, _maxSide);
      try {
        final params = cv.VecI32.fromList([
          cv.IMWRITE_JPEG_QUALITY,
          _jpegQuality,
        ]);
        final (ok, encoded) = cv.imencode('.jpg', resized, params: params);
        params.dispose();
        if (!ok || encoded.isEmpty) {
          throw const DocumentRecognitionException('图片编码失败');
        }
        return encoded;
      } finally {
        if (!identical(resized, base)) resized.dispose();
      }
    } finally {
      warped?.dispose();
      src.dispose();
    }
  }

  static List<Uint8List?> _extractFigureCropBytes(
    Uint8List sourceBytes,
    List<List<double>> rects,
  ) {
    final source = cv.imdecode(sourceBytes, cv.IMREAD_COLOR);
    if (source.isEmpty) return List<Uint8List?>.filled(rects.length, null);
    try {
      return [for (final rect in rects) _encodeFigureCrop(source, rect)];
    } finally {
      source.dispose();
    }
  }

  static Uint8List? _encodeFigureCrop(cv.Mat source, List<double> rect) {
    if (rect.length != 4) return null;
    // Small context padding protects axes and arrow heads when the first-pass
    // bounding box is slightly tight. These bytes are never written to disk.
    final paddingX = source.cols * .012;
    final paddingY = source.rows * .012;
    final left = (rect[0] * source.cols - paddingX).floor().clamp(
      0,
      source.cols - 1,
    );
    final top = (rect[1] * source.rows - paddingY).floor().clamp(
      0,
      source.rows - 1,
    );
    final right = ((rect[0] + rect[2]) * source.cols + paddingX).ceil().clamp(
      left + 1,
      source.cols,
    );
    final bottom = ((rect[1] + rect[3]) * source.rows + paddingY).ceil().clamp(
      top + 1,
      source.rows,
    );
    final width = right - left;
    final height = bottom - top;
    if (width < 32 || height < 32) return null;
    final crop = cv.Mat.fromMat(
      source,
      copy: true,
      roi: cv.Rect(left, top, width, height),
    );
    try {
      final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 90]);
      final (ok, encoded) = cv.imencode('.jpg', crop, params: params);
      params.dispose();
      return ok && encoded.isNotEmpty ? encoded : null;
    } finally {
      crop.dispose();
    }
  }

  /// 四角检测 + 透视拉平 + 四周裁 10px；检测失败或结果不可用时返回 null。
  static cv.Mat? _tryDewarp(cv.Mat src, {bool strictPageDewarp = false}) {
    final detection = DocumentQuadDetector.detectDetailed(src).detection;
    if (detection == null || detection.quad.length != 4) return null;
    // A split half may still contain a framed exercise, table or callout.
    // Those are much smaller than a complete page, so a strict path accepts
    // only a high-confidence, page-sized quadrilateral.
    if (strictPageDewarp &&
        (detection.areaRatio < 0.58 || detection.score < 58)) {
      return null;
    }
    try {
      final warped = _warpToRect(src, detection.quad);
      // 轻量黑图防护：均值过低说明 warp 产物不可用（BGR 存于 val1~val3）。
      final mean = cv.mean(warped);
      if (mean.val1 + mean.val2 + mean.val3 < 45) {
        warped.dispose();
        return null;
      }
      return _cropMargin(warped, 10);
    } catch (e) {
      debugPrint('[VlmRecognizer] dewarp failed: $e');
      return null;
    }
  }

  /// 与 DocumentEnhancer 相同的四点透视变换。
  static cv.Mat _warpToRect(cv.Mat src, List<dynamic> corners) {
    final tl = corners[0];
    final tr = corners[1];
    final br = corners[2];
    final bl = corners[3];

    double distance(dynamic a, dynamic b) {
      return math.sqrt(math.pow((a.dx - b.dx), 2) + math.pow((a.dy - b.dy), 2));
    }

    final maxWidth = math.max(distance(tr, tl), distance(br, bl)).toDouble();
    final maxHeight = math.max(distance(bl, tl), distance(br, tr)).toDouble();

    final srcPoints = cv.VecPoint2f.fromList([
      cv.Point2f(tl.dx.toDouble(), tl.dy.toDouble()),
      cv.Point2f(tr.dx.toDouble(), tr.dy.toDouble()),
      cv.Point2f(br.dx.toDouble(), br.dy.toDouble()),
      cv.Point2f(bl.dx.toDouble(), bl.dy.toDouble()),
    ]);
    final dstPoints = cv.VecPoint2f.fromList([
      cv.Point2f(0, 0),
      cv.Point2f(maxWidth - 1, 0),
      cv.Point2f(maxWidth - 1, maxHeight - 1),
      cv.Point2f(0, maxHeight - 1),
    ]);

    final m = cv.getPerspectiveTransform2f(srcPoints, dstPoints);
    try {
      return cv.warpPerspective(src, m, (maxWidth.toInt(), maxHeight.toInt()));
    } finally {
      m.dispose();
    }
  }

  /// 四周向内裁 [margin] 像素，切掉拉平后的灰边。
  static cv.Mat _cropMargin(cv.Mat src, int margin) {
    final w = src.cols;
    final h = src.rows;
    if (w <= margin * 2 + 20 || h <= margin * 2 + 20) {
      return src;
    }
    final roi = cv.Rect(margin, margin, w - margin * 2, h - margin * 2);
    final cropped = cv.Mat.fromMat(src, copy: true, roi: roi);
    src.dispose();
    return cropped;
  }

  /// 长边超过 [maxSide] 时等比缩小；否则原样返回。
  static cv.Mat _limitSide(cv.Mat src, int maxSide) {
    final longSide = math.max(src.cols, src.rows);
    if (longSide <= maxSide) return src;
    final scale = maxSide / longSide;
    return cv.resize(src, (
      (src.cols * scale).round().clamp(1, maxSide),
      (src.rows * scale).round().clamp(1, maxSide),
    ), interpolation: cv.INTER_AREA);
  }

  /// 把处理后的图写入 photos/scanned，作为展示底图。
  static Future<String> _writeDisplayImage(Uint8List bytes) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final outDir = Directory(p.join(appDir.path, 'photos', 'scanned'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final path = p.join(
        outDir.path,
        'scan_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (e) {
      debugPrint('[VlmRecognizer] display persistence failed: $e');
      return '';
    }
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          return error['message']?.toString() ?? '';
        }
        if (error is String) return error;
      }
    } catch (_) {}
    return '';
  }

  static String _stripCodeFences(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*\n'), '');
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }

  /// 解析新 JSON 协议；旧模型/代理偶尔返回 Markdown 时保留只读兼容兜底。
  @visibleForTesting
  static BookPageDocument parseStructuredResponse(String raw) {
    final cleaned = _stripCodeFences(raw);
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) throw const FormatException('not an object');
      final document = BookPageDocument.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      final ordered = [...document.blocks]
        ..sort((a, b) {
          final byId = a.id.compareTo(b.id);
          if (a.id > 0 && b.id > 0 && byId != 0) return byId;
          final byY = a.y.compareTo(b.y);
          return byY != 0 ? byY : a.x.compareTo(b.x);
        });
      return _normalizeBookPageDocument(document.copyWith(blocks: ordered));
    } catch (_) {
      if (cleaned.trimLeft().startsWith('{')) {
        throw const DocumentRecognitionException('书页结构返回不完整，请重试本页');
      }
      final extracted = _extractLegacyPageFurniture(cleaned);
      return _normalizeBookPageDocument(
        BookPageDocument(
          blocks: extracted.blocks,
          pageNumber: extracted.pageNumber,
          compatibilityMarkdown: extracted.markdown,
        ),
      );
    }
  }

  /// The vision model is responsible for transcription and block semantics,
  /// but small models regularly emit `first_line_indent: 0` for every block.
  /// Normalize that finite layout field deterministically before persistence.
  /// This does not rewrite source text or merge blocks.
  static BookPageDocument _normalizeBookPageDocument(
    BookPageDocument document,
  ) {
    // Small VLMs sometimes transcribe a table correctly but emit its cells as
    // ordinary blocks in column-major order. Geometry is deterministic, so
    // repair repeated aligned short blocks before paragraph normalization.
    final ordered = _rescueBareTableBlocks(
      _reconstructTablesFromGeometry(document.blocks),
    );
    final firstBodyIndex = ordered.indexWhere((block) => !block.isFurniture);
    final normalized = <OcrBlock>[];
    for (var i = 0; i < ordered.length; i++) {
      final block = ordered[i];
      final explicitIndent = block.firstLineIndent == 2;
      final inferredIndent = _shouldInferTwoCharacterIndent(
        block,
        isFirstBody: i == firstBodyIndex,
      );
      normalized.add(
        block.copyWith(
          id: i + 1,
          firstLineIndent: explicitIndent || inferredIndent ? 2 : 0,
        ),
      );
    }
    return document.copyWith(
      blocks: normalized,
      compatibilityMarkdown: MarkdownBlocksCodec.toMarkdown(normalized),
    );
  }

  /// A `table` block whose `table_rows` failed to parse would previously end
  /// up with empty rows and empty text, which the renderer treats as nothing
  /// at all. Rebuild a single-column table from its text so the content stays
  /// visible (and structurally a table) instead of silently vanishing.
  static List<OcrBlock> _rescueBareTableBlocks(List<OcrBlock> blocks) {
    return [
      for (final block in blocks)
        if (block.type == 'table' &&
            block.tableRows.isEmpty &&
            block.text.trim().isNotEmpty)
          block.copyWith(
            tableRows: [
              for (final line in block.text.split('\n'))
                if (line.trim().isNotEmpty) [line.trim()],
            ],
          )
        else
          block,
    ];
  }

  static List<OcrBlock> _reconstructTablesFromGeometry(List<OcrBlock> blocks) {
    final candidates = blocks.where(_isTableCellCandidate).toList();
    if (candidates.length < 6) return blocks;

    final clustered = _clusterTableColumns(candidates);
    var columnGroups = clustered
        .where((column) => column.blocks.length >= 3)
        .toList();
    if (columnGroups.length < 2) {
      // A wide form table (a header row plus one filled row above blank fill
      // rules) yields only two blocks per column, but three or more equally
      // spaced columns is already a strong table signature.
      final wideForm = clustered
          .where((column) => column.blocks.length >= 2)
          .toList();
      if (wideForm.length >= 3) columnGroups = wideForm;
    }
    if (columnGroups.length < 2) return blocks;

    final rows = <_GeometryTableRow>[];
    final anchor = columnGroups.first;
    for (final anchorBlock in anchor.blocks) {
      final cells = <int, OcrBlock>{0: anchorBlock};
      for (
        var columnIndex = 1;
        columnIndex < columnGroups.length;
        columnIndex++
      ) {
        final match = _nearestVerticallyAligned(
          anchorBlock,
          columnGroups[columnIndex].blocks,
        );
        if (match != null) cells[columnIndex] = match;
      }
      if (cells.length >= 2) rows.add(_GeometryTableRow(cells));
    }
    rows.sort((a, b) => a.centerY.compareTo(b.centerY));
    // A wide form table (three or more columns) can be worth rebuilding with
    // as few as two text rows — e.g. a header row plus one filled row above
    // blank fill rules. Two-column repairs still need three rows to avoid
    // turning ordinary label/value pairs into tables.
    final minRunLength = columnGroups.length >= 3 ? 2 : 3;
    if (rows.length < minRunLength) return blocks;

    final runs = <List<_GeometryTableRow>>[];
    var current = <_GeometryTableRow>[];
    for (final row in rows) {
      if (current.isNotEmpty && row.centerY - current.last.centerY > .11) {
        runs.add(current);
        current = <_GeometryTableRow>[];
      }
      current.add(row);
    }
    if (current.isNotEmpty) runs.add(current);

    final replacements = <int, OcrBlock>{};
    final consumed = <OcrBlock>{};
    for (final run in runs.where((run) => run.length >= minRunLength)) {
      final activeColumns = <int>[
        for (
          var columnIndex = 0;
          columnIndex < columnGroups.length;
          columnIndex++
        )
          if (run.where((row) => row.cells[columnIndex] != null).length >= 2)
            columnIndex,
      ];
      if (activeColumns.length < 2) continue;
      final activeCenters = [
        for (final index in activeColumns) columnGroups[index].centerX,
      ];
      var columnsSeparated = true;
      for (var i = 1; i < activeCenters.length; i++) {
        if (activeCenters[i] - activeCenters[i - 1] < .12) {
          columnsSeparated = false;
          break;
        }
      }
      if (!columnsSeparated) continue;

      final used = <OcrBlock>{
        for (final row in run)
          for (final index in activeColumns) ?row.cells[index],
      };
      final firstIndex = blocks.indexWhere(used.contains);
      if (firstIndex < 0) continue;
      final left = used.map((block) => block.x).reduce(math.min);
      final top = used.map((block) => block.y).reduce(math.min);
      final right = used.map((block) => block.x + block.width).reduce(math.max);
      final bottom = used
          .map((block) => block.y + block.height)
          .reduce(math.max);
      final firstRow = run.first;
      final laterCells = run
          .skip(1)
          .expand(
            (row) => activeColumns
                .map((index) => row.cells[index])
                .whereType<OcrBlock>(),
          );
      final firstRowIsHeader =
          activeColumns
              .map((index) => firstRow.cells[index])
              .whereType<OcrBlock>()
              .any((block) => block.isBold || block.isTitle) &&
          laterCells.any((block) => !block.isBold && !block.isTitle);
      replacements[firstIndex] = OcrBlock(
        id: 0,
        text: '',
        type: 'table',
        x: left,
        y: top,
        width: (right - left).clamp(0, 1).toDouble(),
        height: (bottom - top).clamp(0, 1).toDouble(),
        tableHeaderRowCount: firstRowIsHeader ? 1 : 0,
        tableRows: [
          for (final row in run)
            [
              for (final index in activeColumns)
                row.cells[index]?.text.trim() ?? '',
            ],
        ],
      );
      consumed.addAll(used);
    }
    if (replacements.isEmpty) return blocks;

    return [
      for (var index = 0; index < blocks.length; index++)
        if (replacements[index] case final replacement?)
          replacement
        else if (!consumed.contains(blocks[index]))
          blocks[index],
    ];
  }

  static bool _isTableCellCandidate(OcrBlock block) {
    if (block.isFurniture ||
        block.isTable ||
        block.isQuote ||
        block.isListItem ||
        block.text.trim().isEmpty ||
        block.width <= 0 ||
        block.height <= 0 ||
        block.width > .62 ||
        block.height > .1) {
      return false;
    }
    final text = block.text.trim();
    if (text.runes.length > 42) return false;
    return !(text.runes.length > 18 && RegExp(r'[。！？!?]$').hasMatch(text));
  }

  static List<_GeometryTableColumn> _clusterTableColumns(
    List<OcrBlock> candidates,
  ) {
    final sorted = [...candidates]..sort((a, b) => a.x.compareTo(b.x));
    final columns = <_GeometryTableColumn>[];
    for (final block in sorted) {
      if (columns.isEmpty || block.x - columns.last.meanLeft > .08) {
        columns.add(_GeometryTableColumn([block]));
      } else {
        columns.last.blocks.add(block);
      }
    }
    for (final column in columns) {
      column.blocks.sort((a, b) => a.y.compareTo(b.y));
    }
    return columns;
  }

  static OcrBlock? _nearestVerticallyAligned(
    OcrBlock anchor,
    List<OcrBlock> candidates,
  ) {
    OcrBlock? best;
    var bestDistance = double.infinity;
    final anchorCenter = anchor.y + anchor.height / 2;
    for (final candidate in candidates) {
      final candidateCenter = candidate.y + candidate.height / 2;
      final distance = (candidateCenter - anchorCenter).abs();
      final tolerance = math.max(
        .025,
        math.max(anchor.height, candidate.height) * .9,
      );
      if (distance <= tolerance && distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }

  static bool _shouldInferTwoCharacterIndent(
    OcrBlock block, {
    required bool isFirstBody,
  }) {
    if (!block.isParagraph) return false;
    final text = block.text.trim();
    if (text.isEmpty || _looksLikeUnindentedRow(text)) return false;

    // The first block near the page top can be a paragraph continued from the
    // previous page. Do not invent an indent without explicit model evidence.
    if (isFirstBody && block.y < .08) return false;

    final cjkCount = RegExp(
      r'[\u3400-\u4DBF\u4E00-\u9FFF]',
    ).allMatches(text).length;
    return cjkCount >= 12 && RegExp(r'[，。！？；：“”]').hasMatch(text);
  }

  static bool _looksLikeUnindentedRow(String text) {
    if (RegExp(r'^(?:[-*+•●▪◦]|\d+[.、])\s*').hasMatch(text)) return true;
    final length = text.runes.length;
    return length <= 24 &&
        (text.endsWith('：') || RegExp(r'^[^。！？!?]{1,14}[：:]').hasMatch(text));
  }

  static _ExtractedPageFurniture _extractLegacyPageFurniture(String markdown) {
    var content = markdown;

    String? take(String name) {
      final expression = RegExp(
        '<!--\\s*xiaoqi:$name\\s*-->(.*?)<!--\\s*/xiaoqi:$name\\s*-->',
        caseSensitive: false,
        dotAll: true,
      );
      final match = expression.firstMatch(content);
      if (match == null) return null;
      content = content.replaceFirst(expression, '');
      final value = match.group(1)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final header = take('page-header-top');
    final rightSidebar = take('page-sidebar-right');
    final leftSidebar = take('page-sidebar-left');
    final pageNumber = take('page-number');
    final bodyBlocks = MarkdownBlocksCodec.fromMarkdown(content.trim());
    final blocks = <OcrBlock>[
      if (header != null)
        OcrBlock(
          id: 0,
          text: header,
          type: 'page_header',
          x: 0.15,
          y: 0.02,
          width: 0.7,
          height: 0.04,
        ),
      ...bodyBlocks,
      if (leftSidebar != null)
        OcrBlock(
          id: 0,
          text: leftSidebar,
          type: 'sidebar',
          x: 0.02,
          y: 0.12,
          width: 0.05,
          height: 0.5,
        ),
      if (rightSidebar != null)
        OcrBlock(
          id: 0,
          text: rightSidebar,
          type: 'sidebar',
          x: 0.93,
          y: 0.12,
          width: 0.05,
          height: 0.5,
        ),
    ];
    return _ExtractedPageFurniture(
      markdown: content.trim(),
      blocks: [
        for (var i = 0; i < blocks.length; i++) blocks[i].copyWith(id: i + 1),
      ],
      pageNumber: pageNumber,
    );
  }
}

/// 单个图示降级链的执行结果：最终场景（null 表示全部尝试失败）、
/// 依次尝试过的模型、实际请求次数与总耗时。
typedef FigureSceneOutcome = ({
  OcrBlock? scene,
  List<String> models,
  int attempts,
  int elapsedMs,
});

class _FigureSceneBatch {
  const _FigureSceneBatch({
    required this.document,
    required this.attempted,
    required this.completed,
    required this.requestCount,
    required this.detail,
  });

  final BookPageDocument document;
  final int attempted;
  final int completed;

  /// 含兜底重试在内的实际 HTTP 请求次数（≥ attempted）。
  final int requestCount;

  /// 每个图示一条可读摘要，形如 `8B-Instruct→30B-A3B-Instruct:ok:23456ms`。
  final List<String> detail;
}

class _GeometryTableColumn {
  _GeometryTableColumn(this.blocks);

  final List<OcrBlock> blocks;

  double get meanLeft =>
      blocks.map((block) => block.x).reduce((a, b) => a + b) / blocks.length;

  double get centerX {
    final centers = blocks.map((block) => block.x + block.width / 2);
    return centers.reduce((a, b) => a + b) / blocks.length;
  }
}

class _GeometryTableRow {
  const _GeometryTableRow(this.cells);

  final Map<int, OcrBlock> cells;

  double get centerY {
    final centers = cells.values.map((block) => block.y + block.height / 2);
    return centers.reduce((a, b) => a + b) / cells.length;
  }
}

class _ExtractedPageFurniture {
  const _ExtractedPageFurniture({
    required this.markdown,
    required this.blocks,
    required this.pageNumber,
  });

  final String markdown;
  final List<OcrBlock> blocks;
  final String? pageNumber;
}
