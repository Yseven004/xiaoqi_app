import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config/book_flow_theme.dart';
import '../models/book_recognition.dart';
import '../plugins/book_metadata/book_metadata_plugin.dart';
import '../services/book_library_service.dart';
import '../services/book_recognition_repository.dart';
import '../utils/isbn.dart';
import '../widgets/book_candidate_verification.dart';

class BookIsbnScannerPage extends StatefulWidget {
  const BookIsbnScannerPage({
    super.key,
    required this.repository,
    this.bookLibraryService,
    this.metadataPlugin,
    this.title = '新建书籍',
  });

  final BookRecognitionRepository repository;
  final BookLibraryService? bookLibraryService;
  final BookMetadataPlugin? metadataPlugin;
  final String title;

  @override
  State<BookIsbnScannerPage> createState() => _BookIsbnScannerPageState();
}

class _BookIsbnScannerPageState extends State<BookIsbnScannerPage>
    with WidgetsBindingObserver {
  late final MobileScannerController _scannerController;
  late final BookLibraryService _bookLibrary;
  bool _lookingUp = false;
  String? _lastDetectedIsbn;
  DateTime? _lastDetectedAt;
  int _detectedCount = 0;
  String? _isbn;
  BookCandidate? _candidate;
  BookMetadataLookupResult? _metadataResult;
  String? _message;
  bool _manualInputOpen = false;
  bool _appInForeground = true;
  Future<void>? _scannerStartFuture;

  @override
  void initState() {
    super.initState();
    _bookLibrary = widget.bookLibraryService ?? BookLibraryService();
    _scannerController = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 650,
      formats: const [BarcodeFormat.ean13],
      autoZoom: false,
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startScanner());
    });
  }

  bool get _canScan =>
      mounted &&
      _appInForeground &&
      !_manualInputOpen &&
      !_lookingUp &&
      _candidate == null;

  Future<void> _startScanner() {
    if (!_canScan) return Future<void>.value();
    final existing = _scannerStartFuture;
    if (existing != null) return existing;
    late final Future<void> startFuture;
    startFuture = _startScannerInternal().whenComplete(() {
      if (identical(_scannerStartFuture, startFuture)) {
        _scannerStartFuture = null;
      }
    });
    _scannerStartFuture = startFuture;
    return startFuture;
  }

  Future<void> _startScannerInternal() async {
    try {
      await _scannerController.start();
      if (!_canScan) await _scannerController.stop();
    } catch (_) {
      if (mounted && _canScan) {
        setState(() => _message = '相机暂时无法启动，请手动输入');
      }
    }
  }

  Future<void> _stopScanner() async {
    final starting = _scannerStartFuture;
    if (starting != null) await starting;
    try {
      await _scannerController.stop();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (_appInForeground) {
      unawaited(_startScanner());
    } else {
      unawaited(_stopScanner());
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_canScan) return;
    String? detectedIsbn;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final isbn = Isbn.normalize(raw);
      if (isbn == null) {
        if (mounted) {
          setState(() => _message = '扫到的不是有效 ISBN，请对准书籍条码');
        }
        continue;
      }
      detectedIsbn = isbn;
      break;
    }
    if (detectedIsbn == null) {
      _resetDetectedIsbn();
      return;
    }

    final now = DateTime.now();
    final isSameRecentIsbn =
        _lastDetectedIsbn == detectedIsbn &&
        _lastDetectedAt != null &&
        now.difference(_lastDetectedAt!) <= const Duration(seconds: 2);
    _lastDetectedIsbn = detectedIsbn;
    _lastDetectedAt = now;
    _detectedCount = isSameRecentIsbn ? _detectedCount + 1 : 1;
    if (_detectedCount < 2) {
      if (mounted) {
        setState(() => _message = '已识别，保持条码清晰并稳定一下');
      }
      return;
    }

    _resetDetectedIsbn();
    await _lookup(detectedIsbn);
  }

  void _resetDetectedIsbn() {
    _lastDetectedIsbn = null;
    _lastDetectedAt = null;
    _detectedCount = 0;
  }

  Future<void> _lookup(String raw) async {
    final isbn = Isbn.normalize(raw);
    if (isbn == null || _lookingUp) {
      if (mounted && isbn == null) {
        setState(() => _message = '这串数字不是有效的图书条形码');
      }
      return;
    }
    _resetDetectedIsbn();
    setState(() {
      _lookingUp = true;
      _isbn = isbn;
      _candidate = null;
      _metadataResult = null;
      _message = null;
    });
    unawaited(HapticFeedback.mediumImpact());
    await _stopScanner();
    try {
      final local = await _bookLibrary.findByIsbn(isbn);
      if (!mounted) return;
      if (local != null) {
        setState(() {
          _candidate = BookCandidate(
            book: local,
            confidence: BookMatchConfidence.high,
            matchLabel: '曾经确认过',
            score: 1,
            fromHistory: true,
          );
          _lookingUp = false;
        });
        return;
      }

      final metadata = widget.metadataPlugin == null
          ? null
          : await widget.metadataPlugin!.lookupByIsbn(isbn);
      final candidates = metadata == null
          ? await widget.repository.lookupIsbn(isbn)
          : const <BookCandidate>[];
      if (!mounted) return;
      setState(() {
        _metadataResult = metadata;
        if (metadata?.retryableError != null) {
          _message = metadata!.retryableError;
        }
        if (metadata != null) {
          _candidate = BookCandidate(
            book: metadata.book,
            confidence: metadata.exactIsbnMatch
                ? (metadata.needsManualReview
                      ? BookMatchConfidence.medium
                      : BookMatchConfidence.high)
                : BookMatchConfidence.unknown,
            matchLabel: metadata.exactIsbnMatch
                ? (metadata.conflicts.isEmpty ? 'ISBN 联网精确匹配' : '资料需核对')
                : '已扫到书码 · 请补充书名',
            score: metadata.exactIsbnMatch ? 1 : 0,
          );
        } else {
          final exact = candidates.where(
            (item) => item.book.isbn13 == isbn || item.book.isbn10 == isbn,
          );
          _candidate =
              exact.firstOrNull ??
              candidates.firstOrNull ??
              _unresolvedCandidate(isbn);
        }
        _lookingUp = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _candidate = _unresolvedCandidate(isbn);
        _message = '书目服务暂时没响应，书码已经保留';
        _lookingUp = false;
      });
    }
  }

  BookCandidate _unresolvedCandidate(String isbn) => BookCandidate(
    book: BookRecord(
      title: '待确认书籍',
      isbn13: isbn,
      source: 'isbn_unresolved',
      sourceId: 'isbn-$isbn',
    ),
    confidence: BookMatchConfidence.unknown,
    matchLabel: '已扫到书码 · 请补充书名',
  );

  Future<void> _scanAgain() async {
    setState(() {
      _candidate = null;
      _metadataResult = null;
      _isbn = null;
      _message = null;
    });
    _resetDetectedIsbn();
    await _startScanner();
  }

  Future<void> _enterManually() async {
    if (!mounted || _manualInputOpen || _lookingUp) return;
    setState(() => _manualInputOpen = true);
    await _stopScanner();
    if (!mounted) return;
    String? value;
    try {
      value = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: double.infinity),
        builder: (_) => _ManualIsbnSheet(initialValue: _isbn ?? ''),
      );
    } finally {
      if (mounted) setState(() => _manualInputOpen = false);
    }
    _resetDetectedIsbn();
    if (!mounted) return;
    if (value != null) {
      await _lookup(value);
      return;
    }
    if (_candidate == null && !_lookingUp) {
      await _startScanner();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BookFlowTheme.camera,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final frameWidth = (width - 48).clamp(260.0, 420.0);
          final frameHeight = frameWidth * .48;
          final frameTop = (constraints.maxHeight * .29).clamp(150.0, 290.0);
          final scanWindow = Rect.fromLTWH(
            (width - frameWidth) / 2,
            frameTop,
            frameWidth,
            frameHeight,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _scannerController,
                      scanWindow: scanWindow,
                      tapToFocus: true,
                      onDetect: _onDetect,
                      errorBuilder: (_, _) =>
                          _ScannerError(onManual: _enterManually),
                      placeholderBuilder: (_) => const ColoredBox(
                        color: BookFlowTheme.camera,
                        child: SizedBox.shrink(),
                      ),
                    ),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _ScannerOverlayPainter(scanWindow),
                      ),
                    ),
                    if (_manualInputOpen)
                      Positioned.fill(
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: const ColoredBox(color: Color(0x80000000)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton.filledTonal(
                                tooltip: '返回',
                                onPressed: () => Navigator.of(context).pop(),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  backgroundColor: Colors.black45,
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              ValueListenableBuilder<MobileScannerState>(
                                valueListenable: _scannerController,
                                builder: (_, state, _) =>
                                    IconButton.filledTonal(
                                      tooltip: state.torchState == TorchState.on
                                          ? '关闭闪光灯'
                                          : '打开闪光灯',
                                      onPressed:
                                          state.torchState ==
                                              TorchState.unavailable
                                          ? null
                                          : _scannerController.toggleTorch,
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                        backgroundColor: Colors.black45,
                                        foregroundColor: Colors.white,
                                      ),
                                      icon: Icon(
                                        state.torchState == TorchState.on
                                            ? Icons.flash_on_rounded
                                            : Icons.flash_off_rounded,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          const Text(
                            '对准书背面的条形码',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _lookingUp
                                ? '条形码已识别，正在查询书名…'
                                : '把完整条形码放进框内，模糊时点按条码对焦',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _BottomPanel(
                      isbn: _isbn,
                      candidate: _candidate,
                      metadata: _metadataResult,
                      lookingUp: _lookingUp,
                      message: _message,
                      onConfirm: _candidate == null
                          ? null
                          : () => Navigator.of(context).pop(_candidate),
                      onAgain: _scanAgain,
                      onManual: _enterManually,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ManualIsbnSheet extends StatefulWidget {
  const _ManualIsbnSheet({required this.initialValue});

  final String initialValue;

  @override
  State<_ManualIsbnSheet> createState() => _ManualIsbnSheetState();
}

class _ManualIsbnSheetState extends State<_ManualIsbnSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _error;
  bool _keyboardVisible = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addObserver(this);
    final views = WidgetsBinding.instance.platformDispatcher.views;
    _keyboardVisible = views.isNotEmpty && views.first.viewInsets.bottom > 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final keyboardVisible =
        views.isNotEmpty && views.first.viewInsets.bottom > 0;
    final wasKeyboardVisible = _keyboardVisible;
    if (wasKeyboardVisible != keyboardVisible) {
      setState(() => _keyboardVisible = keyboardVisible);
    }
    if (wasKeyboardVisible && !keyboardVisible && _controller.text.isEmpty) {
      _focusNode.unfocus();
    }
  }

  void _submit() {
    final normalized = Isbn.normalize(_controller.text);
    if (normalized == null) {
      setState(() => _error = Isbn.explainInvalid(_controller.text));
      return;
    }
    _focusNode.unfocus();
    Navigator.of(context).pop(normalized);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_keyboardVisible,
    child: Material(
      color: BookFlowTheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD5D8DE),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text('手动输入 ISBN', style: BookFlowTheme.heading),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () {
                      _focusNode.unfocus();
                      Navigator.of(context).pop();
                    },
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    style: IconButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '支持 ISBN-10 或 ISBN-13，连字符可省略。',
                style: BookFlowTheme.caption,
              ),
              const SizedBox(height: 18),
              TextField(
                key: const Key('manual_isbn_field'),
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9Xx\-\s]')),
                ],
                decoration: InputDecoration(
                  hintText: '例如 9787508614007',
                  errorText: _error,
                  filled: true,
                  fillColor: BookFlowTheme.canvas,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD5D8DE)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFD5D8DE)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: BookFlowTheme.ink,
                      width: 1.3,
                    ),
                  ),
                ),
                onTapOutside: (_) => _focusNode.unfocus(),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: BookFlowTheme.ink,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('查询书籍'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.isbn,
    required this.candidate,
    required this.metadata,
    required this.lookingUp,
    required this.message,
    required this.onConfirm,
    required this.onAgain,
    required this.onManual,
  });

  final String? isbn;
  final BookCandidate? candidate;
  final BookMetadataLookupResult? metadata;
  final bool lookingUp;
  final String? message;
  final VoidCallback? onConfirm;
  final VoidCallback onAgain;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final item = candidate;
    return Semantics(
      liveRegion: lookingUp || message != null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(40, 48, 40, 72),
        decoration: BoxDecoration(
          color: BookFlowTheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: lookingUp
            ? const _LookupPlaceholder()
            : item == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    key: const Key('manual_isbn_button'),
                    onPressed: onManual,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                      minimumSize: const Size.fromHeight(56),
                      side: const BorderSide(color: BookFlowTheme.inkSecondary),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text(
                      '手动输入 ISBN',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message ?? '只读取条形码数字，不会保存封底照片',
                    textAlign: TextAlign.center,
                    style: BookFlowTheme.caption.copyWith(fontSize: 15),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ScannedBookCover(book: item.book),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.book.title == '待确认书籍'
                                  ? '条形码已读取'
                                  : item.book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: BookFlowTheme.ink,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 7),
                            BookCandidateVerification(candidate: item),
                            const SizedBox(height: 6),
                            Text(
                              item.book.metadataLabel.isNotEmpty
                                  ? item.book.metadataLabel
                                  : '书码 ${isbn ?? item.book.isbn13}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: BookFlowTheme.caption,
                            ),
                            if (message != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                message!,
                                style: const TextStyle(
                                  color: BookFlowTheme.danger,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            if (item.book.description.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                item.book.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: BookFlowTheme.caption,
                              ),
                            ],
                            if (item.book.tableOfContents.isNotEmpty ||
                                item.book.metadataSources.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 5,
                                children: [
                                  if (item.book.tableOfContents.isNotEmpty)
                                    _MetadataPill(
                                      icon: Icons.format_list_bulleted_rounded,
                                      label:
                                          '${item.book.tableOfContents.length} 项目录',
                                    ),
                                  for (final source
                                      in item.book.metadataSources)
                                    _MetadataPill(
                                      icon: Icons.verified_outlined,
                                      label: _providerLabel(source.provider),
                                    ),
                                ],
                              ),
                            ],
                            if (metadata?.conflicts.isNotEmpty == true) ...[
                              const SizedBox(height: 7),
                              const Text(
                                '部分资料来自不同书目来源，保存前请核对。',
                                style: TextStyle(
                                  color: BookFlowTheme.danger,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    key: const Key('confirm_scanned_book'),
                    style: FilledButton.styleFrom(
                      backgroundColor: BookFlowTheme.ink,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: onConfirm,
                    child: Text(item.book.title == '待确认书籍' ? '补充书名' : '确认是这本书'),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: onAgain,
                    style: TextButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Text('不是这个条形码，重新扫'),
                  ),
                  TextButton(
                    onPressed: onManual,
                    style: TextButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Text('手动输入或修改 ISBN'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LookupPlaceholder extends StatelessWidget {
  const _LookupPlaceholder();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 92,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('正在核对书目资料…', style: BookFlowTheme.body),
        SizedBox(height: 12),
        _StaticSkeleton(width: 154),
        SizedBox(height: 8),
        _StaticSkeleton(width: 226),
      ],
    ),
  );
}

class _StaticSkeleton extends StatelessWidget {
  const _StaticSkeleton({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 10,
    decoration: BoxDecoration(
      color: Color(0xFFF2F2F2),
      borderRadius: BorderRadius.circular(99),
    ),
  );
}

class _MetadataPill extends StatelessWidget {
  const _MetadataPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Color(0xFFF2F2F2),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: BookFlowTheme.inkSecondary),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
}

String _providerLabel(String provider) => switch (provider) {
  'glm_web_search' => '联网书目',
  'deepseek_search_fetch' => 'DeepSeek Search/Fetch',
  'tanshu_isbn' => '探数 ISBN',
  'tanshu_proxy' => '探数代理',
  'jisu_isbn' => '极速数据',
  'open_library' => 'Open Library',
  'weread' => '微信读书',
  _ => '书目来源',
};

class _ScannedBookCover extends StatelessWidget {
  const _ScannedBookCover({required this.book});

  final BookRecord book;

  @override
  Widget build(BuildContext context) {
    const fallback = ColoredBox(
      color: Color(0xFFF2F2F2),
      child: Center(
        child: Icon(Icons.menu_book_rounded, color: BookFlowTheme.inkSecondary),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        width: 46,
        height: 62,
        child: book.coverUrl.isEmpty
            ? fallback
            : Image.network(
                book.coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.onManual});

  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: BookFlowTheme.camera,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white,
                size: 42,
              ),
              const SizedBox(height: 12),
              const Text(
                '无法打开扫码相机',
                style: TextStyle(color: Colors.white, fontSize: 17),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onManual,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: BookFlowTheme.ink,
                  minimumSize: const Size(48, 48),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('手动输入数字'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  const _ScannerOverlayPainter(this.window);

  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final cutout = RRect.fromRectAndRadius(window, const Radius.circular(18));
    final overlay = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(cutout)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlay, Paint()..color = const Color(0x8F000000));

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const corner = 24.0;
    final r = window;
    for (final segment in <(Offset, Offset)>[
      (Offset(r.left, r.top + corner), Offset(r.left, r.top)),
      (Offset(r.left, r.top), Offset(r.left + corner, r.top)),
      (Offset(r.right - corner, r.top), Offset(r.right, r.top)),
      (Offset(r.right, r.top), Offset(r.right, r.top + corner)),
      (Offset(r.right, r.bottom - corner), Offset(r.right, r.bottom)),
      (Offset(r.right, r.bottom), Offset(r.right - corner, r.bottom)),
      (Offset(r.left + corner, r.bottom), Offset(r.left, r.bottom)),
      (Offset(r.left, r.bottom), Offset(r.left, r.bottom - corner)),
    ]) {
      canvas.drawLine(segment.$1, segment.$2, border);
    }
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.window != window;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
