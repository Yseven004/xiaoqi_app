import assert from 'node:assert/strict'
import test from 'node:test'
import {
  patchPluginBundleNavigation,
  patchRemoteSettings,
  patchSettingsSectionNavigation,
  patchSettingsTabNavigation,
} from './patch_remote_settings.mjs'

const source = 'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";'

test('allows DSH host settings only on the configured admin hostname', () => {
  const patched = patchRemoteSettings(source, 'ADMIN.XIAOQI.EXAMPLE:8443')
  assert.match(patched, /isLoopback \|\| globalThis\.location\?\.hostname\?\.toLowerCase\(\) === "admin\.xiaoqi\.example"/)
  assert.match(patched, /: "memory";/)
})

test('fails closed when the upstream DSH gate changes', () => {
  assert.throws(() => patchRemoteSettings('const persistence = true;', 'admin.xiaoqi.example'), /Expected one DSH remote-settings gate/)
})

test('rejects malformed admin host configuration', () => {
  assert.throws(() => patchRemoteSettings(source, 'admin.example/path'), /must be a hostname/)
})

test('opens the requested native DSH settings section and tab', () => {
  const section = patchSettingsSectionNavigation('const shellInstance = shellHandle.create();')
  const tab = patchSettingsTabNavigation('const [activeId, setActiveId] = (0, react.useState)();')
  assert.match(section, /openSection\(requestedSettingsSection\)/)
  assert.match(tab, /react\.useState\)\(requestedSettingsTab\)/)
})

test('opens the requested DSH plugin bundle page from a deep link', () => {
  const patched = patchPluginBundleNavigation('const disposeNavigation = ctx.reflect.provide("pluginNavigation", {')
  assert.match(patched, /setView\(\{ kind: "package", name: requestedPluginBundle \}\)/)
})
