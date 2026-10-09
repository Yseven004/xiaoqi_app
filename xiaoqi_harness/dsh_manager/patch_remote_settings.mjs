import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const needle = 'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";'

export function patchRemoteSettings(source, adminHostname) {
  const configuredHost = String(adminHostname || '').trim()
  let url
  try {
    url = new URL(configuredHost.includes('://') ? configuredHost : `https://${configuredHost}`)
  } catch {
    throw new Error('XIAOQI_ADMIN_HOST must be a hostname, optionally with a port or scheme')
  }
  if (!url.hostname || !['http:', 'https:'].includes(url.protocol) || url.pathname !== '/' || url.search || url.hash || url.username || url.password) {
    throw new Error('XIAOQI_ADMIN_HOST must be a hostname, optionally with a port or scheme')
  }
  const allowedHostname = url.hostname.toLowerCase()
  const replacement = `const persistence = ctx.remote.$host.isLoopback || globalThis.location?.hostname?.toLowerCase() === ${JSON.stringify(allowedHostname)} ? "host" : "memory";`
  const matches = source.split(needle).length - 1
  if (matches === 1) return source.replace(needle, replacement)
  if (matches === 0 && source.includes(replacement)) return source
  throw new Error(`Expected one DSH remote-settings gate, found ${matches}`)
}

function patchOnce(source, anchor, addition, marker) {
  if (source.includes(marker)) return source
  const matches = source.split(anchor).length - 1
  if (matches !== 1) throw new Error(`Expected one DSH navigation anchor, found ${matches}`)
  return source.replace(anchor, `${anchor}${addition}`)
}

export function patchSettingsSectionNavigation(source) {
  return patchOnce(
    source,
    'const shellInstance = shellHandle.create();',
    '\nconst requestedSettingsSection = new URLSearchParams(globalThis.location?.search ?? "").get("xiaoqiSettingsSection");\nif (requestedSettingsSection) shellInstance.actions.openSection(requestedSettingsSection);',
    'xiaoqiSettingsSection',
  )
}

export function patchSettingsTabNavigation(source) {
  const anchor = 'const [activeId, setActiveId] = (0, react.useState)();'
  const matches = source.split(anchor).length - 1
  if (source.includes('xiaoqiSettingsTab')) return source
  if (matches !== 1) throw new Error(`Expected one DSH settings-tab anchor, found ${matches}`)
  return source.replace(
    anchor,
    'const requestedSettingsTab = new URLSearchParams(globalThis.location?.search ?? "").get("xiaoqiSettingsTab") ?? void 0;\n' +
      'const [activeId, setActiveId] = (0, react.useState)(requestedSettingsTab);',
  )
}

export function patchPluginBundleNavigation(source) {
  const anchor = 'const disposeNavigation = ctx.reflect.provide("pluginNavigation",'
  const marker = 'xiaoqiPluginBundle'
  if (source.includes(marker)) return source
  const matches = source.split(anchor).length - 1
  if (matches !== 1) throw new Error(`Expected one DSH plugin-navigation anchor, found ${matches}`)
  const addition = 'const requestedPluginBundle = new URLSearchParams(globalThis.location?.search ?? "").get("xiaoqiPluginBundle");\n' +
    'if (requestedPluginBundle) { ctx.layout.selectPanel(PANEL_ID); instance.actions.setView({ kind: "package", name: requestedPluginBundle }); }\n'
  return source.replace(anchor, `${addition}${anchor}`)
}

function findPackageFiles(root, packageName, relativeFile) {
  const found = []
  const pending = [{ path: root, depth: 0 }]
  while (pending.length) {
    const current = pending.pop()
    if (!current || current.depth > 14) continue
    let entries
    try {
      entries = readdirSync(current.path, { withFileTypes: true })
    } catch {
      continue
    }
    const manifestPath = join(current.path, 'package.json')
    try {
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
      if (manifest.name === packageName && typeof manifest.version === 'string') {
        found.push({ manifestPath, clientPath: join(current.path, relativeFile) })
      }
    } catch {
      // Most directories in node_modules are not package roots.
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name === '.bin' || entry.name === '.cache') continue
      pending.push({ path: join(current.path, entry.name), depth: current.depth + 1 })
    }
  }
  return found
}

function patchInstalledPackage(adminHostname) {
  const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
  const targets = [
    ['@deepseek-ai/dsh-client-ui-settings', 'lib/client.js', (source) => patchRemoteSettings(source, adminHostname)],
    ['@deepseek-ai/dsh-client-ui-settings-general', 'lib/client.js', patchSettingsSectionNavigation],
    ['@deepseek-ai/dsh-client-ui-settings-plugins', 'lib/client.js', patchSettingsTabNavigation],
    ['@deepseek-ai/dsh-client-ui-plugin-manager', 'lib/client.js', patchPluginBundleNavigation],
  ]
  for (const [packageName, relativeFile, transform] of targets) {
    const packages = findPackageFiles(globalRoot, packageName, relativeFile)
    if (!packages.length) throw new Error(`Could not find installed DSH client package ${packageName}`)
    for (const candidate of packages) {
      const source = readFileSync(candidate.clientPath, 'utf8')
      const updated = transform(source)
      if (updated !== source) writeFileSync(candidate.clientPath, updated, 'utf8')
    }
  }
  process.stdout.write(`DSH remote settings and plugin deep links enabled for ${adminHostname}\n`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    patchInstalledPackage(process.argv[2])
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  }
}
