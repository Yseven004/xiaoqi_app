# 小栖 MCP 已验证清单

服务端通过 `XIAOQI_MCP_CATALOG_JSON` 读取随发布更新的清单。客户端只显示清单内容，不接受普通用户手填服务地址、命令或令牌。

每一项至少包含：

```json
{
  "id": "example",
  "name": "Example MCP",
  "description": "公开服务说明",
  "url": "https://mcp.example.com/mcp",
  "version": "1.0.0",
  "runtime": "remote_https",
  "auth_mode": "none",
  "status": "verified",
  "repository": "https://github.com/example/mcp-server"
}
```

网页登录工具将 `auth_mode` 设为 `oauth`，并提供 `authorize_url`、`token_url`、`client_id` 与可选 `scopes`。应用只把 OAuth 状态保存到服务端，授权令牌按租户加密保存，不返回客户端或日志。

`runtime` 支持 `remote_https`。`sandbox_npm` 与 `sandbox_pypi` 已保留为清单协议值，但在沙箱桥接验证完成前必须标为 `unsupported`，不会出现在默认推荐列表；GitHub 项目网页本身也不能填入 `url`。

发布前逐项记录来源、固定版本、许可证和验证日期。只有完成 MCP 握手与工具发现后，连接才会进入“已就绪”。无效的旧连接会显示“暂未支持”，用户可从推荐清单重新安装。
