# 配对码 Auth 报错：根因与具体修复

日期：2026-10-04。

流程状态更新（2026-10-05）：用户已决定使用个人邮箱自动授权，不再要求配对。本文前面的配对码步骤是旧流程的历史排障记录；不要按旧步骤运行配对命令。之前生成的 `*-auth-fix.zip` 只修复存储 SDK 参数，不含新的邮箱登录路由，不能作为本次登录功能的部署包。

## 结论

此次报错的直接根因是应用代码调用 OSS SDK 的参数错误。并非通过更换管理员 Token、修改 PowerShell 命令或重复上传现有 ZIP 能解决。

当前源码 `xiaoqi_harness/capabilities/storage.py` 原第 73 行调用：

```python
oss2.Auth(access_key_id, access_key_secret, security_token)
```

包内 OSS SDK 的构造函数实际为 `Auth(self, access_key_id, access_key_secret)`。Python 将 self 也计入参数数量，所以报错为：

```text
Auth.__init__() takes 3 positional arguments but 4 were given
```

第三个参数即使是 None，也依然是多传一个参数。临时凭证应使用 `StsAuth`。

## 证据与此前修复遗漏

1. 检查了 deploy 目录全部 9 个 ZIP；API 的原版、fixed、linux-py310、v2、v3，以及 Worker 的原版、linux-py310、v2、v3，均包含同一行错误调用。所有包内的 Auth 都只接受两个显式参数，StsAuth 接受 Token。换这些包不会消除此错误。
2. 从 API v3 ZIP 提取真实 Auth 构造签名，保留签名、替换函数体为空操作，分别传入 None 与模拟 Token，均精确复现截图报错。这是参数契约复现，不是完整 SDK 云服务集成测试。
3. 调用链是 `POST /v1/pairing-codes → create_pairing_code → store() → CloudStore() → oss2.Auth(...)`。存储初始化先构造 Tablestore 客户端，再构造 OSS 客户端；报错发生在配对码写入之前。
4. 按当前路由代码，管理员 Token 校验在存储初始化之前；错误 Token 应返回 401。截图的 Auth 异常与已通过管理员校验、随后初始化失败相符，不支持继续把管理员 Token 当作此次根因。尚未读取线上代码，不能据此断言线上所有配置正确。
5. 原配对码单测使用内存存储，绕过 CloudStore 初始化；`/health` 也仅返回固定 ok，不能证明 OSS/Tablestore 可用。

