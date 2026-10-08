"""Focused tests for the DSH admin's update and authentication boundaries."""

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from werkzeug.security import generate_password_hash

from xiaoqi_harness.dsh_manager import manager


class DshManagerTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.old_values = (manager.ROOT, manager.DB_PATH, manager.STATE_PATH, manager._READY)
        manager.ROOT = self.root
        manager.DB_PATH = self.root / "manager.sqlite3"
        manager.STATE_PATH = self.root / "manager-state.json"
        manager._READY = False
        self.scheduler_patch = patch.object(manager, "_run_update_scheduler", return_value=None)
        self.recovery_patch = patch.object(manager, "_recover_interrupted_operations", return_value=None)
        self.scheduler_patch.start()
        self.recovery_patch.start()
        self.client = manager.app.test_client()

    def tearDown(self):
        self.scheduler_patch.stop()
        self.recovery_patch.stop()
        manager.ROOT, manager.DB_PATH, manager.STATE_PATH, manager._READY = self.old_values
        self.temporary_directory.cleanup()

    def test_login_requires_csrf_for_session_mutations_and_logout_revokes_session(self):
        with patch.dict(
            os.environ,
            {
                "XIAOQI_DSH_ADMIN_PASSWORD_HASH": generate_password_hash("test-admin-password"),
                "XIAOQI_DSH_COOKIE_SECURE": "0",
            },
        ):
            login = self.client.post("/api/auth/login", json={"password": "test-admin-password"})
            self.assertEqual(login.status_code, 200)
            csrf = login.json["csrf"]

            rejected = self.client.post("/api/auth/logout", json={}, headers={})
            self.assertEqual(rejected.status_code, 403)

            logged_out = self.client.post("/api/auth/logout", json={}, headers={"X-CSRF-Token": csrf})
            self.assertEqual(logged_out.status_code, 200)
            self.assertFalse(self.client.get("/api/auth").json["authenticated"])

    def test_release_compatibility_is_rechecked_against_the_active_profile(self):
        release = self.root / "releases" / "dsh-1.2.3"
        release.mkdir(parents=True)
        lock_bytes = b'{"lockfileVersion":3,"packages":{}}'
        (release / "package-lock.json").write_bytes(lock_bytes)
        binary = release / "node_modules" / ".bin" / "dsh"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/usr/bin/env node\n", encoding="utf-8")
        (release / "manifest.json").write_text(
            json.dumps({
                "version": "1.2.3",
                "binary": "node_modules/.bin/dsh",
                "compatibility_checked": True,
                "lock_sha256": hashlib.sha256(lock_bytes).hexdigest(),
            }),
            encoding="utf-8",
        )
        with patch.object(manager, "_profile_for_config", return_value=self.root / "active-profile") as profile_for_config:
            with patch.object(manager, "_check_release_compatibility", return_value=("incompatible", [{"name": "plugin-a", "result": "incompatible"}])):
                releases = manager._prepared_releases(
                    {"active_release_id": "builtin", "config_id": "cfg-current", "dsh_version": "0.2.0-rc.2"}
                )
        candidate = next(item for item in releases if item["id"] == "dsh-1.2.3")
        self.assertEqual(candidate["compatibility"], "incompatible")
        self.assertEqual(candidate["plugin_checks"][0]["name"], "plugin-a")
        profile_for_config.assert_called_once_with("cfg-current")

    def test_plugin_sources_must_be_exactly_pinned(self):
        with patch.object(manager, "_npm_package", return_value={"version": "1.2.3"}):
            self.assertEqual(manager._parse_spec("example-plugin@1.2.3"), ("example-plugin@1.2.3", "1.2.3", "npm"))
            with self.assertRaises(ValueError):
                manager._parse_spec("example-plugin@latest")
        commit = "a" * 40
        self.assertEqual(
            manager._parse_spec(f"github:owner/repo#{commit}"),
            (f"github:owner/repo#{commit}", "", "github"),
        )
        with self.assertRaises(ValueError):
            manager._parse_spec("github:owner/repo#main")

    def test_plugin_without_peer_range_can_enter_draft_but_not_be_published(self):
        with patch.object(manager, "_compatibility", return_value="unknown"):
            manager._check_peer_package({"name": "plugin-a", "peerDependencies": {}}, "0.2.0-rc.2")
        with patch.object(manager, "_compatibility", return_value="incompatible"):
            with self.assertRaisesRegex(ValueError, "不兼容"):
                manager._check_peer_package(
                    {"name": "plugin-a", "peerDependencies": {"@deepseek-ai/dsh": "<0.2.0"}},
                    "0.2.0-rc.2",
                )
        with patch.object(manager, "_internal", return_value={"dsh_version": "0.2.0-rc.2"}):
            with patch.object(manager, "_draft_profile", return_value=(self.root / "profile", {"dirty": True})):
                with patch.object(manager, "_active_binary", return_value="dsh"):
                    with patch.object(
                        manager,
                        "_plugin_rows",
                        return_value=[{"name": "plugin-a", "enabled": True, "compatibility": "unknown"}],
                    ):
                        with self.assertRaisesRegex(ValueError, "不能发布到小七"):
                            manager._perform_plugin_apply("unconfirmed-plugin")

    def test_command_failure_reports_redacted_diagnostics(self):
        class FailedProcess:
            returncode = 1

            def poll(self):
                return self.returncode

        def write_log(*_args, **kwargs):
            kwargs["stdout"].write(
                b"npm error code E401\nnpm error authorization=secret-value\nnpm error Authorization: Bearer hidden-token\n"
            )
            return FailedProcess()

        with patch.object(manager.subprocess, "Popen", side_effect=write_log):
            with self.assertRaisesRegex(RuntimeError, "E401") as raised:
                manager._run_command(["npm", "install"], home=self.root / "home", operation_id="failed-install")
        self.assertNotIn("secret-value", str(raised.exception))
        self.assertNotIn("hidden-token", str(raised.exception))

    def test_immutable_profile_contains_its_dependency_tree(self):
        source = self.root / "draft" / "profiles" / "xiaoqi-acp"
        (source / "node_modules" / "plugin-a").mkdir(parents=True)
        (source / "package.json").write_text(
            json.dumps({"dependencies": {}, "dsh": {"profile": {"bundles": []}}}),
            encoding="utf-8",
        )
        (source / "node_modules" / "plugin-a" / "package.json").write_text(
            json.dumps({"name": "plugin-a", "version": "1.0.0"}),
            encoding="utf-8",
        )
        destination = self.root / "configs" / "cfg-1" / "profiles" / "xiaoqi-acp"

        manager._copy_immutable_profile(source, destination)

        self.assertTrue((destination / "node_modules" / "plugin-a" / "package.json").is_file())
        self.assertNotEqual(
            (destination / "node_modules" / "plugin-a" / "package.json").resolve(),
            (source / "node_modules" / "plugin-a" / "package.json").resolve(),
        )

    def test_github_pinned_plugins_are_not_checked_as_npm_updates(self):
        profile = self.root / "profile"
        git_package = profile / "node_modules" / "git-plugin" / "package.json"
        npm_package = profile / "node_modules" / "npm-plugin" / "package.json"
        git_package.parent.mkdir(parents=True)
        npm_package.parent.mkdir(parents=True)
        (profile / "package.json").write_text(
            json.dumps({
                "dependencies": {
                    "git-plugin": "github:owner/repo#" + "a" * 40,
                    "npm-plugin": "1.0.0",
                },
                "dsh": {"profile": {"bundles": ["git-plugin", "npm-plugin"]}},
            }),
            encoding="utf-8",
        )
        for path, name in ((git_package, "git-plugin"), (npm_package, "npm-plugin")):
            path.write_text(
                json.dumps({"name": name, "version": "1.0.0", "dsh": {"bundle": {"patch": {"ok": True}}}}),
                encoding="utf-8",
            )
        with patch.object(manager, "_compatibility", return_value="compatible"):
            with patch.object(manager, "_npm_package", return_value={"version": "1.1.0", "peerDependencies": {}}) as npm_lookup:
                updates, _ = manager._check_plugin_updates_for_profile(profile, "0.2.0-rc.2")

        self.assertEqual(set(updates), {"npm-plugin"})
        npm_lookup.assert_called_once_with("npm-plugin")


if __name__ == "__main__":
    unittest.main()
