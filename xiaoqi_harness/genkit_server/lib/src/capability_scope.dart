/// Resolves scope from the visible snapshot ancestry, never another branch.
Map<String, dynamic> resolveCapabilityScope(
  Map<String, dynamic> current,
  Iterable<Map<String, dynamic>> ancestors,
) {
  Map<String, dynamic>? previous;
  for (final candidate in ancestors) {
    if (candidate['workflow_id'] != current['workflow_id']) continue;
    previous = candidate;
    break;
  }
  final operation =
      current['capability_scope_operation']?.toString() ??
      ((current['selected_capabilities'] as List? ?? const []).isNotEmpty ||
              (current['selected_mcp_connections'] as List? ?? const [])
                  .isNotEmpty
          ? 'replace'
          : 'inherit');
  if (!const {'inherit', 'replace', 'clear'}.contains(operation)) {
    throw const FormatException('能力选择操作无效');
  }
  final result = Map<String, dynamic>.from(current);
  final excluded = <String>{
    ...((previous?['excluded_capability_ids'] as List?) ?? const []).map(
      (id) => id.toString(),
    ),
  };
  String idOf(Object? item) =>
      (item is Map ? item['id'] : item)?.toString() ?? '';
  for (final key in ['selected_capabilities', 'selected_mcp_connections']) {
    // Old snapshots merged implicit activation into selection. Without the
    // v2 provenance marker, inherited execution preferences are ambiguous.
    final prior = previous?['capability_scope_schema'] == 2
        ? (previous?[key] as List?) ?? const []
        : const [];
    final next = operation == 'inherit'
        ? prior
        : operation == 'clear'
        ? const []
        : (current[key] as List?) ?? const [];
    if (operation != 'inherit') {
      final retained = next.map(idOf).toSet();
      excluded.addAll(prior.map(idOf).where((id) => !retained.contains(id)));
      excluded.removeAll(retained);
    }
    result[key] = next;
  }
  result['excluded_capability_ids'] = excluded
      .where((id) => id.isNotEmpty)
      .toList();
  result['capability_scope_operation'] = operation;
  if (operation == 'inherit' &&
      previous?['capability_scope_schema'] == 2 &&
      previous?['capability'] is Map &&
      (previous!['capability'] as Map)['type'] != 'action' &&
      current['capability'] == null) {
    result['capability'] = previous['capability'];
  }
  if (operation == 'clear') result.remove('capability');
  // Runtime activation is not a preference and must not leak into a new turn.
  result.remove('task_active_capabilities');
  result.remove('task_active_mcp_connections');
  result['capability_scope_schema'] = 2;
  return result;
}