官方来源：[阿里云 OSS Python SDK auth.py](https://github.com/aliyun/aliyun-oss-python-sdk/blob/master/oss2/auth.py)。本次也直接检查了部署包内 SDK，结论不依赖上游 master 的版本变化。项目 requirements 将 oss2 固定为 2.19.1。

## 已完成的本地修复

共享存储初始化修改为：

```python
self._bucket = oss2.Bucket(
    oss2.StsAuth(access_key_id, access_key_secret, security_token)
    if security_token
    else oss2.Auth(access_key_id, access_key_secret),
    os.environ["OSS_ENDPOINT"],
    os.environ["OSS_BUCKET"],
    region=os.environ["OSS_REGION"],
)
```

同时新增 `xiaoqi_harness/capabilities/tests/test_storage_auth.py`，使用与 SDK 参数契约一致的替身，检查无 Token、空 Token、存在 Token 三种情况，并检查 Tablestore 仍收到原 Token。

本地执行（在 xiaoqi_harness 目录）：

```powershell
python -m unittest capabilities.tests.test_storage_auth
```

结果：1 个测试、3 个子场景通过。未安装或更换本机 SDK 依赖，没有使用真实密钥，没有向云存储写入数据。

## 具体云端修复步骤

1. 在阿里云函数计算中打开截图 URL 实际绑定的 API 函数，进入代码编辑，打开 `capabilities/storage.py`，将 Bucket 第一个参数由旧的单行 Auth 调用改为上面的三行条件表达式。其余参数保持原样。保存并部署；不要仅保存编辑器内容。
2. 对 Worker 函数的同名文件做相同修改并部署。两者共享此错误；只改 API 会留下 Worker 初始化失败。如果控制台无法在线编辑，则基于当前已部署包仅替换此源码文件后重新部署。不要重新上传本地现有 9 个旧 ZIP，它们尚未重打包。
3. 核对截图中的 HTTP 域名确实指向刚更新的函数；若配置了固定版本或别名，确认其已指向修复版本。重新打开该版本文件，确认存在 `oss2.StsAuth` 和双参数 `oss2.Auth`。这一步用于排除“改了文件，但请求仍打到旧版本”。
4. 以上是旧配对流程的历史验收方法。新流程部署后应配置 QQ SMTP 与唯一允许登录的邮箱，调用邮箱验证码登录，再核对个人账号首页任务；`/health` 的 `release_id` 用于确认实际部署版本，单独返回 ok 不算登录验收。

不需要为此修改 CAPABILITY_ADMIN_TOKEN，也不要删除临时凭证的 Security Token 来绕过问题。临时凭证的 ID、Secret、Token 必须配套；本次修改保留 Token 传递。

## 验证边界与回滚

- 代码实现完成；离线参数路由回归通过。
- 线上部署未执行，未获取线上 traceback 或运行代码指纹；云端配对、OSS/Tablestore 权限和真实读写待验证。
- 未修改已有 ZIP，避免将旧包误称为修复产物。
- 本次没有数据结构变化或迁移。部署前保留现有函数版本；若出现与此次修改有关的新回归，可恢复先前版本，但先前版本本身仍包含已确认的 Auth 参数错误。

## 本次执行进度

- 已在本地共享文件 `xiaoqi_harness/capabilities/storage.py` 修复。API 和 Worker 都使用它。
- 已执行离线认证构造参数回归：无 Token、空 Token、有效格式 Token 三种路由通过。
- 已尝试只读列出杭州 FC 函数，阿里云 CLI 返回 `InvalidAccessKeyId.NotFound`。因此尚不能确认函数名、上传修复包或部署；没有进行任何云端写操作。
- 本地现存 API/Worker ZIP 仍是旧版本，不能直接上传。当前可用 CLI 凭证也不能用于更新它们。

## 部署包已生成

根据用户提供的 FC 函数列表，目标函数为 API `xiaoqi_capability_api` 和 Worker `xiaoqi_sandbox`。这两个函数分别对应仓库的 Linux/Python 3.10 v3 部署包。

从两个 v3 包各自只替换 `capabilities/storage.py` 内的错误 Auth 调用生成了独立修复包，保留包内其他代码和依赖：

- API：`xiaoqi_harness/deploy/xiaoqi-capability-api-auth-fix.zip`，SHA-256 `77fdbd0dc25520b5d260b9a1fb04f6a423a3a9b542150d64246a0d6181bfdc99`。
- Worker：`xiaoqi_harness/deploy/xiaoqi-agent-worker-auth-fix.zip`，SHA-256 `73d8e594ff16f74bd364b899cbc438a5cdeb1d7c3f41bb4ef3e77b5980916b3f`。

两个 ZIP 均已重新打开验证完整性，确认只包含一次目标源码替换，并且压缩包内 Auth 调用已变为：有 Token 用 `StsAuth`、无 Token 用双参数 `Auth`。

用户刚才新建并完成 `xiaoqi-repair` OAuth CLI profile。阿里云 CLI `fc` 命令与 OAuth 有已公开问题（`aliyun/aliyun-cli#1271`），所以部署改走 FC 控制台。云端修改尚未执行。当前在 FC 3.0 的杭州函数列表，下一步应先打开 `xiaoqi_capability_api`，上传 API 修复包并保留函数现有运行时配置，然后对 `xiaoqi_sandbox` 做同样操作。部署后必须用原配对码请求确认 API 返回 HTTP 201；仅仅 `/health` 成功不算验收。
