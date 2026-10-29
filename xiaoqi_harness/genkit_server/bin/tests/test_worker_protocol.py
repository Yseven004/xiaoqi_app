from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('hook_protocol_bridge',
    Path(__file__).resolve().parents[1] / 'docker_worker.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class HookProtocolBridgeTests(unittest.TestCase):
    def test_private_profile_forwards_complete_json_with_normal_timeout(self):
        request = {'task_id': 'profile-fixture', 'execution_id': 'a' * 32,
                   'language': 'javascript', 'code': 'process.exit(0)',
                   'execution_profile': 'plugin_hook'}
        envelope = json.dumps({'xiaoqi_hook_command_v1': {'exit_code': 2,
            'stdout': '\x00' * 120000, 'stderr': 'source denial',
            'matched': True, 'timed_out': False}})
        event = {'type': 'result', 'ok': True, 'stdout': envelope, 'artifacts': []}
        opener = Mock()
        opener.open.return_value = io.BytesIO((json.dumps(event) + '\n').encode())
        messages = []
        with (patch.dict(bridge.os.environ, {'SANDBOX_RUNNER_URL': 'http://runner',
                                          'SANDBOX_RUNNER_TOKEN': 'fixture-only'}),
              patch.object(bridge.sys, 'stdin', io.StringIO(json.dumps(request))),
              patch.object(bridge.urllib.request, 'build_opener', return_value=opener),
              patch.object(bridge, '_emit', side_effect=messages.append)):
            self.assertEqual(bridge.main(), 0)
        self.assertEqual(messages, [event])
        outgoing = opener.open.call_args.args[0]
        self.assertEqual(json.loads(outgoing.data)['execution_profile'], 'plugin_hook')
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 330)

    def test_unknown_profile_never_reaches_transport(self):
        opener = Mock()
        with (patch.dict(bridge.os.environ, {'SANDBOX_RUNNER_URL': 'http://runner',
                                          'SANDBOX_RUNNER_TOKEN': 'fixture-only'}),
              patch.object(bridge.sys, 'stdin', io.StringIO(json.dumps({
                  'task_id': 'profile-fixture', 'execution_profile': 'unlimited'}))),
              patch.object(bridge.urllib.request, 'build_opener', return_value=opener),
              patch.object(bridge, '_emit')):
            self.assertEqual(bridge.main(), 1)
        opener.open.assert_not_called()


if __name__ == '__main__':
    unittest.main()
