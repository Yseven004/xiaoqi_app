from __future__ import annotations

import json
import threading
import unittest
import urllib.request
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer

import server

class NetworkControlTests(unittest.TestCase):
    def test_private_http_token_control_and_revocation_roundtrip(self):
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
                    suffix = 'token' if action == 'network_token' else 'off'
                    request = urllib.request.Request(
                        f'http://127.0.0.1:{http.server_port}/v1/tasks/network-control-task/network/{suffix}',
                        data=json.dumps({'task_id': 'network-control-task'}).encode(),
                        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
                        method='POST')
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open(request, timeout=5) as response:
                        self.assertEqual(response.status, 200)
                        return json.load(response)

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
