import { Fragment, useCallback, useEffect, useState } from 'react'
import type { FormEvent } from 'react'

type Auth = { authenticated: boolean; csrf?: string }
type Plugin = {
  name: string
  version: string
  description: string
  source: string
  distribution?: 'npm' | 'github'
  enabled: boolean
  compatibility: 'compatible' | 'incompatible' | 'unknown'
  peer_range?: string
  update_version?: string
  update_compatibility?: 'compatible' | 'incompatible' | 'unknown'
}
type CatalogPlugin = {
  name: string
  version: string
  display_name: string
  description: string
  repository: string
  license: string
  catalog_compatibility: string
}
type Release = {
  id: string
  version: string
  current?: boolean
  prepared?: boolean
  compatibility?: 'compatible' | 'incompatible' | 'unknown'
  notes?: string
  released_at?: string
}
type Status = {
  maintenance: boolean
  operation_id: string | null
  active_release_id: string
  dsh_version: string
  config_id: string
  config_revision: number
  active_tasks: number
  queued_tasks: number
  draft_dirty: boolean
  draft_plugins: Plugin[]
  config_history?: Array<{ config_id: string; config_revision: number; created_at: string; plugin_count: number }>
  last_check?: string
  plugins_last_check?: string
  github_checked?: boolean
  github_error?: string | null
}
type Operation = {
  id: string
  kind: string
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled'
  step: string
  message: string
  error?: string
  result?: Record<string, unknown>
  cancellable?: boolean
}

