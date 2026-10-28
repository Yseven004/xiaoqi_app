import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'turn_contract.dart';

/// Completion requirements, never tool authorization. Tool results cannot
/// withdraw requirements; only a contract derived from the current user can.
class ScopeRequirements {
  final _entries = <String, Map<String, dynamic>>{};
  static String key(String kind, Object identity) =>
      'requirement-${sha256.convert(utf8.encode(jsonEncode([kind, identity]))).toString().substring(0, 24)}';
  void add(
    String id,
    String name, {
    String? parent,
    Iterable<String> parents = const [],
    String? failure,
    bool selection = false,
    String? version,
  }) {
    _entries[id] = {
      'id': id,
      'name': name,
      'status': failure == null ? 'available' : 'unavailable',
      if (parent != null) 'parent_requirement_id': parent,
      if (parents.isNotEmpty) 'parent_requirement_ids': parents.toList(),
      if (failure != null) 'failure': failure,
      if (selection) 'selected': true,
      if (version != null) 'version_id': version,
    };
  }

  void fail(String id, String message) {
    final entry = _entries[id];
    if (entry == null) throw StateError('完成条件不存在');
    _entries[id] = {...entry, 'status': 'unavailable', 'failure': message};
  }

  bool contains(String id) => _entries.containsKey(id);
  List<Map<String, dynamic>> get catalog =>
      _entries.values.map((e) => Map<String, dynamic>.from(e)).toList();
  bool required(TurnContract scope, String id) {
    if (!_entries.containsKey(id) || scope.withdrawnRequirementIds.contains(id))
      return false;
    final parent = _entries[id]?['parent_requirement_id'];
    final parents = [
      if (parent != null) parent.toString(),
      ...(_entries[id]?['parent_requirement_ids'] as List? ?? const [])
          .cast<String>(),
    ];
    return parents.isEmpty ||
        parents.any((p) => !_entries.containsKey(p) || required(scope, p));
  }

  bool hasSelected(TurnContract scope) => _entries.values.any(
    (e) => e['selected'] == true && required(scope, e['id'].toString()),
  );
  List<String> missing(TurnContract scope) => [
    for (final e in _entries.values)
      if (e['status'] == 'unavailable' && required(scope, e['id'].toString()))
        e['failure'].toString(),
  ];
}
