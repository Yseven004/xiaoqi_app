from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import threading
import unittest
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer

import server

spec = importlib.util.spec_from_file_location('network_worker', Path(__file__).parents[2] / 'bin' / 'docker_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class NetworkControlTests(unittest.TestCase):
    def test_private_bridge_token_control_and_revocation_roundtrip(self):
        token = 'test-runner-token-' + 'a' * 32
        client = Mock()
        client.containers.list.return_value = []
        with (patch.object(server, 'RUNNER_TOKEN', token),
              patch.object(server, '_get_client', return_value=client)):
            http = ThreadingHTTPServer(('127.0.0.1', 0), server.RunnerHandler)
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            try:
                def control(action):
                    output = io.StringIO()
                    with (patch.dict(os.environ, {'SANDBOX_RUNNER_URL': f'http://127.0.0.1:{http.server_port}', 'SANDBOX_RUNNER_TOKEN': token}),
                          patch.object(worker.sys, 'stdin', io.StringIO(json.dumps({'action': action, 'task_id': 'network-control-task'}))),
                          contextlib.redirect_stdout(output)):
                        self.assertEqual(worker.main(), 0)
                    return json.loads(output.getvalue())

                old = control('network_token')['network_token']
                self.assertTrue(server._network_token_is_current('network-control-task', old))
                self.assertTrue(control('disable_network')['ok'])
                self.assertFalse(server._network_token_is_current('network-control-task', old))
                fresh = control('network_token')['network_token']
                self.assertTrue(server._network_token_is_current('network-control-task', fresh))
                self.assertNotEqual(old, fresh)
                self.assertFalse(server._network_token_is_current('other-task', fresh))
            finally:
                http.shutdown()
                http.server_close()
                thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
