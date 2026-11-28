import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/v0_9/basic_catalog.dart';
import 'package:flutter/material.dart';

import '../models/reading_companion_evidence.dart';

final _catalog = basicCatalog();
const _version = A2uiProtocolVersion.v0_9;
const _openAction = 'open_reading_source';

class ReadingCompanionSources extends StatefulWidget {
  const ReadingCompanionSources({
    super.key,
    required this.evidence,
    required this.onOpen,
  });

  final List<ReadingCompanionEvidence> evidence;
  final ValueChanged<ReadingCompanionEvidence> onOpen;

  @override
  State<ReadingCompanionSources> createState() =>
      _ReadingCompanionSourcesState();
}

class _ReadingCompanionSourcesState extends State<ReadingCompanionSources> {
  final _processor = MessageProcessor<ComponentImplementation>(
    catalogs: [_catalog],
    defaultVersion: _version,
  );
  late final Subscription _actionSubscription;
  List<ReadingCompanionEvidence> _sources = const [];
  SurfaceModel<ComponentImplementation>? _surface;
  int _surfaceGeneration = 0;

  @override
  void initState() {
    super.initState();
    _actionSubscription = _processor.model.onAction.subscribe(_onAction);
    _updateSources();
  }

  @override
  void didUpdateWidget(covariant ReadingCompanionSources oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSources();
  }

  @override
  void dispose() {
    _actionSubscription.unsubscribe();
    _processor.dispose();
    super.dispose();
  }

  void _updateSources() {
    final pdfPages = <(String, int)>{};
    final sources = widget.evidence
        .where((entry) {
          if (!entry.showsAsA2ui) return false;
          final page = entry.page;
          return page == null || pdfPages.add((entry.sourceVersion, page));
        })
        .toList(growable: false);
    final unchanged =
        _sources.length == sources.length &&
        sources.asMap().entries.every((entry) {
          final previous = _sources[entry.key];
          return previous.identity == entry.value.identity &&
              previous.href == entry.value.href &&
              previous.label == entry.value.label;
        });
    if (unchanged) return;
    _sources = sources;
    if (_surface case final previous?) {
      _processor.processMessages([
        DeleteSurfaceMessage(
          version: _version.jsonValue,
          surfaceId: previous.id,
        ).toJson(),
      ]);
      _surface = null;
    }
    if (sources.isEmpty) return;

    final surfaceId = 'companion-sources-${++_surfaceGeneration}';
    _processor.processMessages([
      CreateSurfaceMessage(
        version: _version.jsonValue,
        surfaceId: surfaceId,
        catalogId: _catalog.id,
      ).toJson(),
      UpdateComponentsMessage(
        version: _version.jsonValue,
        surfaceId: surfaceId,
        components: [
          {
            'id': 'root',
            'component': 'Column',
            'align': 'start',
            'children': [
              for (final (index, _) in sources.indexed) 'source-$index',
            ],
          },
          for (final (index, entry) in sources.indexed) ...[
            {
              'id': 'source-$index',
              'component': 'Button',
              'variant': 'borderless',
              'child': 'label-$index',
              'action': {
                'event': {
                  'name': _openAction,
                  'context': {'row': index},
                },
              },
            },
            {
              'id': 'label-$index',
              'component': 'Text',
              'text': '查看原文 · ${entry.label}',
            },
          ],
        ],
      ).toJson(),
    ]);
    _surface = _processor.model.getSurface(surfaceId);
  }

  void _onAction(A2uiRendererAction action) {
    final row = action.context['row'];
    if (!mounted ||
        action.name != _openAction ||
        action.surfaceId != _surface?.id ||
        row is! int ||
        row < 0 ||
        row >= _sources.length ||
        action.sourceComponentId != 'source-$row') {
      return;
    }
    widget.onOpen(_sources[row]);
  }

  @override
  Widget build(BuildContext context) => switch (_surface) {
    final surface? => A2uiSurface(key: ObjectKey(surface), surface: surface),
    null => const SizedBox.shrink(),
  };
}
