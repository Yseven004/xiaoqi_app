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

enum ToolAccessDecision { allow, confirm }

class ToolAccessPolicy {
  static ToolAccessDecision decide({
    required ToolEffect effect,
    bool hasExactUserGrant = false,
  }) =>
      hasExactUserGrant ||
          effect == ToolEffect.read ||
          effect == ToolEffect.workspace
      ? ToolAccessDecision.allow
      : ToolAccessDecision.confirm;
}
