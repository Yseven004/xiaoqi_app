"""Focused tests for the DSH admin's update and authentication boundaries."""

import hashlib
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
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

    def test_auth_verify_redirects_to_login_and_accepts_admin_session(self):
        response = self.client.get("/api/auth/verify", follow_redirects=False)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.headers["Location"], "/xiaoqi/")
        with patch.dict(
            os.environ,
            {
                "XIAOQI_DSH_ADMIN_PASSWORD_HASH": generate_password_hash("test-admin-password"),
                "XIAOQI_DSH_COOKIE_SECURE": "0",
            },
        ):
            self.client.post("/api/auth/login", json={"password": "test-admin-password"})
            self.assertEqual(self.client.get("/api/auth/verify").status_code, 204)

    def test_readiness_rejects_missing_internal_token(self):
        with patch.dict(os.environ, {"XIAOQI_DSH_INTERNAL_TOKEN": ""}):
            response = self.client.get("/readyz")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["status"], "not_ready")
        self.assertIn("凭据未配置", response.json["error"])

    def test_readiness_rejects_internal_token_shorter_than_32_characters(self):
        with patch.dict(os.environ, {"XIAOQI_DSH_INTERNAL_TOKEN": "t" * 31}):
            response = self.client.get("/readyz")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["status"], "not_ready")

    def test_readiness_requires_a_reachable_xiaoqi_status(self):
        with patch.dict(os.environ, {"XIAOQI_DSH_INTERNAL_TOKEN": "t" * 40}):
            with patch.object(manager, "_internal", return_value={"dsh_version": "0.2.0-rc.2"}) as internal:
                response = self.client.get("/readyz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"status": "ready", "dsh_version": "0.2.0-rc.2"})
        internal.assert_called_once_with("/status", timeout=3)

    def test_readiness_reports_internal_api_rejection_without_becoming_ready(self):
        with patch.dict(os.environ, {"XIAOQI_DSH_INTERNAL_TOKEN": "t" * 40}):
            with patch.object(manager, "_internal", side_effect=RuntimeError("无权读取 DSH 管理状态")):
                response = self.client.get("/readyz")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["status"], "not_ready")
        self.assertIn("无权读取", response.json["error"])

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

    def test_compatibility_checks_component_level_dsh_peer_ranges(self):
        package = {
            "peerDependencies": {
                "@deepseek-ai/dsh-settings": "^0.2.0-rc.1",
                "@deepseek-ai/dsh-llm": ">=0.1.0-rc.6",
                "@deepseek-ai/cordis": ">=4.0.1",
            }
        }
        with patch.object(manager, "_semver_satisfies", side_effect=[True, True]) as satisfies:
            self.assertEqual(manager._compatibility(package, "0.2.0-rc.2"), "compatible")
        self.assertEqual(
            [call.args[0] for call in satisfies.call_args_list],
            ["^0.2.0-rc.1", ">=0.1.0-rc.6"],
        )

        with patch.object(manager, "_semver_satisfies", side_effect=[True, False]):
            self.assertEqual(manager._compatibility(package, "0.2.0-rc.2"), "incompatible")

    def test_compatibility_stays_unknown_without_a_dsh_peer_range(self):
        package = {"peerDependencies": {"@deepseek-ai/cordis": ">=4.0.1"}}
        with patch.object(manager, "_semver_satisfies") as satisfies:
            self.assertEqual(manager._compatibility(package, "0.2.0-rc.2"), "unknown")
        satisfies.assert_not_called()

    def test_unknown_compatibility_requires_confirmation_then_can_be_published(self):
        with patch.object(manager, "_compatibility", return_value="unknown"):
            manager._check_peer_package({"name": "plugin-a", "peerDependencies": {}}, "0.2.0-rc.2")
        with patch.object(manager, "_compatibility", return_value="incompatible"):
            with self.assertRaisesRegex(ValueError, "不兼容"):
                manager._check_peer_package(
                    {"name": "plugin-a", "peerDependencies": {"@deepseek-ai/dsh": "<0.2.0"}},
                    "0.2.0-rc.2",
                )
        profile = self.root / "web-profile"
        profile.mkdir()
        state = {"dsh_version": "0.2.0-rc.2", "config_id": "builtin", "config_revision": 0}
        rows = [{"name": "plugin-a", "version": "1.0.0", "enabled": True, "compatibility": "unknown"}]
        with patch.dict(
            os.environ,
            {
                "XIAOQI_DSH_ADMIN_PASSWORD_HASH": generate_password_hash("test-admin-password"),
                "XIAOQI_DSH_COOKIE_SECURE": "0",
            },
        ):
            login = self.client.post("/api/auth/login", json={"password": "test-admin-password"})
            csrf = login.json["csrf"]
            with patch.object(manager, "_plugin_apply_context", return_value=(state, profile, state["dsh_version"], rows, ["plugin-a"], "snapshot-1")):
                with patch.object(manager, "_start_operation", return_value="plugin-apply-1") as start:
                    first = self.client.post("/api/plugins/apply", json={}, headers={"X-CSRF-Token": csrf})
                    self.assertEqual(first.status_code, 200)
                    self.assertTrue(first.json["confirmation_required"])
                    self.assertEqual(first.json["unknown_plugins"], ["plugin-a"])
                    self.assertEqual(first.json["profile_digest"], "snapshot-1")
                    start.assert_not_called()

                    stale = self.client.post(
                        "/api/plugins/apply",
                        json={"confirmed_unknown_plugins": ["plugin-a"], "confirmed_profile_digest": "old-snapshot"},
                        headers={"X-CSRF-Token": csrf},
                    )
                    self.assertEqual(stale.status_code, 409)
                    start.assert_not_called()

                    confirmed = self.client.post(
                        "/api/plugins/apply",
                        json={"confirmed_unknown_plugins": ["plugin-a"], "confirmed_profile_digest": "snapshot-1"},
                        headers={"X-CSRF-Token": csrf},
                    )
                    self.assertEqual(confirmed.status_code, 202)
                    self.assertEqual(confirmed.json["operation_id"], "plugin-apply-1")
                    start.assert_called_once_with(
                        "plugin_apply",
                        {"confirmed_unknown_plugins": ["plugin-a"], "confirmed_profile_digest": "snapshot-1"},
                    )

    def test_plugin_apply_rejects_confirmation_if_unknown_set_changed(self):
        profile = self.root / "web-profile"
        profile.mkdir()
        state = {"dsh_version": "0.2.0-rc.2", "config_id": "builtin", "config_revision": 0}
        with patch.object(
            manager,
            "_plugin_apply_context",
            return_value=(state, profile, state["dsh_version"], [], ["plugin-b"], "snapshot-1"),
        ):
            with self.assertRaisesRegex(ValueError, "狀态在确认期间发生变化|状态在确认期间发生变化"):
                manager._perform_plugin_apply(
                    "plugin-apply-1",
                    {"confirmed_unknown_plugins": ["plugin-a"], "confirmed_profile_digest": "snapshot-1"},
                )

    def test_confirmed_unknown_plugin_is_snapshotted_and_reported(self):
        profile = self.root / "web-profile"
        profile.mkdir()
        state = {"dsh_version": "0.2.0-rc.2", "config_id": "builtin", "config_revision": 0}
        rows = [{"name": "plugin-a", "version": "1.0.0", "enabled": True, "compatibility": "unknown"}]

        def prepare_profile(_source, destination):
            destination.mkdir(parents=True)
            return ["plugin-a"]

        manager._ensure_ready()
        with patch.object(manager, "_plugin_apply_context", return_value=(state, profile, state["dsh_version"], rows, ["plugin-a"], "profile-digest")):
            with patch.object(manager, "_profile_digest", return_value="profile-digest"):
                with patch.object(manager, "_active_binary", return_value="dsh"):
                    with patch.object(manager, "_prepare_xiaoqi_profile", side_effect=prepare_profile):
                        with patch.object(manager, "_verify_profile"):
                            with patch.object(manager, "_internal", return_value={"config_revision": 1}) as internal:
                                result = manager._perform_plugin_apply(
                                    "plugin-apply-1",
                                    {"confirmed_unknown_plugins": ["plugin-a"], "confirmed_profile_digest": "profile-digest"},
                                )

        manifest = json.loads((self.root / "configs" / result["config_id"] / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["unconfirmed_plugins"], ["plugin-a"])
        self.assertIn("兼容性未确认插件：plugin-a", result["message"])
        internal.assert_called_once_with("/apply-config", {"config_id": result["config_id"]})

    def test_official_web_profile_is_converted_to_acp_with_plugin_settings(self):
        source = self.root / "web-home" / "profiles" / "web"
        enabled = source / "node_modules" / "@acme" / "dsh-enabled"
        disabled = source / "node_modules" / "@acme" / "dsh-disabled"
        enabled.mkdir(parents=True)
        disabled.mkdir(parents=True)
        manifest = {
            "name": "dsh-profile-web",
            "dependencies": {"@acme/dsh-enabled": "1.2.0", "@acme/dsh-disabled": "1.1.0"},
            "dsh": {"profile": {"bundles": [
                "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@acme/dsh-enabled",
            ]}},
        }
        (source / "package.json").write_text(json.dumps(manifest), encoding="utf-8")
        settings = "@acme/dsh-enabled#tool:\\n  disabled: true\\n"
        (source / "cordis.patch.yml").write_text(settings, encoding="utf-8")
        (source / ".plugin-manager").mkdir()
        (source / ".plugin-manager" / "run.json").write_text("private install log", encoding="utf-8")
        for path, name in ((enabled, "@acme/dsh-enabled"), (disabled, "@acme/dsh-disabled")):
            (path / "package.json").write_text(
                json.dumps({"name": name, "version": "1.0.0", "dsh": {"bundle": {"patch": {}}}}),
                encoding="utf-8",
            )
        destination = self.root / "configs" / "cfg-test" / "profiles" / "xiaoqi-acp"

        selected = manager._prepare_xiaoqi_profile(source, destination)
        result = json.loads((destination / "package.json").read_text(encoding="utf-8"))

        self.assertEqual(selected, ["@acme/dsh-enabled"])
        self.assertEqual(
            result["dsh"]["profile"]["bundles"],
            ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-acp-app", "@acme/dsh-enabled"],
        )
        self.assertEqual(result["dependencies"], manifest["dependencies"])
        self.assertEqual((destination / "cordis.patch.yml").read_text(encoding="utf-8"), settings)
        self.assertTrue((destination / "node_modules" / "@acme" / "dsh-enabled" / "package.json").is_file())
        self.assertFalse((destination / ".plugin-manager").exists())

    def test_publish_failure_removes_candidate_without_recording_it_as_active(self):
        source = self.root / "web-home" / "profiles" / "web"
        source.mkdir(parents=True)
        (source / "package.json").write_text(
            json.dumps({
                "name": "dsh-profile-web",
                "dependencies": {},
                "dsh": {"profile": {"bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]}},
            }),
            encoding="utf-8",
        )
        current = {
            "dsh_version": "0.2.0-rc.2",
            "config_id": "builtin",
            "config_revision": 7,
            "active_release_id": "builtin",
        }

        def reject_apply(path, body=None, timeout=12):
            if path == "/status":
                return current
            if path == "/apply-config":
                raise RuntimeError("simulated publish rejection")
            self.fail(f"unexpected internal route: {path}")

        manager._ensure_ready()
        with patch.object(manager, "WEB_PROFILE", source), patch.object(manager, "_internal", side_effect=reject_apply):
            with patch.object(manager, "_active_binary", return_value="dsh"), patch.object(manager, "_verify_profile"):
                with self.assertRaisesRegex(RuntimeError, "simulated publish rejection"):
                    manager._perform_plugin_apply(
                        "publish-rejected",
                        {"confirmed_unknown_plugins": [], "confirmed_profile_digest": manager._profile_digest(source)},
                    )

        self.assertFalse(any((self.root / "configs").glob("cfg-*")))
        self.assertNotIn("last_published_web_profile_sha256", manager._read_state())
        self.assertEqual(current["config_id"], "builtin")

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
        self.assertEqual(updates["npm-plugin"]["checked_from_version"], "1.0.0")
        npm_lookup.assert_called_once_with("npm-plugin")

    def test_update_recommendation_explains_compatible_stable_update(self):
        now = datetime(2026, 10, 8, 14, 0, tzinfo=timezone.utc)
        with patch.object(manager, "_semver_satisfies", return_value=True):
            result = manager._recommend_update(
                "1.0.0",
                "1.1.0",
                "compatible",
                "2026-10-08T13:30:00+00:00",
                "npm latest 标签",
                now=now,
            )

        self.assertEqual(result["status"], "available")
        self.assertEqual(result["label"], "有稳定版，可考虑更新")
        self.assertIn("版本要求匹配", result["reason"])

    def test_update_recommendation_never_recommends_a_prerelease_for_production(self):
        now = datetime(2026, 10, 8, 14, 0, tzinfo=timezone.utc)
        with patch.object(manager, "_semver_satisfies", return_value=True):
            result = manager._recommend_update(
                "1.0.0",
                "1.1.0-alpha.1",
                "compatible",
                "2026-10-08T13:30:00+00:00",
                "npm latest 标签",
                now=now,
            )

        self.assertEqual(result["status"], "preview")
        self.assertIn("预发布版", result["reason"])

    def test_update_recommendation_does_not_hide_incompatible_or_unknown_ranges(self):
        now = datetime(2026, 10, 8, 14, 0, tzinfo=timezone.utc)
        with patch.object(manager, "_semver_satisfies", return_value=True):
            incompatible = manager._recommend_update(
                "1.0.0", "1.1.0", "incompatible", "2026-10-08T13:30:00+00:00", "npm", now=now
            )
            unknown = manager._recommend_update(
                "1.0.0", "1.1.0", "unknown", "2026-10-08T13:30:00+00:00", "npm", now=now
            )

        self.assertEqual(incompatible["status"], "blocked")
        self.assertEqual(unknown["status"], "unknown")

    def test_security_release_note_only_recommends_priority_review(self):
        now = datetime(2026, 10, 8, 14, 0, tzinfo=timezone.utc)
        with patch.object(manager, "_semver_satisfies", return_value=True):
            result = manager._recommend_update(
                "1.0.0",
                "1.1.0",
                "compatible",
                "2026-10-08T13:30:00+00:00",
                "official release",
                security_signal=True,
                now=now,
            )

        self.assertEqual(result["status"], "priority")
        self.assertEqual(result["label"], "建议优先评估")
        self.assertIn("确认影响后", result["reason"])

    def test_missing_and_stale_update_checks_are_not_reported_as_current(self):
        now = datetime(2026, 10, 8, 14, 0, tzinfo=timezone.utc)
        missing = manager._recommend_update("1.0.0", None, "unknown", None, "npm", now=now)
        with patch.object(manager, "_semver_satisfies") as compare:
            stale = manager._recommend_update(
                "1.0.0",
                "1.0.0",
                "compatible",
                "2026-10-08T07:00:00+00:00",
                "npm",
                now=now,
            )

        self.assertEqual(missing["status"], "unchecked")
        self.assertEqual(stale["status"], "stale")
        compare.assert_not_called()

    def test_plugin_update_check_records_per_package_failures(self):
        profile = self.root / "profile"
        plugin_package = profile / "node_modules" / "npm-plugin" / "package.json"
        plugin_package.parent.mkdir(parents=True)
        (profile / "package.json").write_text(
            json.dumps({"dependencies": {"npm-plugin": "1.0.0"}, "dsh": {"profile": {"bundles": ["npm-plugin"]}}}),
            encoding="utf-8",
        )
        plugin_package.write_text(
            json.dumps({"name": "npm-plugin", "version": "1.0.0", "dsh": {"bundle": {"patch": {"ok": True}}}}),
            encoding="utf-8",
        )
        with patch.object(manager, "_compatibility", return_value="compatible"):
            with patch.object(manager, "_npm_package", side_effect=RuntimeError("registry unavailable")):
                updates, _ = manager._check_plugin_updates_for_profile(profile, "0.2.0")

        self.assertEqual(updates, {})
        self.assertEqual(manager._read_state()["plugin_update_errors"], {"npm-plugin": "无法读取 npm 上游版本"})

    def test_plugin_rows_identifies_native_configuration_pages_generically(self):
        profile = self.root / "profile"
        dependencies = {
            "configured-plugin": "1.0.0",
            "plain-plugin": "1.0.0",
        }
        (profile / "package.json").parent.mkdir(parents=True, exist_ok=True)
        (profile / "package.json").write_text(
            json.dumps({"dependencies": dependencies, "dsh": {"profile": {"bundles": list(dependencies)}}}),
            encoding="utf-8",
        )
        for name, client in (
            ("configured-plugin", {"inject": ["@deepseek-ai/dsh-client-ui-settings-plugins"]}),
            ("plain-plugin", {"inject": ["@deepseek-ai/dsh-client-ui-conversation"]}),
        ):
            package_path = profile / "node_modules" / name / "package.json"
            package_path.parent.mkdir(parents=True)
            (package_path.parent / "cordis.patch.yml").write_text(
                "- insert:\n    - id: configured-plugin\n",
                encoding="utf-8",
            )
            package_path.write_text(
                json.dumps({
                    "name": name,
                    "version": "1.0.0",
                    "dsh": {"bundle": {"patch": "./cordis.patch.yml"}, "client": client},
                }),
                encoding="utf-8",
            )

        with patch.object(manager, "_compatibility", return_value="compatible"):
            rows = manager._plugin_rows(profile, "0.2.0")

        self.assertEqual(
            {row["name"]: row["configuration_available"] for row in rows},
            {"configured-plugin": True, "plain-plugin": False},
        )
        configured = next(row for row in rows if row["name"] == "configured-plugin")
        self.assertEqual(configured["configuration_target"], {"kind": "settings_tab", "id": "configured-plugin"})

    def test_official_web_launch_opens_declared_plugin_configuration_target(self):
        with patch.dict(
            os.environ,
            {
                "XIAOQI_DSH_ADMIN_PASSWORD_HASH": generate_password_hash("test-admin-password"),
                "XIAOQI_DSH_COOKIE_SECURE": "0",
            },
        ):
            self.client.post("/api/auth/login", json={"password": "test-admin-password"})
            token_path = self.root / "web-launch-token"
            token_path.write_text("web-token", encoding="utf-8")
            with patch.object(manager, "WEB_TOKEN_PATH", token_path):
                response = self.client.get("/api/web/launch?settings_tab=image-gen")
                rejected = self.client.get("/api/web/launch?settings_tab=bad%2Ftarget")

        self.assertEqual(response.status_code, 302)
        self.assertEqual(
            response.headers["Location"],
            "/?token=web-token&xiaoqiSettingsSection=plugins&xiaoqiSettingsTab=image-gen",
        )
        self.assertEqual(rejected.status_code, 400)

    def test_failed_plugin_update_check_is_not_rendered_as_no_update(self):
        profile = self.root / "profile"
        plugin_package = profile / "node_modules" / "plugin-a" / "package.json"
        plugin_package.parent.mkdir(parents=True)
        (profile / "package.json").write_text(
            json.dumps({"dependencies": {"plugin-a": "1.0.0"}, "dsh": {"profile": {"bundles": ["plugin-a"]}}}),
            encoding="utf-8",
        )
        plugin_package.write_text(
            json.dumps({"name": "plugin-a", "version": "1.0.0", "dsh": {"bundle": {"patch": {"ok": True}}}}),
            encoding="utf-8",
        )
        checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with patch.object(manager, "_semver_satisfies", return_value=False):
            result = manager._update_recommendations(
                {"dsh_version": "0.2.0", "config_id": "builtin"},
                profile,
                {
                    "updates": {"npm_latest": "0.2.0", "last_check": checked_at},
                    "plugin_updates": {},
                    "plugin_update_errors": {"plugin-a": "无法读取 npm 上游版本"},
                    "plugins_last_check": checked_at,
                },
            )

        plugin = result["plugins"][0]["recommendation"]
        self.assertEqual(plugin["status"], "failed")
        self.assertEqual(plugin["label"], "检查失败")
        self.assertIn("不能据此判断", plugin["reason"])

    def test_failed_dsh_check_does_not_leave_a_cached_no_update_recommendation(self):
        now = datetime.now(timezone.utc)
        successful_at = (now.replace(minute=max(0, now.minute - 10))).isoformat(timespec="seconds")
        failed_at = now.isoformat(timespec="seconds")
        result = manager._update_recommendations(
            {"dsh_version": "0.2.0", "config_id": "builtin"},
            self.root,
            {
                "updates": {"npm_latest": "0.2.0", "last_check": successful_at},
                "updates_check_failed_at": failed_at,
            },
        )

        self.assertEqual(result["dsh"]["status"], "failed")
        self.assertEqual(result["dsh"]["label"], "检查失败")
        self.assertIn("上次成功结果", result["dsh"]["reason"])

    def test_release_check_uses_npm_latest_dist_tag_and_records_next_preview(self):
        package_data = {
            "versions": {"0.2.0": {}, "0.2.1-alpha.1": {}},
            "time": {"0.2.0": "2026-10-01T00:00:00Z", "0.2.1-alpha.1": "2026-10-02T00:00:00Z"},
            "dist-tags": {"latest": "0.2.0", "next": "0.2.1-alpha.1"},
        }
        with patch.object(manager, "_npm_package", return_value={"version": "0.2.1-alpha.1"}):
            with patch.object(
                manager,
                "_request_json",
                side_effect=[package_data, [{
                    "tag_name": "v0.2.0",
                    "name": "DSH release",
                    "body": "CVE-2026-12345: security fix",
                    "html_url": "https://github.com/deepseek-ai/deepseek-harness/releases/tag/v0.2.0",
                }]],
            ):
                with patch.object(manager, "_internal", return_value={"dsh_version": "0.2.0-rc.2", "config_id": "builtin"}):
                    cache = manager._check_release_updates()

        self.assertEqual(cache["npm_latest"], "0.2.0")
        self.assertEqual(cache["npm_next"], "0.2.1-alpha.1")
        release = next(item for item in cache["releases"] if item["version"] == "0.2.1-alpha.1")
        self.assertTrue(release["prerelease"])
        stable_release = next(item for item in cache["releases"] if item["version"] == "0.2.0")
        self.assertTrue(stable_release["security_update_signal"])
        self.assertTrue(stable_release["release_url"].startswith("https://github.com/deepseek-ai/"))


if __name__ == "__main__":
    unittest.main()
