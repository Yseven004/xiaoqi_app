from __future__ import annotations

import base64
import io
import json
import socket
import tarfile
import unittest
from unittest.mock import Mock, patch

import server
from stdio_channel import StdioChannel


class RunnerValidationTests(unittest.TestCase):
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
        container.attach_socket.return_value = attached
        channel = StdioChannel()
        argv = ['node','/workspace/skill/server.js','literal; $(not-a-host-command)']
        with patch.object(server, '_get_client', return_value=client), patch.object(server, '_decode_logs', return_value=''), patch.object(server, '_safe_artifacts', return_value=[]):
            result = server._run_sandbox({'task_id':'stdio-task','command':argv,'environment':{'PLUGIN_SETTING':'value'}}, Mock(), channel)
        self.assertTrue(result['ok'])
        options = client.containers.create.call_args.kwargs
        self.assertEqual(options['command'], argv)
        self.assertTrue(options['stdin_open'])
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
                },
                Mock(),
            )

        self.assertTrue(result["ok"])
        self.assertEqual(execution_client.containers.create.call_count, 1)
        self.assertEqual(
            execution_client.containers.create.call_args.kwargs["image"],
            server.SANDBOX_IMAGE,
        )

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


if __name__ == "__main__":
    unittest.main()
