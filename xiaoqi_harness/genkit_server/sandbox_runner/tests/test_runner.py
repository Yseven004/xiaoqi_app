from __future__ import annotations

import base64
import io
import json
import socket
import tarfile
import unittest
from unittest.mock import Mock, patch
from docker.types import ContainerConfig

import server
from stdio_channel import StdioChannel


class RunnerValidationTests(unittest.TestCase):
    def test_installer_export_profile_is_carried_across_container_restart(self):
        client, container, volume = Mock(), Mock(), Mock()
        volume.name = 'installer-export-profile'
        client.volumes.create.return_value = volume
        client.containers.create.return_value = container
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'exited', 'Running': False, 'ExitCode': 0}}
        with (patch.object(server, '_get_client', return_value=client),
              patch.object(server, '_decode_logs', return_value=''),
              patch.object(server, '_safe_artifacts', return_value=[]) as export):
            server._run_sandbox({'task_id':'installer-profile', 'execution_id':'a'*32,
                'execution_profile':'dependency_build', 'language':'python', 'code':'pass'}, Mock())
            export.assert_called_once_with(container, dependency_build=True)
        self.assertEqual(client.containers.create.call_args.kwargs['labels']['com.xiaoqi.execution-profile'], 'dependency_build')

    def test_only_installer_dependency_archive_gets_twenty_mb_single_file_limit(self):
        payload = b'x' * (11 * 1024 * 1024)
        def container_for(name, data=payload):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                entry = tarfile.TarInfo('output/' + name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
            container = Mock()
            container.get_archive.return_value = ([stream.getvalue()], {})
            return container
        result = server._execution_artifacts(container_for('dependencies.zip'), 'dependency_build')
        self.assertEqual(base64.b64decode(result[0]['base64']), payload)
        for profile, name in [('code', 'dependencies.zip'), ('plugin_hook', 'dependencies.zip'),
                              ('dependency_build', 'other.zip')]:
            with self.subTest(profile=profile, name=name), self.assertRaises(server.RequestError):
                server._execution_artifacts(container_for(name), profile)
        with self.assertRaises(server.RequestError):
            server._execution_artifacts(container_for('dependencies.zip', b'x' * (20 * 1024 * 1024 + 1)), 'dependency_build')

    def test_legacy_shebang_launchability_changes_only_task_source_modes(self):
        script = b'#!/bin/sh\nprintf "%s" "$1"\n'
        files = [('skill/scripts/legacy', script), ('materials/upload.sh', script),
                 ('skill/node_modules/tool/cli', script), ('skill/.xiaoqi/python/bin/tool', script),
                 ('skill/.git/hooks/post-checkout', script), ('skill/handbook/example.sh', script),
                 ('skill/notes.txt', b'example\n#!/bin/sh\n')]
        with tarfile.open(fileobj=io.BytesIO(server._make_archive(files))) as archive:
            source = archive.getmember('skill/scripts/legacy')
            self.assertEqual(source.mode, 0o755)
            self.assertEqual((source.uid, source.gid), (10001, 10001))
            self.assertEqual(archive.extractfile(source).read(), script)
            for name, _ in files[1:]:
                self.assertEqual(archive.getmember(name).mode, 0o644)
        self.assertEqual(files[0][1], script)

    def test_recorded_source_modes_remain_authoritative_over_legacy_inference(self):
        script = b'#!/bin/sh\nexit 0\n'
        files = [('skill/scripts/resource.sh', script), ('skill/scripts/declared', b'original binary bytes'),
                 ('skill/.xiaoqi-source-executables.json', json.dumps({'schema': 1, 'executables': ['scripts/declared']}).encode())]
        with tarfile.open(fileobj=io.BytesIO(server._make_archive(files))) as archive:
            self.assertEqual(archive.getmember('skill/scripts/resource.sh').mode, 0o644)
            self.assertEqual(archive.getmember('skill/scripts/declared').mode, 0o755)
        files[-1] = ('skill/.xiaoqi-source-executables.json', b'{invalid')
        with self.assertRaises(server.RequestError):
            server._make_archive(files)

    def test_failed_script_preserves_validated_partial_artifacts_and_cleanup(self):
        client = Mock()
        volume = Mock()
        volume.name = 'xq-code-volume'
        client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'exited', 'ExitCode': 7, 'Running': False}}
        client.containers.create.return_value = container
        partial = [{'name': 'partial.txt', 'media_type': 'text/plain', 'base64': 'cGFydGlhbA=='}]
        with patch.object(server, '_get_client', return_value=client), patch.object(server, '_decode_logs', return_value=''), patch.object(server, '_safe_artifacts', return_value=partial) as export:
            result = server._run_sandbox({'task_id': 'failed-task', 'language': 'shell', 'code': 'exit 7'}, Mock())
        self.assertFalse(result['ok'])
        self.assertIn('7', result['error'])
        self.assertEqual(result['artifacts'], partial)
        export.assert_called_once_with(container)
        self.assertFalse(result['cleanup_pending'])
        container.remove.assert_called_once_with(force=True, v=True)
        volume.remove.assert_called_once_with(force=True)

    def test_shell_arguments_and_installed_script_are_not_reparsed(self):
        arguments = ['value with spaces', '', 'literal; $(not-a-host-command)']
        files, language, args, scripts = server._request_files({'code':'printf "%s" "$1"','language':'shell','arguments':arguments})
        self.assertIn('main.sh', dict(files))
        self.assertEqual(server._command(language,args,scripts),['bash','--noprofile','--norc','/workspace/main.sh',*arguments])
        files, language, args, scripts = server._request_files({'code':'placeholder','language':'shell','arguments':arguments,
            'script_path':'scripts/check.sh','skill_files':{'scripts/check.sh':base64.b64encode(b'printf "%s" "$1"').decode()}})
        self.assertEqual(server._command(language,args,scripts),['bash','--noprofile','--norc','/workspace/skill/scripts/check.sh',*arguments])

    def test_installed_script_uses_file_budget_not_inline_code_limit(self):
        source = b'# installed script\n' + b'#' * (70 * 1024)
        files, language, args, scripts = server._request_files({'language':'shell',
            'script_path':'scripts/large.sh','skill_files':{'scripts/large.sh':base64.b64encode(source).decode()}})
        self.assertEqual(dict(files)['skill/scripts/large.sh'],source)
        self.assertEqual(scripts,['scripts/large.sh'])
    def test_stdio_uses_isolated_container_and_literal_arguments(self):
        client = Mock()
        volume = Mock()
        volume.name = 'xq-code-volume'
        client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {'State':{'Status':'exited','ExitCode':0,'Running':False}}
        client.containers.create.return_value = container
        raw, peer = socket.socketpair()
        self.addCleanup(peer.close)
        attached = Mock()
        attached._sock = raw
        reader = raw.makefile('rb')
        attached._response.raw._fp.fp = reader
        attached._response.close.side_effect = reader.close
        container.attach_socket.return_value = attached
        channel = StdioChannel()
        argv = ['node','/workspace/skill/server.js','literal; $(not-a-host-command)']
        with patch.object(server, '_get_client', return_value=client), patch.object(server, '_decode_logs', return_value=''), patch.object(server, '_safe_artifacts', return_value=[]):
            result = server._run_sandbox({'task_id':'stdio-task','command':argv,'environment':{'PLUGIN_SETTING':'value'}}, Mock(), channel)
        self.assertTrue(result['ok'])
        options = client.containers.create.call_args.kwargs
        self.assertEqual(options['command'], argv)
        self.assertTrue(options['stdin_open'])
        # Assert docker-py's actual Engine API encoding, not only our kwargs.
        config = ContainerConfig(version='1.45', image='fixture', command=argv,
                                 stdin_open=options['stdin_open'], detach=options['detach'])
        self.assertTrue(config['OpenStdin'])
        self.assertFalse(config['StdinOnce'])
        original_default = ContainerConfig(version='1.45', image='fixture', command=argv, stdin_open=True)
        self.assertTrue(original_default['StdinOnce'])
        self.assertEqual(options['network'], 'none')
        self.assertEqual(options['mem_limit'], '256m')
        self.assertEqual(options['user'], '10001:10001')
        self.assertEqual(options['cap_drop'], ['ALL'])
        self.assertNotIn('SANDBOX_RUNNER_TOKEN', options['environment'])
        self.assertEqual(options['environment']['PLUGIN_SETTING'], 'value')
        container.remove.assert_called_once_with(force=True, v=True)
        volume.remove.assert_called_once_with(force=True)

    def test_disable_task_network_only_kills_owned_proxy_for_task(self) -> None:
        client = Mock()
        proxy = Mock()
        proxy.name = "xq-code-proxy-session"
        proxy.attrs = {"State": {"Running": True}}
        client.containers.list.return_value = [proxy]

        with patch.object(server, "_get_client", return_value=client):
            result = server._disable_task_network("task-1")

        self.assertEqual(result["network"], "off")
        self.assertEqual(result["terminated_proxies"], 1)
        client.containers.list.assert_called_once_with(
            all=True,
            filters={
                "label": [
                    f"{server.OWNER_LABEL}=true",
                    "com.xiaoqi.task-id=task-1",
                    "com.xiaoqi.role=network-proxy",
                ],
            },
        )
        proxy.kill.assert_called_once_with()

    def test_disabled_network_prevents_proxy_creation_for_queued_task(self) -> None:
        task_id = "task-disabled-before-run"
        token = server._network_token(task_id)
        control_client = Mock()
        control_client.containers.list.return_value = []
        with patch.object(server, "_get_client", return_value=control_client):
            server._disable_task_network(task_id)

        execution_client = Mock()
        volume = Mock()
        volume.name = "xq-code-volume"
        execution_client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {"State": {"Status": "exited", "ExitCode": 0}}
        execution_client.containers.create.return_value = container
        with (
            patch.object(server, "_get_client", return_value=execution_client),
            patch.object(server, "_decode_logs", return_value=""),
            patch.object(server, "_safe_artifacts", return_value=[]),
        ):
            result = server._run_sandbox(
                {
                    "task_id": task_id,
                    "code": "print('hello')",
                    "language": "python",
                    "authorized_domains": ["example.com"],
                    "network_token": token,
                },
                Mock(),
            )

        self.assertFalse(result["ok"])
        self.assertIn('联网授权已撤销', result['error'])
        execution_client.containers.create.assert_not_called()
        # Cleanup of a denied/offline execution must not resurrect this token.
        self.assertFalse(server._network_token_is_current(task_id, token))

    def test_network_reauthorization_accepts_new_token_without_waiting(self):
        task_id = 'network-toggle-task'
        old_token = server._network_token(task_id)
        client = Mock()
        client.containers.list.return_value = []
        with patch.object(server, '_get_client', return_value=client):
            server._disable_task_network(task_id)
        new_token = server._network_token(task_id)
        self.assertFalse(server._network_token_is_current(task_id, old_token))
        self.assertTrue(server._network_token_is_current(task_id, new_token))
        self.assertFalse(server._network_token_is_current('another-task', new_token))
        self.assertFalse(server._network_token_is_current(task_id, new_token + 'a'))
        with patch.object(server, '_network_token_key', b'new-runner-key'):
            self.assertFalse(server._network_token_is_current(task_id, new_token))
        issued = int(new_token.split('.')[0])
        with patch.object(server.time, 'monotonic_ns', return_value=issued + (server.NETWORK_TOKEN_SECONDS + 1) * 1_000_000_000):
            self.assertFalse(server._network_token_is_current(task_id, new_token))

    def test_delayed_off_preserves_new_revision_and_cannot_lower_revocation(self):
        task_id = 'network-control-reordered'
        old = server._network_token(task_id, 0)
        fresh = server._network_token(task_id, 2)
        client = Mock()
        proxies = []
        for revision in (0, 2):
            proxy = Mock()
            proxy.name = f'xq-code-proxy-revision-{revision}'
            proxy.attrs = {'State': {'Running': True}, 'Config': {
                'Labels': {'com.xiaoqi.network-revision': str(revision)}}}
            proxies.append(proxy)
        client.containers.list.return_value = proxies
        with patch.object(server, '_get_client', return_value=client):
            result = server._disable_task_network(task_id, 1)
            self.assertEqual(result['terminated_proxies'], 1)
            proxies[0].kill.assert_called_once_with()
            proxies[1].kill.assert_not_called()
            self.assertFalse(server._network_token_is_current(task_id, old, 0))
            self.assertTrue(server._network_token_is_current(task_id, fresh, 2))
            # Revision is cryptographically bound: changing it cannot lift a ban.
            self.assertFalse(server._network_token_is_current(task_id, old, 2))
            server._disable_task_network(task_id, 3)
            proxies[1].kill.assert_called_once_with()
            server._disable_task_network(task_id, 1)
            self.assertFalse(server._network_token_is_current(
                task_id, server._network_token(task_id, 2), 2))

    def test_network_revision_rejects_untrusted_types(self):
        for revision in (None, True, -1, 1.5, '2', 9007199254740992):
            with self.subTest(revision=revision), self.assertRaises(server.RequestError):
                server._network_token('bad-network-revision', revision)

    def test_fresh_network_token_actually_starts_proxy_after_revocation(self):
        task_id = 'fresh-network-task'
        client = Mock()
        client.containers.list.return_value = []
        with patch.object(server, '_get_client', return_value=client):
            server._disable_task_network(task_id)
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'exited', 'ExitCode': 0, 'Running': False}}
        proxy = Mock()
        proxy.attrs = {'State': {'Running': False}}
        client.containers.create.side_effect = [proxy, container]
        with (patch.object(server, '_get_client', return_value=client),
              patch.object(server, '_wait_for_proxy', return_value=True),
              patch.object(server, '_decode_logs', return_value=''),
              patch.object(server, '_safe_artifacts', return_value=[])):
            result = server._run_sandbox({'task_id': task_id, 'code': 'pass', 'language': 'python',
                'authorized_domains': ['example.com'], 'network_token': server._network_token(task_id)}, Mock())
        self.assertTrue(result['ok'], result['error'])
        proxy.start.assert_called_once()
        self.assertEqual(client.containers.create.call_count, 2)

    def test_task_network_has_no_host_bridge_gateway(self) -> None:
        client = Mock()
        labels = {server.OWNER_LABEL: "true"}

        server._create_task_network(client, "task-network", labels)

        client.networks.create.assert_called_once_with(
            name="task-network",
            driver="bridge",
            internal=True,
            options={"com.docker.network.bridge.gateway_mode_ipv4": "isolated"},
            labels=labels,
        )

    def test_docker_log_frames_keep_only_requested_stream(self) -> None:
        frame = lambda kind, data: bytes([kind, 0, 0, 0]) + len(data).to_bytes(4, "big") + data
        container = Mock()
        container.logs.return_value = frame(1, b"out") + frame(2, b"err")

        self.assertEqual(server._decode_logs(container, "stdout"), "out")
        self.assertEqual(server._decode_logs(container, "stderr"), "err")
        container.logs.assert_called_with(stdout=False, stderr=True, tail=10000)

    def test_plain_docker_logs_are_preserved(self) -> None:
        container = Mock()
        container.logs.return_value = b"plain output"

        self.assertEqual(server._decode_logs(container, "stdout"), "plain output")

    def test_domain_list_is_normalized_and_bounded(self) -> None:
        self.assertEqual(server._normalize_domains(["Example.com.", "api.example.com"]), ["api.example.com", "example.com"])
        with self.assertRaises(server.RequestError):
            server._normalize_domains(["*.example.com"])
        with self.assertRaises(server.RequestError):
            server._normalize_domains([f"x{index}.example.com" for index in range(11)])

    def test_workspace_paths_reject_traversal(self) -> None:
        self.assertEqual(server._safe_relative("scripts/task.py"), "scripts/task.py")
        for value in ("../escape", "scripts/../../escape", "/absolute", "scripts\\escape", ""):
            with self.subTest(value=value), self.assertRaises(server.RequestError):
                server._safe_relative(value)

    def test_code_and_files_are_staged_without_shell_interpolation(self) -> None:
        files, language, arguments, script_paths = server._request_files({
            "task_id": "task-1",
            "code": "print('hello')",
            "language": "python",
            "materials": [{"name": "notes.txt", "content": "data"}],
            "skill_files": {"scripts/run.py": base64.b64encode(b"print('skill')").decode("ascii")},
        })
        self.assertEqual(language, "python")
        self.assertEqual(arguments, [])
        self.assertEqual(script_paths, [])
        self.assertIn(("main.py", b"print('hello')"), files)
        self.assertIn(("materials/1-notes.txt", b"data"), files)
        archive = tarfile.open(fileobj=io.BytesIO(server._make_archive(files)))
        self.assertEqual(archive.extractfile("main.py").read(), b"print('hello')")
        self.assertEqual(archive.getmember("output/").mode, 0o777)

    def test_skill_script_arguments_remain_separate_argv_values(self) -> None:
        files, language, arguments, paths = server._request_files({
            "task_id": "task-1",
            "code": "placeholder",
            "language": "javascript",
            "script_path": "scripts/run.js",
            "arguments": ["value with spaces", "$(touch /tmp/nope)"],
            "skill_files": {"scripts/run.js": base64.b64encode(b"console.log(process.argv)").decode("ascii")},
        })
        self.assertEqual(language, "javascript")
        self.assertEqual(arguments, ["value with spaces", "$(touch /tmp/nope)"])
        self.assertEqual(paths, ["scripts/run.js"])
        command = server._command(language, arguments, paths)
        self.assertEqual(command[-2:], arguments)
        self.assertIn("/workspace/skill/scripts/run.js", command)

    def test_dependency_executable_modes_survive_archive_reconstruction(self) -> None:
        files = [('skill/node_modules/pkg/bin/tool', b'ELF-fixture'), ('skill/readme.txt', b'text'),
                 ('skill/.xiaoqi/dependency-lock.json', json.dumps({'schema':1,'executables':['node_modules/pkg/bin/tool']}).encode())]
        with tarfile.open(fileobj=io.BytesIO(server._make_archive(iter(files)))) as archive:
            executable = archive.getmember('skill/node_modules/pkg/bin/tool')
            self.assertEqual(executable.mode, 0o755)
            self.assertEqual(executable.uid, 10001)
            self.assertEqual(archive.getmember('skill/readme.txt').mode, 0o644)

    def test_dependency_executable_records_cannot_escape_or_name_missing_files(self) -> None:
        for paths in [['../main.py'], ['/etc/passwd'], ['missing'], 'not-a-list', [42]]:
            with self.subTest(paths=paths), self.assertRaises(server.RequestError):
                server._make_archive([('skill/.xiaoqi/dependency-lock.json',json.dumps({'executables':paths}).encode())])

    def test_source_execution_metadata_preserves_owner_mode_only(self) -> None:
        files=[('skill/scripts/install.sh',b'#!/bin/sh\nprintf ok'),
               ('skill/.xiaoqi-source-executables.json',json.dumps({'schema':1,'executables':['scripts/install.sh']}).encode())]
        with tarfile.open(fileobj=io.BytesIO(server._make_archive(files))) as archive:
            entry=archive.getmember('skill/scripts/install.sh')
            self.assertEqual(entry.mode,0o755)
            self.assertEqual(entry.uid,10001)
        with self.assertRaises(server.RequestError):
            server._make_archive([('skill/.xiaoqi-source-executables.json',b'{"executables":["../main.py"]}')])

    def test_input_manifest_preserves_binary_identity_and_current_paths(self) -> None:
        content = bytes([0, 255, 128, 80, 75, 3, 4])
        files, _, _, _ = server._request_files({
            "task_id": "task-manifest", "language": "python", "code": "pass",
            "materials": [{
                "artifact_id": "original-artifact", "name": "../source.pdf",
                "media_type": "application/pdf",
                "base64": base64.b64encode(content).decode("ascii"),
            }],
        })
        staged = dict(files)
        manifest = json.loads(staged["input_manifest.json"])
        source = manifest["inputs"][0]
        self.assertEqual(source["id"], "original-artifact")
        self.assertEqual(source["name"], "source.pdf")
        self.assertEqual(source["path"], "/workspace/materials/1-source.pdf")
        self.assertEqual(staged[source["path"].removeprefix("/workspace/")], content)
        self.assertEqual(source["size"], len(content))
        self.assertEqual(manifest["work_dir"], "/workspace/work")
        self.assertEqual(manifest["output_dir"], "/workspace/output")
        archive = tarfile.open(fileobj=io.BytesIO(server._make_archive(files)))
        for name in ("work/", "output/", ".home/", ".python/"):
            self.assertEqual(archive.getmember(name).uid, 10001)
            self.assertTrue(archive.getmember(name).mode & 0o222)

    def test_skill_script_extension_must_match_language(self) -> None:
        with self.assertRaises(server.RequestError):
            server._request_files({
                "task_id": "task-1",
                "code": "placeholder",
                "language": "python",
                "script_path": "scripts/run.js",
                "skill_files": {"scripts/run.js": base64.b64encode(b"print(1)").decode("ascii")},
            })


    def test_mcp_connection_does_not_inherit_the_script_deadline(self):
        for mcp in (False, True):
            with self.subTest(mcp=mcp):
                client, volume, container = Mock(), Mock(), Mock()
                volume.name = 'timeout-fixture-volume'
                client.volumes.create.return_value = volume
                client.containers.create.return_value = container
                container.put_archive.return_value = True
                states = iter(['running', 'exited'])
                def reload():
                    state = next(states, 'exited')
                    container.attrs = {'State': {'Status': state, 'Running': state == 'running', 'ExitCode': 0}}
                container.reload.side_effect = reload
                channel = StdioChannel() if mcp else None
                if channel is not None:
                    channel.attach = Mock()
                send = Mock()
                request = {'task_id':'deadline-fixture','code':'pass','language':'python',
                           'command':['node','/workspace/skill/server.js']}
                with (patch.object(server, '_get_client', return_value=client),
                      patch.object(server, 'DockerAttachStream', return_value=Mock()),
                      patch.object(server, '_decode_logs', return_value=''),
                      patch.object(server, '_safe_artifacts', return_value=[]),
                      patch.object(server, 'MAX_RUN_SECONDS', 0),
                      patch.object(server.time, 'sleep')):
                    result = server._run_sandbox(request, send, stdio=channel)
                self.assertEqual(result['ok'], mcp)
                if not mcp:
                    self.assertIn('0 秒', result['error'])
                    container.kill.assert_called_once()
                else:
                    self.assertTrue(any(call.args[0].get('type') == 'heartbeat' for call in send.call_args_list))

    def test_dependency_build_uses_a_total_deadline_without_widening_ordinary_code(self):
        for profile, elapsed, success in [('code', 121, False), ('dependency_build', 121, True), ('dependency_build', 601, False)]:
            with self.subTest(profile=profile, elapsed=elapsed):
                client, container, volume = Mock(), Mock(), Mock()
                volume.name = 'budget-fixture'
                client.volumes.create.return_value = volume
                client.containers.create.return_value = container
                container.put_archive.return_value = True
                states = iter(['running', 'exited'])
                def reload():
                    state = next(states, 'exited')
                    container.attrs = {'State': {'Status': state, 'Running': state == 'running', 'ExitCode': 0}}
                container.reload.side_effect = reload
                partial = [{'name': 'partial.txt', 'base64': 'aGVsbG8='}]
                with (patch.object(server, '_get_client', return_value=client),
                      patch.object(server, '_decode_logs', return_value=''),
                      patch.object(server, '_safe_artifacts', return_value=partial),
                      patch.object(server.time, 'monotonic', side_effect=[0, elapsed]),
                      patch.object(server.time, 'sleep')):
                    result = server._run_sandbox({'task_id': 'budget-test', 'language': 'python',
                        'code': 'pass', 'execution_profile': profile}, Mock())
                self.assertEqual(result['ok'], success)
                self.assertEqual(result['artifacts'], partial)
                self.assertEqual(container.kill.call_count, 0 if success else 1)
                options = client.containers.create.call_args.kwargs
                self.assertEqual(options['mem_limit'], '384m')
                self.assertEqual(options['user'], '10001:10001')
                self.assertEqual(options['cap_drop'], ['ALL'])
                self.assertTrue(options['read_only'])
                container.remove.assert_called_once_with(force=True, v=True)

    def test_invalid_or_misapplied_build_profile_creates_no_resources(self):
        invalid = [None, 600, [], 'unlimited', 'dependency_build']
        with patch.object(server, '_get_client') as client:
            for profile in invalid:
                with self.subTest(profile=profile), self.assertRaises(server.RequestError):
                    server._run_sandbox({'task_id': 'profile-test', 'language': 'shell',
                        'code': 'true', 'execution_profile': profile}, Mock())
            client.assert_not_called()

    def test_hook_json_and_durable_checkpoint_keep_large_verdict_while_code_tail_stays_bounded(self):
        verdict = {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                   'permissionDecision': 'deny', 'additionalContext': 'x' * 70000}}
        envelope = json.dumps({'xiaoqi_hook_command_v1': {'exit_code': 0,
                              'stdout': json.dumps(verdict), 'stderr': '',
                              'matched': True, 'timed_out': False}})
        for profile in ('code', 'plugin_hook'):
            with self.subTest(profile=profile):
                client, container, volume = Mock(), Mock(), Mock()
                volume.name = 'hook-protocol-fixture'
                client.volumes.create.return_value = volume
                client.containers.create.return_value = container
                container.put_archive.return_value = True
                container.attrs = {'State': {'Status': 'exited', 'Running': False, 'ExitCode': 0}}
                checkpoints = []
                with (patch.object(server, '_get_client', return_value=client),
                      patch.object(server, '_decode_logs', side_effect=lambda c, stream: envelope if stream == 'stdout' else ''),
                      patch.object(server, '_safe_artifacts', return_value=[])):
                    result = server._run_sandbox({'task_id': 'hook-output-test', 'language': 'javascript',
                        'execution_id': 'a' * 32,
                        'code': 'process.stdout.write("{}");', 'execution_profile': profile}, Mock(),
                        checkpoint=checkpoints.append)
                self.assertTrue(result['ok'])
                self.assertEqual(result['stdout'], checkpoints[-1]['stdout'])
                if profile == 'plugin_hook':
                    self.assertEqual(result['stdout'], envelope)
                    actual = json.loads(json.loads(result['stdout'])['xiaoqi_hook_command_v1']['stdout'])
                    self.assertEqual(actual, verdict)
                else:
                    self.assertEqual(len(result['stdout']), 40000)
                    with self.assertRaises(json.JSONDecodeError):
                        json.loads(result['stdout'])
                options = client.containers.create.call_args.kwargs
                if profile == 'plugin_hook':
                    self.assertEqual(options['labels']['com.xiaoqi.execution-profile'], 'plugin_hook')
                else:
                    self.assertNotIn('com.xiaoqi.execution-profile', options['labels'])
                self.assertEqual(options['nano_cpus'], 500000000)
                self.assertEqual(options['mem_limit'], '384m')
                self.assertEqual(options['network'], 'none')

    def test_hook_profile_does_not_grant_longer_deadline_or_mcp_script_entrypoints(self):
        request = {'execution_profile': 'plugin_hook', 'language': 'javascript', 'code': 'process.exit(0)'}
        self.assertEqual(server._execution_run_seconds(request), server.MAX_RUN_SECONDS)
        invalid = [{**request, 'language': 'shell'}, {**request, 'script_path': 'scripts/entry.js'},
                   {**request, 'command': ['node', 'entry.js']}]
        with patch.object(server, '_get_client') as client:
            for value in invalid:
                with self.assertRaises(server.RequestError):
                    server._run_sandbox({'task_id': 'hook-profile-test', **value}, Mock())
            with self.assertRaises(server.RequestError):
                server._execution_run_seconds(request, Mock())
            client.assert_not_called()

    def test_read_only_hook_never_exports_ephemeral_files_or_grants_network(self):
        request = {'task_id': 'readonly-hook', 'execution_id': 'a' * 32,
                   'execution_profile': 'plugin_hook_read_only',
                   'language': 'javascript', 'code': 'process.exit(0)'}
        client, container, volume = Mock(), Mock(), Mock()
        volume.name = 'readonly-hook-volume'
        client.volumes.create.return_value = volume
        client.containers.create.return_value = container
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'exited', 'Running': False, 'ExitCode': 0}}
        checkpoints = []
        with (patch.object(server, '_get_client', return_value=client),
              patch.object(server, '_decode_logs', return_value='protocol'),
              patch.object(server, '_safe_artifacts') as export):
            result = server._run_sandbox(request, Mock(), checkpoint=checkpoints.append)
            export.assert_not_called()
        self.assertEqual(result['artifacts'], [])
        self.assertEqual(checkpoints[-1]['artifacts'], [])
        self.assertEqual(result['stdout'], 'protocol')
        options = client.containers.create.call_args.kwargs
        self.assertEqual(options['labels']['com.xiaoqi.execution-profile'], 'plugin_hook_read_only')
        self.assertEqual(options['network'], 'none')
        self.assertEqual(server._execution_run_seconds(request), server.MAX_RUN_SECONDS)
        with patch.object(server, '_get_client') as create, self.assertRaises(server.RequestError):
            server._run_sandbox({**request, 'authorized_domains': ['example.com']}, Mock())
        create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
