import 'store.dart';

List<Map<String, dynamic>> validateArtifactReferences(
  CloudStore store,
  String tenantId,
  Object? references,
) {
  if (references is! List) return const [];
  final result = <Map<String, dynamic>>[];
  for (final raw in references.whereType<Map>().take(20)) {
    final id = raw['id']?.toString() ?? '';
    final parts = id.split('/');
    if (parts.length != 2) continue;
    final trusted = visibleTaskArtifacts(store, tenantId, [
      parts.first,
    ]).where((a) => a['id'] == id).firstOrNull;
    if (trusted != null) result.add(trusted);
  }
  return result;
}

/// Resolves only server-owned artifact records belonging to visible ancestor
/// tasks. Remote URLs and arbitrary client filesystem paths are never trusted.
List<Map<String, dynamic>> visibleTaskArtifacts(
  CloudStore store,
  String tenantId,
  Iterable<String> visibleTaskIds,
) {
  final result = <String, Map<String, dynamic>>{};
  for (final taskId in visibleTaskIds.toSet().take(40)) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(taskId))
      continue;
    final task = store.get('task/$tenantId/$taskId')?.value;
    if (task == null) continue;
    for (final raw
        in (task['artifacts'] as List? ?? const []).whereType<Map>()) {
      final artifact = Map<String, dynamic>.from(raw);
      final id = artifact['id']?.toString();
      final objectKey = artifact['object_key']?.toString();
      if (id == null ||
          objectKey == null ||
          !objectKey.startsWith('tenants/$tenantId/tasks/$taskId/artifacts/'))
        continue;
      result['$taskId/$id'] = {
        ...artifact,
        'id': '$taskId/$id',
        'task_id': taskId,
      };
    }
  }
  return result.values.toList().reversed.take(20).toList();
}
