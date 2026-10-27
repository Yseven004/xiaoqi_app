import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Effects come from deployment-owned policy or an isolated runtime, never
/// from tool names, remote annotations or the tool call's own arguments.
enum ToolEffect {
  read,
  workspace,
  write,
  send,
  delete,
  payment,
  unknown;

  static ToolEffect parse(Object? value) =>
      values.where((effect) => effect.name == value).firstOrNull ?? unknown;
}

enum ToolAccessDecision { allow, confirm, deny, unavailable }

class ToolAccessPolicy {
  static ToolAccessDecision decide({
    required ToolEffect effect,
    bool hasExactUserGrant = false,
    bool hasUserDenial = false,
    bool available = true,
  }) {
    if (!available) return ToolAccessDecision.unavailable;
    if (hasUserDenial) return ToolAccessDecision.deny;
    return hasExactUserGrant ||
            effect == ToolEffect.read ||
            effect == ToolEffect.workspace
        ? ToolAccessDecision.allow
        : ToolAccessDecision.confirm;
  }

  /// Arguments and trusted authority occupy separate slots: tool parameters
  /// cannot overwrite scope metadata by choosing a reserved-looking name.
  static String actionHash({
    required String connectionId,
    required String tool,
    required String requestIdentity,
    required Map<String, dynamic> authority,
    Map<String, dynamic>? arguments,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical([
              connectionId,
              tool,
              requestIdentity,
              authority,
              arguments,
            ]),
          ),
        ),
      )
      .toString();

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
