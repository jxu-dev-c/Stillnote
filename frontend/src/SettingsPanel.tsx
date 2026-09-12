import { useState } from 'react'
import { ArrowDownToLine, Check, ChevronLeft } from 'lucide-react'
import { Feedback, Spinner } from './components'
import AgentIcon from './AgentIcon'
import { agentDefaults, api, json, languages, speechReady } from './types'
import type { Settings } from './types'

export default function SettingsPanel({ settings, onSave, onBack, onRefresh }: { settings: Settings | null; onSave: (settings: Settings) => void; onBack: () => void; onRefresh: () => Promise<void> }) {
  const [model, setModel] = useState(settings?.transcription.model || 'moss-0.9b')
  const [language, setLanguage] = useState(settings?.transcription.language || 'auto')
  const [speakers, setSpeakers] = useState(settings?.transcription.speaker_count?.toString() || '')
  const [provider, setProvider] = useState<Settings['summary']['provider']>(settings?.summary.provider || 'codex')
  const [summaryModel, setSummaryModel] = useState(settings?.summary.model || agentDefaults[provider].model)
  const [effort, setEffort] = useState<Settings['summary']['reasoning_effort']>(settings?.summary.reasoning_effort || 'high')
  const [saving, setSaving] = useState(false)
  const [installing, setInstalling] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const selectedModel = settings?.speech.models?.find(item => item.id === model)
  const ready = model === settings?.transcription.model ? speechReady(settings?.speech) : Boolean(selectedModel?.installed && settings?.speech.dependencies_ready)
  const modelDetail = model === settings?.transcription.model ? settings?.speech.detail : selectedModel?.installed ? 'Downloaded. Save to use this model.' : 'Download this model to transcribe offline.'
  const setupBusy = installing || settings?.speech.installing
  async function save() {
    setError(null); setSuccess(null); setSaving(true)
    try {
      const next = await api<Settings>('/settings', json('PUT', { transcription: { model, language, speaker_count: speakers ? Number(speakers) : null }, summary: { provider, model: summaryModel, reasoning_effort: effort } }))
      onSave(next); setSummaryModel(next.summary.model); setSuccess('Settings saved.'); return next
    } catch (err) { setError((err as Error).message); return null }
    finally { setSaving(false) }
  }
  async function install() {
    setError(null); setSuccess(null)
    const next = await save()
    if (!next) return
    setInstalling(true); setSuccess(null)
    try { await api('/models/install', json('POST', { model })); await onRefresh(); setSuccess('Download started.') }
    catch (err) { setError((err as Error).message) }
    finally { setInstalling(false) }
  }
  function changeProvider(value: Settings['summary']['provider']) {
    setProvider(value); setSummaryModel(agentDefaults[value].model); setEffort('high')
  }
  return <div className="settings-page page-enter">
    <button className="text-button back-button" onClick={onBack}><ChevronLeft size={16} />Back</button>
    <div className="page-heading"><h1>Settings</h1></div>
    <Feedback error={error} success={success} />
    <section className="settings-section">
      <div className="section-intro"><h2>Transcription</h2></div>
      <div className="form-grid settings-grid">
        <label className="field">Speech model
          <select value={model} onChange={event => setModel(event.target.value)} disabled={Boolean(setupBusy)}>
            {settings?.speech.models?.map(item => <option key={item.id} value={item.id}>{item.name} · {item.tier}</option>)}
          </select>
          {selectedModel && <small>{(selectedModel.download_mb / 1000).toFixed(1)} GB · <a href={selectedModel.url} target="_blank" rel="noreferrer">Model details</a></small>}
        </label>
        <label className="field">Language
          <select value={language} onChange={event => setLanguage(event.target.value)}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
        </label>
        <label className="field">Speakers
          <select value={speakers} onChange={event => setSpeakers(event.target.value)}><option value="">Detect automatically</option>{Array.from({ length: 10 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} speaker{i ? 's' : ''}</option>)}</select>
        </label>
      </div>
      <div className={`model-state ${ready ? 'ready' : ''}`}>
        <div>
          <strong>{setupBusy ? 'Downloading…' : ready ? model === settings?.transcription.model ? 'Ready · runs locally' : 'Downloaded · save to use' : 'Setup needed'}</strong>
          {(!ready || setupBusy) && <p>{modelDetail || 'Download a speech model to transcribe offline.'}</p>}
          {settings?.speech.error && <p className="inline-error">{settings.speech.error}</p>}
          {setupBusy && typeof settings?.speech.progress === 'number' && <progress max={100} value={settings.speech.progress} aria-label="Model setup progress" />}
        </div>
        <button className="button secondary" onClick={() => void install()} disabled={Boolean(setupBusy) || saving}>
          {setupBusy ? <Spinner /> : <ArrowDownToLine size={16} />}{setupBusy ? 'Downloading…' : ready ? 'Check / repair' : 'Download model'}
        </button>
      </div>
    </section>
    <section className="settings-section">
      <div className="section-intro"><h2>Summaries</h2></div>
      <div className="provider-grid agent-providers">
        {(Object.keys(agentDefaults) as Settings['summary']['provider'][]).map(value => <button className={`provider-card ${provider === value ? 'selected' : ''}`} key={value} onClick={() => changeProvider(value)} aria-pressed={provider === value}>
          <span className="provider-identity"><AgentIcon provider={value} /><strong>{agentDefaults[value].label}</strong></span>{provider === value && <Check size={15} />}
        </button>)}
      </div>
      <div className="form-grid">
        <label className="field">Model<input value={summaryModel} onChange={event => setSummaryModel(event.target.value)} placeholder={agentDefaults[provider].model} autoComplete="off" spellCheck={false} /></label>
        <label className="field">Thinking effort<select value={effort} onChange={event => setEffort(event.target.value as typeof effort)}><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option></select></label>
      </div>
      <div className={`model-state ${settings?.agents[provider]?.installed ? 'ready' : ''}`}>
        <div><strong>{settings?.agents[provider]?.installed ? `${agentDefaults[provider].label} installed` : `Set up ${agentDefaults[provider].label}`}</strong><p>{settings?.agents[provider]?.installed ? 'Uses your CLI sign-in.' : 'Install the CLI, sign in, then restart Stillnote.'}</p></div>
        <button className="text-button" onClick={() => void onRefresh().catch(err => setError((err as Error).message))}>Check again</button>
      </div>
      <p className="settings-note">Summaries send transcript text to the model provider. You’ll confirm each time.</p>
    </section>
    <div className="settings-bottom"><button className="button primary" onClick={() => void save()} disabled={saving || Boolean(setupBusy)}>{saving ? <Spinner /> : <Check size={17} />}{saving ? 'Saving…' : 'Save settings'}</button></div>
  </div>
}
