"""Reconnect a recorded stdio process; never create a replacement MCP server."""
from __future__ import annotations

import time
from typing import Any, Callable

from docker.errors import DockerException, NotFound


def freeze_resources(resources):
    for kind, obj, _ in resources:
        if kind == 'container':
            try:
                obj.kill()
                obj.wait(timeout=5)
            except DockerException:
                pass


def lease_resources(client: Any, state: dict[str, Any], owner: str):
    expected = {owner: 'true', 'com.xiaoqi.mcp-lease': state['lease_id'],
                'com.xiaoqi.task-id': state['task_id'], 'com.xiaoqi.mcp-fingerprint': state['fingerprint']}
    filters = {'label': [f'{key}={value}' for key, value in expected.items()]}
    result = []
    for kind, objects in (
        ('container', client.containers.list(all=True, filters=filters)),
        ('network', client.networks.list(filters=filters)),
        ('volume', client.volumes.list(filters=filters)),
    ):
        for obj in objects:
            labels = (obj.attrs.get('Config', {}).get('Labels', {}) if kind == 'container'
                      else obj.attrs.get('Labels', {})) or {}
            if any(labels.get(key) != value for key, value in expected.items()):
                raise RuntimeError('Original MCP resource binding changed')
            result.append((kind, obj, labels))
    return result


def cleanup_resources(resources) -> bool:
    pending = False
    # Containers release mounts/networks before those resources are removed.
    for kind in ('container', 'network', 'volume'):
        for resource_kind, obj, _ in resources:
            if resource_kind != kind:
                continue
            try:
                if kind == 'container':
                    obj.remove(force=True, v=True)
                elif kind == 'volume':
                    obj.remove(force=True)
                else:
                    obj.remove()
            except NotFound:
                pass
            except DockerException:
                pending = True
    return pending


def resume_mcp(client: Any, state: dict[str, Any], event: Callable, channel: Any,
               *, owner: str, sandbox_image: str, read_artifacts: Callable):
    channel.preserve_recovery = state.get('result') is None
    if channel.detached:
        return {'detached': True}
    resources = lease_resources(client, state, owner)
    servers = [obj for kind, obj, labels in resources if kind == 'container' and labels.get('com.xiaoqi.role') == 'mcp-server']
    if len(servers) > 1:
        freeze_resources(resources)
        raise RuntimeError('Original MCP lease has conflicting server processes')
    container = servers[0] if servers else None
    expected_container = (state.get('resources') or {}).get('container')
    if container is not None and expected_container and container.id != expected_container:
        freeze_resources(resources)
        raise RuntimeError('Original MCP server was replaced; cannot replay its requests')
    attached = None
    detached = False
    result = state.get('result')
    never_started = False
    try:
        if channel.detached:
            return {'detached': True}
        if result is None and container is not None:
            container.reload()
            status = container.attrs.get('State', {}).get('Status')
            never_started = status == 'created' and not state.get('workspace_prepared')
            if status == 'created' and state.get('workspace_prepared') and not channel.closed:
                # This exact container has never run; the recorded archive was
                # fully installed before this durable preparation checkpoint.
                container.start()
                status = 'running'
            if status == 'running' and channel.closed and not channel.detached:
                container.kill()
                container.wait(timeout=5)
                container.reload()
            if status == 'running' and not channel.closed:
                attached = container.attach_socket(params={'stdin': True, 'stdout': True, 'stderr': True, 'stream': True, 'logs': True})
                channel.exporter = lambda: read_artifacts(container)
                channel.attach(attached._sock)
                event({'type': 'sandbox_started'})
                while True:
                    if channel.detached:
                        detached = True
                        return {'detached': True}
                    container.reload()
                    if container.attrs.get('State', {}).get('Status') in {'exited', 'dead'}:
                        break
                    if channel.closed and not channel.detached:
                        try:
                            container.kill()
                            container.wait(timeout=5)
                        except NotFound:
                            pass
                        break
                    time.sleep(0.2)
        if channel.detached:
            return {'detached': True}
        if result is None:
            if container is None:
                # Reading a surviving original volume uses a fixed, trusted
                # no-op helper, never the plugin command or its environment.
                volumes = [obj for kind, obj, _ in resources if kind == 'volume']
                helpers = [obj for kind, obj, labels in resources if kind == 'container' and labels.get('com.xiaoqi.role') == 'mcp-file-recovery']
                if len(volumes) > 1 or len(helpers) > 1:
                    raise RuntimeError('Original MCP workspace binding is ambiguous')
                if helpers:
                    container = helpers[0]
                elif volumes:
                    labels = {owner: 'true', 'com.xiaoqi.mcp-lease': state['lease_id'],
                              'com.xiaoqi.task-id': state['task_id'], 'com.xiaoqi.mcp-fingerprint': state['fingerprint'],
                              'com.xiaoqi.role': 'mcp-file-recovery'}
                    container = client.containers.create(image=sandbox_image, command=['/bin/true'],
                        volumes={volumes[0].name: {'bind': '/workspace', 'mode': 'ro'}},
                        network='none', user='10001:10001', read_only=True,
                        cap_drop=['ALL'], security_opt=['no-new-privileges:true'],
                        pids_limit=16, mem_limit='64m', memswap_limit='64m', nano_cpus=100_000_000,
                        labels=labels)
                    resources.append(('container', container, labels))
                    container.start()
                    container.wait(timeout=5)
            artifacts = read_artifacts(container) if container is not None and not never_started else []
            result = {'type': 'result', 'ok': False,
                      'error': channel.error or 'Original MCP process ended; outstanding RPC outcomes must not be replayed',
                      'artifacts': artifacts, 'cleanup_pending': True,
                      'sandbox_id': container.id if container is not None else None}
            if channel.checkpoint is not None:
                channel.checkpoint(result)
        if channel.detached:
            return {'detached': True}
        pending = cleanup_resources(resources)
        channel.preserve_recovery = False
        return {**result, 'cleanup_pending': pending,
                'sandbox_id': result.get('sandbox_id') if pending else None}
    except Exception:
        # No result has been committed: keep the exact workspaces, even if
        # Docker inspection/export or journal storage is temporarily failing.
        if not detached and not channel.detached:
            freeze_resources(resources)
            channel.preserve_recovery = True
        raise
    finally:
        if attached is not None:
            try:
                attached.close()
            except OSError:
                pass
