import 'tool_access_policy.dart';
import 'tool_execution.dart';
import 'code_execution_service.dart' show SandboxExecutionError;
import 'release.dart';

/// One policy for installed scripts and generated code. The search switch is
/// not authority to mutate remote systems, and a domain grant is not a grant
/// for different code, files or arguments. All bindings come from the runtime.
class NetworkCallAuthorization {
  NetworkCallAuthorization({
    required this.execution,
    required this.domains,
    required String tool,
    required Map<String, dynamic> arguments,
    required Map<String, dynamic> authority,
  }) : approvalHash = ToolAccessPolicy.actionHash(
         connectionId: 'sandbox-network',
         tool: tool,
         requestIdentity: execution.requestIdentity,
         arguments: arguments,
         authority: {
           ...authority,
           'domains': domains,
           'runtime_release': releaseId,
           'runtime_contract': apiContractVersion,
         },
       ),
       scopeHash = ToolAccessPolicy.actionHash(
         connectionId: 'sandbox-network',
         tool: 'network-execution',
         requestIdentity: execution.requestIdentity,
         authority: const {},
       );

  final ToolExecution execution;
  final List<String> domains;
  final String approvalHash;
  final String scopeHash;
  String get operationId =>
      execution.operationIdentity('external', 'network:$approvalHash');

  Future<String> execute(Future<String> Function() invoke) async {
    if (decide() != ToolAccessDecision.allow) throw StateError('本次联网执行尚未获得授权');
    if (domains.isEmpty) return invoke();
    final result = await execution.authorizedCode(
      slot: 'network:$approvalHash',
      arguments: {'approval_hash': approvalHash},
      invoke: (_) async => {'output': await invoke()},
      effectsPossible: (error) => error is SandboxExecutionError,
    );
    if (result['ok'] == false) throw StateError(result['output'].toString());
    return result['output'].toString();
  }

  ToolAccessDecision decide({Object? resumed}) {
    execution.check('workspace');
    if (domains.isEmpty) return ToolAccessDecision.allow;
    if (resumed is Map &&
        resumed['approved'] is bool &&
        resumed['approval_hash'] == approvalHash &&
        resumed['domains'] is List &&
        _sameDomains(resumed['domains'] as List)) {
      execution.recordAuthorization(
        actionHash: approvalHash,
        scopeHash: scopeHash,
        approved: resumed['approved'] as bool,
      );
    }
    final grant = execution.authorization(
      actionHash: approvalHash,
      scopeHash: scopeHash,
    );
    return ToolAccessPolicy.decide(
      effect: ToolEffect.unknown,
      hasExactUserGrant: grant == true,
      hasUserDenial:
          grant == false || execution.isAuthorizationScopeDenied(scopeHash),
    );
  }

  bool _sameDomains(List raw) {
    final supplied = raw.whereType<String>().toSet();
    return supplied.length == raw.length &&
        supplied.length == domains.length &&
        supplied.containsAll(domains);
  }
}
