"""Test the installer's actual metadata functions without executing build code."""
import ast
import pathlib
import shlex
import subprocess
import tempfile
import tomllib
import unittest
from types import SimpleNamespace
from unittest.mock import Mock


SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'genkit_server/bin/prepare_dependencies.py'
tree = ast.parse(SOURCE.read_text(encoding='utf-8'))
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
             and node.name in {'registry_requirements', 'project_metadata', 'npm_bin_shim', 'run_dependency_command'}]
namespace = {'tomllib': tomllib,'shlex':shlex}
exec(compile(ast.Module(body=functions, type_ignores=[]), str(SOURCE), 'exec'), namespace)
project_metadata = namespace['project_metadata']


class PythonProjectMetadataTests(unittest.TestCase):
    def test_python_and_npm_steps_share_the_original_remaining_budget(self):
        runner = Mock()
        clock = Mock(side_effect=[10, 80, 110])
        namespace.update({'_build_deadline': 110, 'time': SimpleNamespace(monotonic=clock),
                          'subprocess': SimpleNamespace(run=runner)})
        run = namespace['run_dependency_command']
        run(['python3', '-m', 'pip', 'install', 'fixture'])
        run(['npm', 'run', 'build'], cwd='bound-workspace')
        self.assertEqual([call.kwargs['timeout'] for call in runner.call_args_list], [100, 30])
        self.assertTrue(all(call.kwargs['check'] for call in runner.call_args_list))
        with self.assertRaises(TimeoutError):
            run(['npm', 'prune'])
        self.assertEqual(runner.call_count, 2)

    def test_failed_build_step_is_not_replayed(self):
        runner = Mock(side_effect=subprocess.TimeoutExpired(['npm', 'run', 'build'], 0.1))
        namespace.update({'_build_deadline': 110, 'time': SimpleNamespace(monotonic=lambda: 10),
                          'subprocess': SimpleNamespace(run=runner)})
        with self.assertRaises(subprocess.TimeoutExpired):
            namespace['run_dependency_command'](['npm', 'run', 'build'])
        self.assertEqual(runner.call_count, 1)

    def test_npm_cli_shim_quotes_its_target_and_preserves_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory)/'node_modules'; root.mkdir()
            target=root/"tool's;$(not-a-command)"
            target.write_text('fixture')
            shim=namespace['npm_bin_shim'](root,target).decode()
            self.assertEqual(shlex.split(shim.splitlines()[1]), ['exec',"/workspace/skill/node_modules/tool's;$(not-a-command)",'$@'])
            self.assertTrue(shim.endswith(' "$@"\n'))
            outside=pathlib.Path(directory)/'outside';outside.write_text('private')
            with self.assertRaises(ValueError):namespace['npm_bin_shim'](root,outside)

    def metadata(self, content, setup=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root/'pyproject.toml').write_text(content, encoding='utf-8')
            if setup:
                (root/'setup.py').write_text("raise RuntimeError('metadata reader must not execute this')")
            return project_metadata(root)

    def test_packaged_project_keeps_markers_and_optional_groups(self):
        requirements, groups, install = self.metadata('''
[build-system]
requires = ["hatchling>=1"]
build-backend = "hatchling.build"
[project]
name = "fixture"
version = "1.0"
dependencies = ["pypdf>=4; python_version >= '3.9'"]
[project.optional-dependencies]
pdf = ["Pillow>=11"]
''')
        self.assertEqual(requirements, ["pypdf>=4; python_version >= '3.9'"])
        self.assertEqual(groups, ['pdf'])
        self.assertTrue(install)

    def test_tool_config_and_optional_only_metadata_are_not_installable_projects(self):
        self.assertEqual(self.metadata('[tool.ruff]\nline-length=88\n'), ([], [], False))
        self.assertEqual(self.metadata('[project.optional-dependencies]\npdf=["pypdf>=4"]'), ([], ['pdf'], False))

    def test_setup_presence_is_detected_without_executing_it(self):
        self.assertEqual(self.metadata('', setup=True), ([], [], True))

    def test_direct_sources_and_malformed_declarations_fail_before_build(self):
        for content in (
            '[project]\ndependencies=["pkg @ https://example.com/a.whl"]',
            '[build-system]\nrequires=["pkg @ file:///host/file"]',
            '[project.optional-dependencies]\npdf=["pkg @ https://example.com/a.whl"]',
            '[project]\ndependencies="wrong"',
            'project="wrong"',
            'build-system="wrong"',
            '[project]\ndependencies=["--index-url evil"]',
            '[broken',
        ):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.metadata(content)


if __name__ == '__main__':
    unittest.main()
