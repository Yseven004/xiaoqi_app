from __future__ import annotations

import base64
import io
import tarfile
import unittest
from unittest.mock import Mock

import server


class RunnerValidationTests(unittest.TestCase):
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
