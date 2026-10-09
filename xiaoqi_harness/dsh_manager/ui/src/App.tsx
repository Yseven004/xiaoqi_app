import { useCallback, useEffect, useState } from 'react'
import type { FormEvent } from 'react'

type Auth = { authenticated: boolean; csrf?: string }
type Release = {
  id: string
  version: string
  current?: boolean
  prepared?: boolean
  compatibility?: 'compatible' | 'incompatible' | 'unknown'
  notes?: string
  released_at?: string
}
type Recommendation = {
  current_version: string
  candidate_version?: string | null
  compatibility: 'compatible' | 'incompatible' | 'unknown'
  checked_at?: string | null
  source: string
  notes?: string
  release_url?: string | null
  status: 'current' | 'available' | 'priority' | 'preview' | 'blocked' | 'unknown' | 'unchecked' | 'stale' | 'failed'
  label: string
  reason: string
}
type PluginRecommendation = {
  name: string
  enabled: boolean
  source: string
  configuration_available: boolean
  configuration_target?: { kind: 'settings_tab'; id: string } | { kind: 'bundle'; name: string } | null
  recommendation: Recommendation
}
type UpdateRecommendations = { dsh: Recommendation; plugins: PluginRecommendation[] }
type ConfigHistoryItem = { config_id: string; config_revision?: number; created_at?: string; plugin_count?: number }
type Status = {
  maintenance: boolean
  active_release_id: string
  dsh_version: string
  config_id: string
  config_revision: number
  active_tasks: number
  queued_tasks: number
  config_history?: ConfigHistoryItem[]
  official_web_profile: {
    ready: boolean
    enabled_bundle_count: number
    changed_since_publish: boolean
    installing: boolean
  }
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
type PluginApplyResponse = {
  operation_id?: string
  confirmation_required?: boolean
  unknown_plugins?: string[]
  profile_digest?: string
  warning?: string
}

const PREFIX = '/xiaoqi'

async function api<T>(path: string, auth?: Auth, body?: unknown): Promise<T> {
  const response = await fetch(`${PREFIX}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    credentials: 'same-origin',
    headers: {
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(body === undefined || !auth?.csrf ? {} : { 'X-CSRF-Token': auth.csrf }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(result.error?.message || '请求失败，请稍后重试')
  return result as T
}

function pluginConfigurationHref(target?: PluginRecommendation['configuration_target']): string | undefined {
  if (!target) return undefined
  const params = new URLSearchParams()
  if (target.kind === 'settings_tab') params.set('settings_tab', target.id)
  else params.set('plugin_bundle', target.name)
  return `${PREFIX}/api/web/launch?${params.toString()}`
}

function App() {
  const [auth, setAuth] = useState<Auth | null>(null)
  const [page, setPage] = useState<'bridge' | 'releases'>('bridge')
  const [status, setStatus] = useState<Status | null>(null)
  const [releases, setReleases] = useState<Release[]>([])
  const [recommendations, setRecommendations] = useState<UpdateRecommendations | null>(null)
  const [operation, setOperation] = useState<Operation | null>(null)
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [working, setWorking] = useState(false)
  const [checkingUpdates, setCheckingUpdates] = useState(false)
  const [applyConfirmation, setApplyConfirmation] = useState<{ plugins: string[]; profileDigest: string; warning: string } | null>(null)
  const [restoreConfirmation, setRestoreConfirmation] = useState<ConfigHistoryItem | null>(null)

  const refresh = useCallback(async (credentials: Auth) => {
    const [nextStatus, releaseState] = await Promise.all([
      api<Status>('/api/status', credentials),
      api<{ releases: Release[]; recommendations: UpdateRecommendations }>('/api/releases', credentials),
    ])
    setStatus(nextStatus)
    setReleases(releaseState.releases)
    setRecommendations(releaseState.recommendations)
  }, [])

  useEffect(() => {
    fetch(`${PREFIX}/api/auth`, { credentials: 'same-origin' })
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
            const message = typeof next.result?.message === 'string' ? next.result.message : next.message
            setNotice(message || '操作已完成')
            refresh(auth).catch((cause: Error) => setError(cause.message))
          } else if (next.status === 'failed' || next.status === 'cancelled') {
            setError(next.error || next.message || '操作未完成')
            refresh(auth).catch(() => undefined)
          }
        })
        .catch((cause: Error) => setError(cause.message))
    }, 1400)
    return () => window.clearInterval(timer)
  }, [auth, operation, refresh])

  const perform = async (action: () => Promise<void>) => {
    setWorking(true)
    setError('')
    setNotice('')
    try {
      await action()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '操作失败，请重试')
    } finally {
      setWorking(false)
    }
  }

  const login = async (event: FormEvent) => {
    event.preventDefault()
    await perform(async () => {
      const result = await api<Auth>('/api/auth/login', undefined, { password })
      setPassword('')
      setAuth(result)
    })
  }

  const logout = async () => {
    if (!auth) return
    await perform(async () => {
      await api('/api/auth/logout', auth, {})
      setAuth({ authenticated: false })
      setStatus(null)
      setOperation(null)
    })
  }

  const startOperation = async (path: string, body: unknown = {}) => {
    if (!auth) return
    const started = await api<{ operation_id: string }>(path, auth, body)
    const next = await api<Operation>(`/api/operations/${started.operation_id}`, auth)
    setOperation(next)
  }

  const startPluginApply = async (confirmation?: { plugins: string[]; profileDigest: string }) => {
    if (!auth) return
    const result = await api<PluginApplyResponse>('/api/plugins/apply', auth, {
      confirmed_unknown_plugins: confirmation?.plugins || [],
      ...(confirmation ? { confirmed_profile_digest: confirmation.profileDigest } : {}),
    })
    if (result.confirmation_required) {
      setApplyConfirmation({
        plugins: result.unknown_plugins || [],
        profileDigest: result.profile_digest || '',
        warning: result.warning || '这些插件没有声明当前 DSH 版本的兼容范围。',
      })
      return
    }
    if (!result.operation_id) throw new Error('没有收到发布操作编号，请刷新后重试')
    setApplyConfirmation(null)
    setOperation(await api<Operation>(`/api/operations/${result.operation_id}`, auth))
  }
  const publish = () => perform(() => startPluginApply())
  const confirmPluginApply = () => perform(async () => {
    try {
      if (applyConfirmation) {
        await startPluginApply({ plugins: applyConfirmation.plugins, profileDigest: applyConfirmation.profileDigest })
      }
    } catch (cause) {
      if (cause instanceof Error && cause.message.includes('状态在确认期间发生变化')) setApplyConfirmation(null)
      throw cause
    }
  })
  const restorePrevious = () => perform(async () => {
    if (!auth || !restoreConfirmation) return
    const restored = await api<{ config_id: string; config_revision?: number }>('/api/plugins/restore', auth, { config_id: restoreConfirmation.config_id })
    setRestoreConfirmation(null)
    await refresh(auth)
    setNotice(`已恢复 ${restored.config_id === 'builtin' ? '内置默认配置' : restored.config_id}；后续新任务将使用恢复后的配置`)
  })
  const checkVersions = () => perform(async () => {
    await api('/api/releases/check', auth!, {})
    await refresh(auth!)
    setNotice('已读取官方 DSH 版本列表')
  })
  const checkUpdates = () => perform(async () => {
    setCheckingUpdates(true)
    try {
    const [dshResult, pluginResult] = await Promise.allSettled([
      api('/api/releases/check', auth!, {}),
      api<{ checked: number; failed: number; failed_plugins: string[] }>('/api/plugins/check', auth!, {}),
    ])
    await refresh(auth!)
    const issues: string[] = []
    if (dshResult.status === 'rejected') {
      issues.push(`DSH 检查失败：${dshResult.reason instanceof Error ? dshResult.reason.message : '请稍后重试'}`)
    }
    if (pluginResult.status === 'rejected') {
      issues.push(`插件检查失败：${pluginResult.reason instanceof Error ? pluginResult.reason.message : '请稍后重试'}`)
    } else if (pluginResult.value.failed > 0) {
      issues.push(`${pluginResult.value.failed} 个插件未能读取上游版本：${pluginResult.value.failed_plugins.join('、')}`)
    }
    if (issues.length) setError(issues.join('；'))
    else setNotice(`已检查 DSH 和 ${pluginResult.status === 'fulfilled' ? pluginResult.value.checked : 0} 个插件`)
    } finally {
      setCheckingUpdates(false)
    }
  })
  const prepare = (version: string) => perform(() => startOperation('/api/releases/prepare', { version }))
  const switchRelease = (releaseId: string) => perform(() => startOperation('/api/releases/switch', { release_id: releaseId }))

  if (auth === null) {
    return <main className="bridge-page"><section className="bridge-card"><p>正在检查管理员会话…</p></section></main>
  }

  if (!auth.authenticated) {
    return (
      <main className="bridge-page bridge-login-page">
        <section className="bridge-card bridge-login-card">
          <div className="bridge-mark" aria-hidden="true">七</div>
          <p className="bridge-eyebrow">XIAOQI · DSH</p>
          <h1>管理员登录</h1>
          <p className="bridge-muted">登录后进入官方插件管理界面，并将配置发布给小七。</p>
          <form onSubmit={login} className="bridge-form">
            <label htmlFor="admin-password">管理员密码</label>
            <input id="admin-password" type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required />
            <button className="bridge-button bridge-button-primary" type="submit" disabled={working || !password}>登录</button>
          </form>
          {error && <p className="bridge-alert bridge-alert-error" role="alert">{error}</p>}
        </section>
      </main>
    )
  }

  const web = status?.official_web_profile
  const previousConfig = status?.config_history?.[0]
  const operationActive = operation ? ['queued', 'running'].includes(operation.status) : false

  return (
    <main className="bridge-page">
      <header className="bridge-header">
        <a className="bridge-brand" href={`${PREFIX}/`}><span className="bridge-mark">七</span><span>小七控制面板</span></a>
        <div className="bridge-header-actions">
          <button className={page === 'bridge' ? 'bridge-nav active' : 'bridge-nav'} onClick={() => setPage('bridge')}>插件发布</button>
          <button className={page === 'releases' ? 'bridge-nav active' : 'bridge-nav'} onClick={() => setPage('releases')}>版本维护</button>
          <button className="bridge-nav bridge-logout" onClick={logout} disabled={working}>退出</button>
        </div>
      </header>

      <section className="bridge-main">
        {page === 'bridge' ? (
          <>
            <div className="bridge-title-row">
              <div>
                <p className="bridge-eyebrow">官方 DSH Web</p>
                <h1>管理插件，然后应用到小七</h1>
                <p className="bridge-muted bridge-lead">插件安装、启用和配置由官方界面处理。完成后点“应用到小七”，新任务才会采用这些设置。</p>
              </div>
              <span className="bridge-version-pill">DSH {status?.dsh_version || '读取中'}</span>
            </div>

            <section className="bridge-card bridge-profile-card">
              <div className="bridge-profile-status">
                <span className={web?.ready ? 'bridge-status-dot ready' : 'bridge-status-dot'} />
                <div>
                  <strong>{web?.ready ? '官方 profile 已连接' : '正在读取官方 profile'}</strong>
                  <p className="bridge-muted">
                    {web?.installing
                      ? '官方插件安装正在进行，完成或取消后再发布。'
                      : web?.changed_since_publish
                        ? `当前有 ${web.enabled_bundle_count} 个启用插件束；变更尚未发布给小七。`
                        : `当前有 ${web?.enabled_bundle_count ?? '—'} 个启用插件束；与小七已发布配置一致。`}
                  </p>
                </div>
              </div>
              <div className="bridge-actions">
                <a className="bridge-button bridge-button-secondary" href={`${PREFIX}/api/web/launch`} target="_blank" rel="noreferrer">打开官方插件管理</a>
                <button className="bridge-button bridge-button-primary" onClick={publish} disabled={working || operationActive || Boolean(restoreConfirmation) || !web?.ready || web.installing}>
                  {operationActive ? '正在发布…' : '应用到小七'}
                </button>
                {previousConfig && <button className="bridge-button bridge-button-secondary" onClick={() => setRestoreConfirmation(previousConfig)} disabled={working || operationActive || Boolean(applyConfirmation)}>恢复上一配置</button>}
              </div>
            </section>
            {restoreConfirmation && (
              <section className="bridge-confirm-card" role="alert" aria-labelledby="restore-confirmation-title">
                <h2 id="restore-confirmation-title">确认恢复上一配置？</h2>
                <p>目标：{restoreConfirmation.config_id === 'builtin' ? '内置默认配置' : restoreConfirmation.config_id}{restoreConfirmation.config_revision !== undefined ? ` · 修订 ${restoreConfirmation.config_revision}` : ''}</p>
                <p>这会替换小七当前已发布的插件配置。正在执行的任务继续使用原配置，后续新任务使用恢复后的配置。</p>
                <div className="bridge-confirm-actions">
                  <button className="bridge-button bridge-button-primary" onClick={restorePrevious} disabled={working}>确认恢复</button>
                  <button className="bridge-button bridge-button-secondary" onClick={() => setRestoreConfirmation(null)} disabled={working}>取消</button>
                </div>
              </section>
            )}
            {applyConfirmation && (
              <section className="bridge-confirm-card" role="alert" aria-labelledby="apply-confirmation-title">
                <h2 id="apply-confirmation-title">兼容性未确认，仍可尝试应用</h2>
                <p>{applyConfirmation.warning}</p>
                <ul>{applyConfirmation.plugins.map((name) => <li key={name}>{name}</li>)}</ul>
                <p>应用后，新任务会尝试加载这些插件；插件可能无法启动或导致任务失败。当前任务不受影响，成功发布后可在这里恢复上一份配置。</p>
                <div className="bridge-confirm-actions">
                  <button className="bridge-button bridge-button-primary" onClick={confirmPluginApply} disabled={working || operationActive}>仍然应用到小七</button>
                  <button className="bridge-button bridge-button-secondary" onClick={() => setApplyConfirmation(null)} disabled={working}>先不应用</button>
                </div>
              </section>
            )}

            <section className="bridge-card bridge-runtime-card">
              <div><span className="bridge-label">小七当前配置</span><strong>{status?.config_id || '读取中'}</strong><small>修订 {status?.config_revision ?? '—'}</small></div>
              <div><span className="bridge-label">运行中任务</span><strong>{status?.active_tasks ?? '—'}</strong><small>排队 {status?.queued_tasks ?? '—'}</small></div>
              <div><span className="bridge-label">运行版本</span><strong>{status?.dsh_version || '读取中'}</strong><small>{status?.maintenance ? '维护中' : '服务正常'}</small></div>
            </section>
            <section className="bridge-card bridge-update-card" aria-labelledby="update-recommendations-title">
              <div className="bridge-update-heading">
                <div>
                  <span className="bridge-label">版本判断</span>
                  <h2 id="update-recommendations-title">现在是否需要更新</h2>
                  <p className="bridge-muted">分别查看 DSH 和插件；检查不会自动安装或发布。</p>
                </div>
                <button className="bridge-button bridge-button-secondary" onClick={checkUpdates} disabled={working}>
                  {checkingUpdates ? '正在检查…' : '检查更新'}
                </button>
              </div>
              {!recommendations ? (
                <p className="bridge-update-empty" role="status">
                  {error ? '暂时无法读取更新建议。检查服务连接后，可重新检查。' : '正在读取更新检查结果…'}
                </p>
              ) : (
                <div className="bridge-update-list">
                  <UpdateRecommendationRow title="DSH 运行环境" detail="小七当前使用的版本" recommendation={recommendations.dsh} />
                  {recommendations.plugins.length === 0 ? (
                    <p className="bridge-update-empty">官方插件 profile 中没有已安装的插件。</p>
                  ) : recommendations.plugins.map((plugin) => (
                    <UpdateRecommendationRow
                      key={plugin.name}
                      title={plugin.name}
                      detail={plugin.enabled ? '官方 profile · 已启用' : '官方 profile · 已关闭'}
                      recommendation={plugin.recommendation}
                      configurationHref={plugin.configuration_available ? pluginConfigurationHref(plugin.configuration_target) : undefined}
                    />
                  ))}
                </div>
              )}
              <p className="bridge-update-footnote">
                建议依据官方版本通道、更新说明和插件声明的 DSH 版本要求；这不是小七实际任务验证。上次检查时间与来源显示在每项详情中。更新和应用仍由你手动完成。
              </p>
            </section>
            <p className="bridge-footnote">发布会生成并校验新的只读 ACP 配置快照。发布失败会保留小七当前配置；正在回答的任务继续使用原配置。</p>
          </>
        ) : (
          <>
            <div className="bridge-title-row">
              <div>
                <p className="bridge-eyebrow">独立入口</p>
                <h1>DSH 版本维护</h1>
                <p className="bridge-muted bridge-lead">本页只维护运行版本。插件和 profile 设置请回到官方管理界面。</p>
              </div>
              <button className="bridge-button bridge-button-secondary" onClick={checkVersions} disabled={working}>检查官方版本</button>
            </div>
            <section className="bridge-card bridge-release-list">
              {releases.length === 0 ? <p className="bridge-muted">暂无版本记录。点击“检查官方版本”读取后再选择。</p> : releases.map((release) => (
                <article className="bridge-release-row" key={release.id}>
                  <div>
                    <strong>DSH {release.version}</strong>
                    <p className="bridge-muted">{release.current ? '当前运行' : release.prepared ? '已准备，可切换' : release.compatibility === 'compatible' ? '兼容性检查通过' : '兼容性尚未确认'}</p>
                  </div>
                  <div className="bridge-release-actions">
                    {!release.prepared && release.compatibility === 'compatible' && <button className="bridge-button bridge-button-secondary" onClick={() => prepare(release.version)} disabled={working}>准备版本</button>}
                    {release.prepared && !release.current && <button className="bridge-button bridge-button-primary" onClick={() => switchRelease(release.id)} disabled={working || operationActive}>切换版本</button>}
                  </div>
                </article>
              ))}
            </section>
            <a className="bridge-back-link" href={`${PREFIX}/`} onClick={(event) => { event.preventDefault(); setPage('bridge') }}>返回插件发布</a>
          </>
        )}

        {error && <p className="bridge-alert bridge-alert-error" role="alert">{error}</p>}
        {notice && <p className="bridge-alert bridge-alert-success" role="status">{notice}</p>}
        {operationActive && operation && <div className="bridge-operation" role="status"><strong>{operation.step || '正在处理'}</strong><span>{operation.message}</span></div>}
        {operation && ['failed', 'cancelled'].includes(operation.status) && <div className="bridge-operation bridge-operation-error"><strong>{operation.status === 'failed' ? '操作失败' : '操作已取消'}</strong><span>{operation.error || operation.message}</span></div>}
      </section>
    </main>
  )
}

function UpdateRecommendationRow({ title, detail, recommendation, configurationHref }: {
  title: string
  detail: string
  recommendation: Recommendation
  configurationHref?: string
}) {
  const tone = recommendation.status === 'current'
    ? 'current'
    : recommendation.status === 'available' || recommendation.status === 'priority'
      ? 'available'
      : recommendation.status === 'preview' || recommendation.status === 'blocked' || recommendation.status === 'failed'
        ? 'caution'
        : 'unknown'
  const compatibility = recommendation.compatibility === 'compatible'
    ? '版本要求匹配'
    : recommendation.compatibility === 'incompatible'
      ? '版本要求不匹配'
      : '兼容性未确认'
  const checkedAt = recommendation.checked_at
    ? new Date(recommendation.checked_at).toLocaleString('zh-CN', { dateStyle: 'short', timeStyle: 'short' })
    : '未检查'

  return (
    <article className="bridge-update-row">
      <div className="bridge-update-row-heading">
        <div>
          {configurationHref ? (
            <a className="bridge-plugin-config-link" href={configurationHref} target="_blank" rel="noreferrer" title="打开 DSH 官方插件配置界面">{title}</a>
          ) : <strong>{title}</strong>}
          <small>{detail}</small>
        </div>
        <div className="bridge-plugin-config-status">
          {configurationHref ? (
            <a className="bridge-button bridge-button-secondary" href={configurationHref} target="_blank" rel="noreferrer">配置插件</a>
          ) : (
            <span className="bridge-config-unavailable">未配置，不可使用</span>
          )}
          <span className={`bridge-update-badge bridge-update-badge-${tone}`}>{recommendation.label}</span>
        </div>
      </div>
      <p className="bridge-update-reason">{recommendation.reason}</p>
      <p className="bridge-update-versions">
        当前 {recommendation.current_version || '未知'}
        {recommendation.candidate_version ? ` · 官方候选 ${recommendation.candidate_version}` : ''}
        {recommendation.candidate_version ? ` · ${compatibility}` : ''}
      </p>
      <details className="bridge-update-details">
        <summary>检查详情</summary>
        <p>来源：{recommendation.source}</p>
        <p>上次检查：{checkedAt}</p>
        {recommendation.notes && <p className="bridge-update-notes">{recommendation.notes}</p>}
        {recommendation.release_url && <a href={recommendation.release_url} target="_blank" rel="noreferrer">查看官方发行说明</a>}
      </details>
    </article>
  )
}

export default App
