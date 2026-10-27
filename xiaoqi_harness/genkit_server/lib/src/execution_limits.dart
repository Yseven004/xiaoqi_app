/// Server-owned resource budgets, independent of a model's delivery plan.
/// Attempts count even when execution fails; resuming a task retains its budget.
class ExecutionLimits {
  const ExecutionLimits({
    this.toolOperations = 128,
    this.scriptExecutions = 64,
    this.modelTurns = 64,
  }) : assert(toolOperations > 0),
       assert(scriptExecutions > 0),
       assert(modelTurns > 0);

  final int toolOperations;
  final int scriptExecutions;
  final int modelTurns;
}

class ExecutionBudgetExceeded extends StateError {
  ExecutionBudgetExceeded(super.message);
}

/// IO reservations and direct code attempts are disjoint runtime entries.
/// Includes earlier request scopes in this task, including failed attempts.
/// A new user turn gets a new task ID; steering/resume keeps the existing ID.
int taskToolOperationsUsed(Map<String, dynamic> task) {
  final operations = (task['scope_operations'] as Map? ?? const {}).values
      .whereType<Map>()
      .where((operation) => operation['effect'] != 'image')
      .length;
  return operations + (task['code_execution_runs'] as num? ?? 0).toInt();
}
