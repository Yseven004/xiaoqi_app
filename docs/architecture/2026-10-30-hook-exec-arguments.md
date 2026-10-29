# Hook exec-form arguments and root once semantics

## Source semantics and mapping

The [official command-hook reference](https://code.claude.com/docs/en/hooks#exec-form-and-shell-form),
checked 2026-10-30, distinguishes an omitted `args` field (shell command) from
an explicit argument array (direct executable). With an array, shell selection
is ignored, path placeholders are substituted as string data and each element
is a separate argument. The host previously rejected this valid declaration.

The root Hook adapter now implements that distinction in its isolated Node
launcher. Exec form calls the declared executable directly without shell
tokenization. Root/project placeholders resolve only to the isolated plugin
and task directories. Input JSON remains a separate UTF-8 stdin stream.
Arguments retain empty values, spaces, Unicode and shell metacharacters.
Unmapped plugin `user_config` placeholders fail explicitly instead of reading
API-host configuration. Other unmapped options retain their explicit status.

The parser validates the argument array per handler (at most 64 strings, 4096
UTF-8 bytes each, no NUL). One invalid handler does not hide healthy siblings.
The generated launcher still has the existing 64 KiB admission limit; no code,
network, task or process budget is raised. Timeout, cancellation, bounded
stdout and process-group cleanup use the same implementation as shell form.
The root catalog profile is now 2 so old installed source can be reindexed from
its same immutable bytes without selecting another version or running code.

The [common Hook fields](https://code.claude.com/docs/en/hooks#common-fields)
honor `once` only in skill frontmatter, removing a handler after success rather
than after failure/block/timeout. The current adapter handles root plugin
declarations, so it now ignores root `once` instead of rejecting the handler.
This does not implement or claim skill-scoped once registration: that lifecycle
adapter remains part of the full outstanding scope.

## Verification

The shared native/Docker launcher probe now includes direct Python execution
with a deliberately irrelevant PowerShell setting. It checks exact argv,
plugin/project placeholders, empty arguments, Unicode and unchanged JSON stdin.
Windows testing exposed Python's local-codepage stdin decoding; the isolated
child now explicitly uses `PYTHONIOENCODING=utf-8` and `PYTHONUTF8=1` so JSON
input bytes are interpreted consistently. Only child environment is adjusted.

All ten native Node/Bash/Python cases pass. The shared probe is 52522 bytes,
below the normal 64 KiB code limit. Twenty parser/catalog/runner tests pass,
including malformed-argument isolation and distinct root once invocations.
All five SDK parent/delegated-Agent regression cases pass separately, and
complete Dart static analysis reports no issues.
These local/native checks do not replace real Docker acceptance or deployment.
This change is not part of the main release currently being built/deployed.
