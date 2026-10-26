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
