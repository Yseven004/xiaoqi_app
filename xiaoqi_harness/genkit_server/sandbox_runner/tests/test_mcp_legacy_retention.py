import unittest
from unittest.mock import Mock, patch

import server


class LegacyRetentionTests(unittest.TestCase):
    def test_unbound_legacy_workspace_is_frozen_and_retained_while_bound_session_stays_live(self):
        legacy = {server.OWNER_LABEL: 'true', 'com.xiaoqi.task-id': 'old-task'}
        active = {**legacy, 'com.xiaoqi.mcp-lease': 'a' * 32}
        finished = {**legacy, 'com.xiaoqi.execution-id': 'b' * 32}
        client = Mock()
        groups = []
        for collection, container in ((client.containers, True), (client.networks, False), (client.volumes, False)):
            resources = []
            for labels in (legacy, active, finished):
                item = Mock()
                item.attrs = {'Config': {'Labels': labels}, 'State': {'Running': True}} if container else {'Labels': labels}
                resources.append(item)
            collection.list.return_value = resources
            groups.append(resources)
        registry = Mock(active_lease_ids={'a' * 32})
        with patch.object(server, '_mcp_sessions', registry):
            server._remove_stale_resources(client)
        groups[0][0].kill.assert_called_once()
        groups[0][0].wait.assert_called_once_with(timeout=5)
        groups[0][1].kill.assert_not_called()
        for resources in groups:
            resources[0].remove.assert_not_called()
            resources[1].remove.assert_not_called()
            resources[2].remove.assert_called_once()