const api = async <T,>(path: string, auth: Auth, body?: unknown): Promise<T> => {
  const response = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    credentials: 'same-origin',
    headers: {
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(body === undefined || !auth.csrf ? {} : { 'X-CSRF-Token': auth.csrf }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(result.error?.message || '操作失败，请重试')
  return result as T
}

const formatTime = (value?: string) => {
  if (!value) return '尚未检查'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '时间未知' : date.toLocaleString('zh-CN', { hour12: false })
}

function App() {
  const [auth, setAuth] = useState<Auth | null>(null)
  const [page, setPage] = useState<'plugins' | 'releases'>('plugins')
  const [status, setStatus] = useState<Status | null>(null)
  const [releases, setReleases] = useState<Release[]>([])
  const [operation, setOperation] = useState<Operation | null>(null)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [password, setPassword] = useState('')
  const [loginBusy, setLoginBusy] = useState(false)
  const [dialog, setDialog] = useState<'add' | 'switch' | 'details' | null>(null)
  const [selectedPlugin, setSelectedPlugin] = useState<Plugin | null>(null)
  const [pluginSpec, setPluginSpec] = useState('')
  const [catalog, setCatalog] = useState<CatalogPlugin[]>([])
  const [catalogVisible, setCatalogVisible] = useState(false)
  const [catalogStale, setCatalogStale] = useState(false)
  const [selectedRelease, setSelectedRelease] = useState<Release | null>(null)
  const [configText, setConfigText] = useState('')
  const [query, setQuery] = useState('')
  const [working, setWorking] = useState(false)

  const refresh = useCallback(async (credentials: Auth) => {
    const next = await api<Status>('/api/status', credentials)
    setStatus(next)
    const versionState = await api<{ releases: Release[] }>('/api/releases', credentials)
    setReleases(versionState.releases)
  }, [])

  useEffect(() => {
    fetch('/api/auth', { credentials: 'same-origin' })
      .then((response) => response.json())
      .then((value: Auth) => setAuth(value))
      .catch(() => setAuth({ authenticated: false }))
  }, [])

  useEffect(() => {
    if (!auth?.authenticated) return
    refresh(auth).catch((cause: Error) => setError(cause.message))
  }, [auth, refresh])

  useEffect(() => {
    if (!auth?.authenticated || !operation || !['queued', 'running'].includes(operation.status)) return
    const timer = window.setInterval(() => {
      api<Operation>(`/api/operations/${operation.id}`, auth)
        .then((next) => {
          setOperation(next)
          if (next.status === 'completed') {
            setNotice(next.message || '操作已完成')
            refresh(auth).catch((cause: Error) => setError(cause.message))
          } else if (next.status === 'failed' || next.status === 'cancelled') {
            setError(next.error || next.message || '操作未完成')
            refresh(auth).catch(() => undefined)
          }
        })
        .catch((cause: Error) => setError(cause.message))
    }, 1600)
    return () => window.clearInterval(timer)
  }, [auth, operation, refresh])

  useEffect(() => {
    if (!auth?.authenticated || dialog !== 'add' || !catalogVisible) return
    const timer = window.setTimeout(() => {
      const query = new URLSearchParams({ q: pluginSpec.trim() })
      api<{ plugins: CatalogPlugin[]; stale: boolean }>(`/api/plugins/catalog?${query}`, auth)
        .then((result) => {
          setCatalog(result.plugins)
          setCatalogStale(result.stale)
        })
        .catch((cause: Error) => {
          setCatalog([])
          setCatalogStale(true)
          setError(`社区目录暂时不可用：${cause.message}`)
        })
    }, 220)
    return () => window.clearTimeout(timer)
  }, [auth, catalogVisible, dialog, pluginSpec])

  const run = async <T,>(action: () => Promise<T>, done?: (result: T) => void) => {
    setError('')
    setNotice('')
    setWorking(true)
    try {
      const result = await action()
      done?.(result)
      return result
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '操作失败，请重试')
      return undefined
    } finally {
      setWorking(false)
    }
  }

  const startOperation = (result: { operation_id: string }) => {
    api<Operation>(`/api/operations/${result.operation_id}`, auth!).then(setOperation).catch((cause: Error) => setError(cause.message))
  }

  const login = async (event: FormEvent) => {
    event.preventDefault()
    setLoginBusy(true)
    setError('')
    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password }),
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error?.message || '登录失败')
      setPassword('')
      setAuth(result)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '登录失败')
    } finally {
      setLoginBusy(false)
    }
  }

  const logout = async () => {
    if (!auth) return
    await run(() => api('/api/auth/logout', auth, {}), () => {
      setAuth({ authenticated: false })
      setStatus(null)
      setOperation(null)
    })
  }

  const checkUpdates = async () => {
    await run(() => api('/api/releases/check', auth!, {}), async () => {
      await refresh(auth!)
      setNotice('已从 DSH 官方 npm 与 GitHub Releases 检查版本')
    })
  }

  const checkPluginUpdates = async () => {
    await run(() => api('/api/plugins/check', auth!, {}), async () => {
      await refresh(auth!)
      setNotice('已检查 npm 插件更新；GitHub 固定提交需要手动指定新 commit')
    })
  }

  const applyDraft = async () => {
    await run(() => api<{ operation_id: string }>('/api/plugins/apply', auth!, {}), (result) => {
      if (result) startOperation(result)
    })
  }

  const discardDraft = async () => {
    await run(() => api('/api/plugins/discard', auth!, {}), async () => {
      await refresh(auth!)
      setNotice('已放弃未应用的修改')
    })
  }

  const restorePreviousConfig = async () => {
    const previous = status?.config_history?.[0]
    if (!previous || status?.draft_dirty) return
    const target = previous.config_id === 'builtin' ? '镜像内置配置' : `配置修订 ${previous.config_revision}`
    if (!window.confirm(`恢复到${target}？这会影响下一条小七消息，正在回答的任务会继续使用原配置。`)) return
    await run(() => api('/api/plugins/restore', auth!, { config_id: previous.config_id }), async () => {
      await refresh(auth!)
      setNotice(`已恢复到${target}，下一条消息生效`)
    })
  }

  const togglePlugin = async (plugin: Plugin, enabled: boolean) => {
    await run(() => api('/api/plugins/toggle', auth!, { name: plugin.name, enabled }), async () => refresh(auth!))
  }

  const installPlugin = async (event: FormEvent) => {
    event.preventDefault()
    await run(() => api<{ operation_id: string }>('/api/plugins/install', auth!, { spec: pluginSpec }), (result) => {
      if (result) startOperation(result)
      setDialog(null)
      setPluginSpec('')
    })
  }

  const removePlugin = async (plugin: Plugin) => {
    if (!window.confirm(`从待应用配置中移除 ${plugin.name}？`)) return
    await run(() => api<{ operation_id: string }>('/api/plugins/remove', auth!, { name: plugin.name }), (result) => {
      if (result) startOperation(result)
      setDialog(null)
    })
  }

  const updatePlugin = async (plugin: Plugin) => {
    await run(() => api<{ operation_id: string }>('/api/plugins/update', auth!, { name: plugin.name }), (result) => {
      if (result) startOperation(result)
    })
  }

  const openDetails = async (plugin: Plugin) => {
    setSelectedPlugin(plugin)
    setConfigText('正在读取配置…')
    setDialog('details')
    try {
      const value = await api<{ config: string }>('/api/plugins/config', auth!)
      setConfigText(value.config)
    } catch (cause) {
      setConfigText(cause instanceof Error ? cause.message : '配置读取失败')
    }
  }

  const saveConfig = async () => {
    await run(() => api('/api/plugins/config', auth!, { config: configText }), async () => {
      setDialog(null)
      await refresh(auth!)
      setNotice('配置已保存到待应用修改')
    })
  }

  const prepareRelease = async (version: string) => {
    await run(() => api<{ operation_id: string }>('/api/releases/prepare', auth!, { version }), (result) => {
      if (result) startOperation(result)
    })
  }

  const beginSwitch = (release: Release) => {
    setSelectedRelease(release)
    setDialog('switch')
  }

  const switchRelease = async () => {
    if (!selectedRelease) return
    await run(() => api<{ operation_id: string }>('/api/releases/switch', auth!, { release_id: selectedRelease.id }), (result) => {
      if (result) startOperation(result)
      setDialog(null)
    })
  }

  const cancelOperation = async () => {
    if (!auth || !operation) return
    await run(() => api(`/api/operations/${operation.id}/cancel`, auth, {}), async () => {
      const next = await api<Operation>(`/api/operations/${operation.id}`, auth)
      setOperation(next)
    })
  }

  if (auth === null) {
    return <main className="loading-shell"><div className="skeleton title-skeleton" /><div className="skeleton card-skeleton" /></main>
  }

  if (!auth.authenticated) {
    return <main className="login-shell">
      <form className="login-card" onSubmit={login}>
        <div className="brand-mark">DSH</div>
        <p className="eyebrow">XIAOQI ADMIN</p>
        <h1>管理员登录</h1>
        <p className="muted">登录后管理小七使用的 DSH 插件与运行版本。</p>
        {error && <div className="notice error" role="alert">{error}</div>}
        <label className="field-label" htmlFor="password">管理员密码</label>
        <input id="password" type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required />
        <button className="button primary full" disabled={loginBusy}>{loginBusy ? '正在登录…' : '登录'}</button>
      </form>
    </main>
  }

  const plugins = (status?.draft_plugins || [])
    .filter((plugin) => `${plugin.name} ${plugin.description}`.toLowerCase().includes(query.toLowerCase()))
    .sort((a, b) => Number(a.source !== 'official') - Number(b.source !== 'official') || a.name.localeCompare(b.name))
  const activeOperation = operation && ['queued', 'running'].includes(operation.status) ? operation : null
  const preparedReleases = releases.filter((release) => release.prepared && !release.current)
  const updateCandidates = releases.filter((release) => !release.current && !release.prepared)

  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand"><span className="brand-mark small">DSH</span><span>DeepSeek Harness</span></div>
      <div className="sidebar-caption">小七管理</div>
      <nav aria-label="主导航">
        <button className={`nav-item ${page === 'plugins' ? 'selected' : ''}`} onClick={() => setPage('plugins')}>插件</button>
        <button className={`nav-item ${page === 'releases' ? 'selected' : ''}`} onClick={() => setPage('releases')}>版本管理</button>
      </nav>
      <div className="sidebar-spacer" />
      <div className="account-row"><span className="avatar">管</span><span className="account-name">管理员</span><button className="text-button" onClick={logout}>退出</button></div>
    </aside>

    <main className="main-panel">
      <header className="topbar">
        <div><span className="topbar-label">当前 DSH</span><strong>{status?.dsh_version || '读取中'}</strong></div>
        <span className={`status-pill ${!status ? 'neutral' : status.maintenance ? 'warning' : 'success'}`}>{!status ? '状态未知' : status.maintenance ? '维护中' : '运行正常'}</span>
      </header>

      <section className="page-content">
        {error && <div className="notice error" role="alert"><span>{error}</span><button className="text-button" onClick={() => setError('')}>关闭</button></div>}
        {notice && <div className="notice success" role="status"><span>{notice}</span><button className="text-button" onClick={() => setNotice('')}>关闭</button></div>}
        {activeOperation && <section className="operation-card" aria-live="polite">
          <div><span className="eyebrow">正在执行</span><strong>{activeOperation.message || activeOperation.step}</strong><p className="muted">{activeOperation.step} · 在途任务 {status?.active_tasks ?? 0} 个，排队任务 {status?.queued_tasks ?? 0} 个</p></div>
          {activeOperation.cancellable && <button className="button quiet" onClick={cancelOperation}>取消操作</button>}
        </section>}

        {page === 'plugins' ? <>
          <div className="page-heading">
            <div><p className="eyebrow">服务端配置</p><h1>插件</h1><p className="muted">安装、启用并配置小七下一条消息使用的插件。</p></div>
            <div className="heading-actions">
              <button className="button quiet" onClick={checkPluginUpdates} disabled={working}>检查更新</button>
              <button className="button primary" onClick={() => setDialog('add')}>＋ 添加插件</button>
            </div>
          </div>
          <div className="status-strip">
            <span>当前 DSH <strong>{status?.dsh_version || '—'}</strong></span>
            <span>配置修订 <strong>{status?.config_revision ?? 0}</strong></span>
            {status?.plugins_last_check && <span>插件检查 <strong>{formatTime(status.plugins_last_check)}</strong></span>}
          </div>
          <div className="list-toolbar">
            <h2>已安装 <span className="count">{plugins.length}</span></h2>
            <label className="search-box"><span className="sr-only">搜索插件</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索插件" /></label>
          </div>
          {status?.draft_dirty && <div className="draft-banner"><div><strong>有待应用的修改</strong><p>新配置只会影响下一条小七消息，当前回答会继续使用原配置。</p></div><div className="banner-actions"><button className="button quiet" onClick={discardDraft} disabled={working}>放弃修改</button><button className="button primary" onClick={applyDraft} disabled={working}>应用到小七</button></div></div>}
          {plugins.length === 0 ? <div className="empty-card"><h2>{query ? '没有匹配的插件' : '还没有已安装插件'}</h2><p className="muted">从 npm 包名或 GitHub 固定提交开始添加，安装内容会先进入待应用配置。</p>{!query && <button className="button primary" onClick={() => setDialog('add')}>添加插件</button>}</div> : <div className="plugin-list">
            {plugins.map((plugin, index) => <Fragment key={plugin.name}>{(index === 0 || plugin.source !== plugins[index - 1].source) && <div className="plugin-group-heading">{plugin.source === 'official' ? '官方' : '社区'}</div>}<article className="plugin-row">
              <button className="plugin-main" onClick={() => openDetails(plugin)}>
                <span className="plugin-glyph">{plugin.name.slice(0, 1).toUpperCase()}</span>
                <span className="plugin-copy"><strong>{plugin.name}</strong><span className="plugin-description">{plugin.description || '此插件没有提供说明。'}</span><span className="plugin-meta">v{plugin.version} · {plugin.distribution === 'github' ? 'GitHub 固定提交' : plugin.source === 'official' ? '官方 npm' : '社区 npm'}{plugin.update_version ? ` · 可更新至 ${plugin.update_version}` : ''}</span></span>
              </button>
              <div className="plugin-side">{plugin.update_version && <button className="text-button update-button" disabled={working || plugin.update_compatibility !== 'compatible'} onClick={() => updatePlugin(plugin)}>更新至 {plugin.update_version}</button>}<span className={`compatibility ${plugin.compatibility}`}>{plugin.compatibility === 'compatible' ? '版本要求匹配' : plugin.compatibility === 'incompatible' ? '版本不兼容' : '兼容性尚未确认'}</span><button type="button" role="switch" aria-checked={plugin.enabled} aria-label={`${plugin.enabled ? '停用' : '启用'} ${plugin.name}`} className={`switch ${plugin.enabled ? 'on' : ''}`} onClick={() => togglePlugin(plugin, !plugin.enabled)}><span /></button></div>
            </article></Fragment>)}
          </div>}
          <p className="footnote">插件来源和兼容信息会在安装、更新或切换 DSH 版本前重新检查。</p>
          {status?.config_history?.[0] && <div className="config-history"><div><strong>最近一次已应用配置</strong><span>修订 {status.config_history[0].config_revision} · {status.config_history[0].plugin_count} 个插件 · {formatTime(status.config_history[0].created_at)}</span></div><button className="button quiet" onClick={restorePreviousConfig} disabled={working || status.draft_dirty}>恢复此配置</button></div>}
        </> : <>
          <div className="page-heading">
            <div><p className="eyebrow">运行环境</p><h1>版本管理</h1><p className="muted">版本固定运行；检查与切换分开进行。</p></div>
            <button className="button primary" onClick={checkUpdates} disabled={working}>{working ? '正在检查…' : '检查更新'}</button>
          </div>
          <section className="current-release">
            <div><p className="eyebrow">当前使用</p><h2>DSH {status?.dsh_version || '—'}</h2><p className="muted">固定版本 · 小七后台任务使用此运行环境</p></div>
            <span className={`status-pill ${!status ? 'neutral' : status.maintenance ? 'warning' : 'success'}`}>{!status ? '状态未知' : status.maintenance ? '正在维护' : '运行正常'}</span>
          </section>
          <div className="release-section-heading"><div><h2>可用版本</h2><p className="muted">npm 官方包提供安装版本；GitHub Releases 补充发行说明。</p></div><span className="last-check">{formatTime(status?.last_check)}</span></div>
          {status?.last_check && <p className={`source-status ${status.github_checked ? 'ok' : 'partial'}`}>{status.github_checked ? 'npm 与 GitHub Releases 均已检查' : `npm 版本可用，GitHub Releases 暂不可用${status.github_error ? `：${status.github_error}` : ''}`}</p>}
          {updateCandidates.length === 0 && preparedReleases.length === 0 ? <div className="empty-card compact"><h3>还没有检查结果</h3><p className="muted">检查只读取官方发行信息，不会自动下载或安装。</p></div> : <div className="release-list">
            {preparedReleases.map((release) => <article className="release-row" key={release.id}><div><div className="release-title"><strong>DSH {release.version}</strong><span className="status-pill neutral">已准备</span></div><p className="muted">{release.notes || '候选版本已下载并通过本地启动检查。'}</p>{release.compatibility !== 'compatible' && <p className="compat-warning">{release.compatibility === 'incompatible' ? '与当前启用插件不兼容' : '当前配置兼容性尚未确认，暂不能切换'}</p>}</div><button className="button primary" disabled={release.compatibility !== 'compatible' || working} onClick={() => beginSwitch(release)}>切换版本</button></article>)}
            {updateCandidates.map((release) => <article className="release-row" key={release.id}><div><div className="release-title"><strong>DSH {release.version}</strong>{release.compatibility === 'compatible' && <span className="compatibility compatible">已检查</span>}</div><p className="muted">{release.notes || '官方发行版本'}{release.released_at ? ` · ${formatTime(release.released_at)}` : ''}</p>{release.compatibility !== 'compatible' && <p className="compat-warning">{release.compatibility === 'incompatible' ? '与当前启用插件不兼容' : '插件兼容性尚未确认，暂不能准备此版本'}</p>}</div><button className="button secondary" disabled={release.compatibility !== 'compatible' || working} onClick={() => prepareRelease(release.version)}>准备版本</button></article>)}
          </div>}
          <div className="maintenance-note"><strong>切换时会发生什么</strong><p>先暂停接收新任务，等待当前回答完成，再切换并检查健康状态。等待超过 10 分钟会取消切换并恢复原版本。</p></div>
          <section className="history-section"><h2>已准备的版本</h2><div className="history-list">{releases.filter((release) => release.prepared || release.current).map((release) => <div className="history-row" key={release.id}><span>DSH {release.version}{release.current ? ' · 当前' : ''}</span><span className="muted">{release.current ? '正在运行' : release.compatibility === 'compatible' ? '可切换' : '兼容性待确认'}</span>{!release.current && <button className="text-button" disabled={release.compatibility !== 'compatible' || working} onClick={() => beginSwitch(release)}>恢复此版本</button>}</div>)}</div></section>
        </>}
      </section>
    </main>

    {dialog === 'add' && <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDialog(null) }}><section className="dialog" role="dialog" aria-modal="true" aria-labelledby="add-title"><button className="dialog-close" onClick={() => setDialog(null)} aria-label="关闭">×</button><p className="eyebrow">添加到待应用配置</p><h2 id="add-title">添加插件</h2><p className="muted">输入 npm 包名，或 GitHub 仓库与固定 commit。缺少 DSH 版本声明的插件可先加入草稿验证；未确认兼容的插件不能发布到小七。</p><p className="install-warning">插件会随小七服务端任务运行。请只安装可信来源；安装过程中不会运行 npm 生命周期脚本。</p><form onSubmit={installPlugin}><label className="field-label" htmlFor="plugin-spec">包名或 GitHub 地址</label><input id="plugin-spec" autoFocus value={pluginSpec} onChange={(event) => setPluginSpec(event.target.value)} placeholder="@scope/plugin@1.2.3 或 github:owner/repo#commit" required /><div className="dialog-actions"><button type="button" className="button quiet" onClick={() => setDialog(null)}>取消</button><button className="button primary" disabled={working || !pluginSpec.trim()}>{working ? '正在安装…' : '检查并安装'}</button></div></form><button className="text-button catalog-toggle" onClick={() => setCatalogVisible(!catalogVisible)}>{catalogVisible ? '收起社区目录' : '浏览社区目录'}</button>{catalogVisible && <div className="catalog-panel"><p className="catalog-source">社区目录只负责发现；安装前会再次核对 npm 精确版本与兼容要求。{catalogStale ? ' 当前显示的是缓存结果。' : ''}</p>{catalog.length === 0 ? <p className="muted catalog-empty">{catalogStale ? '社区目录暂时不可用，可直接输入 npm 包名添加。' : pluginSpec ? '没有匹配的社区插件。' : '正在读取社区目录…'}</p> : catalog.slice(0, 6).map((item) => <article className="catalog-row" key={`${item.name}@${item.version}`}><div><strong>{item.display_name}</strong><p>{item.description || item.name}</p><small>{item.name}@{item.version} · {item.license || '许可未记录'} · 目录兼容性待实测</small></div><button className="button quiet" onClick={() => setPluginSpec(`${item.name}@${item.version}`)}>选择</button></article>)}</div>}</section></div>}

    {dialog === 'details' && selectedPlugin && <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDialog(null) }}><section className="dialog wide" role="dialog" aria-modal="true" aria-labelledby="details-title"><button className="dialog-close" onClick={() => setDialog(null)} aria-label="关闭">×</button><p className="eyebrow">插件详情</p><h2 id="details-title">{selectedPlugin.name}</h2><p className="muted">v{selectedPlugin.version} · {selectedPlugin.distribution === 'github' ? 'GitHub 固定提交' : selectedPlugin.source === 'official' ? '官方 npm' : '社区 npm'} · {selectedPlugin.description}</p><label className="field-label" htmlFor="plugin-config">小七 ACP profile 配置</label><textarea id="plugin-config" className="config-editor" value={configText} onChange={(event) => setConfigText(event.target.value)} spellCheck={false} /><p className="footnote">此配置属于小七共用的 ACP profile。保存后进入待应用配置；YAML 错误会在应用预检时提示，线上配置保持不变。</p><div className="dialog-actions spread"><button className="button danger-quiet" onClick={() => removePlugin(selectedPlugin)}>移除插件</button><div><button className="button quiet" onClick={() => setDialog(null)}>关闭</button><button className="button primary" onClick={saveConfig} disabled={working}>保存修改</button></div></div></section></div>}

    {dialog === 'switch' && selectedRelease && <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDialog(null) }}><section className="dialog" role="dialog" aria-modal="true" aria-labelledby="switch-title"><button className="dialog-close" onClick={() => setDialog(null)} aria-label="关闭">×</button><p className="eyebrow">DSH 版本切换</p><h2 id="switch-title">切换到 {selectedRelease.version}？</h2><div className="change-summary"><div><span>当前版本</span><strong>{status?.dsh_version}</strong></div><span className="summary-arrow">→</span><div><span>目标版本</span><strong>{selectedRelease.version}</strong></div></div><p className="muted">系统会暂停新任务并等待当前回答结束。若健康检查失败，会自动恢复到 {status?.dsh_version}。</p><p className="muted">正在处理 {status?.active_tasks ?? 0} 个任务，排队 {status?.queued_tasks ?? 0} 个。</p><div className="dialog-actions"><button className="button quiet" onClick={() => setDialog(null)}>暂不切换</button><button className="button primary" onClick={switchRelease} disabled={working}>确认切换</button></div></section></div>}
  </div>
}

export default App
