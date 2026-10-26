const releaseId = '2026-10-26-agent-tools-1';
const apiContractVersion = '23';
String contractMismatch(String? client) =>
    '客户端接口版本 ${client ?? "未提供"} 与服务端 $apiContractVersion 不一致（$releaseId），请重新构建客户端或部署匹配的服务端。';
