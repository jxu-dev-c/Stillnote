import { useState } from 'react'
import { ArrowDownToLine, AudioLines, Check, ChevronLeft, Cpu, Globe2, HardDrive, LockKeyhole, ShieldCheck, Sparkles } from 'lucide-react'
import { Feedback, PrivacyBadge, Spinner } from './components'
import { api, json, languages, speechReady } from './types'
import type { Settings } from './types'

export default function SettingsPanel({ settings, onSave, onBack, onRefresh }: { settings: Settings | null; onSave: (settings: Settings) => void; onBack: () => void; onRefresh: () => Promise<void> }) {
  const [model, setModel] = useState(settings?.transcription.model || 'moss-0.9b')
  const [language, setLanguage] = useState(settings?.transcription.language || 'auto')
  const [speakers, setSpeakers] = useState(settings?.transcription.speaker_count?.toString() || '')
  const [provider, setProvider] = useState<Settings['summary']['provider']>(settings?.summary.provider || 'local')
  const [summaryModel, setSummaryModel] = useState(settings?.summary.model || '')
  const [url, setUrl] = useState(settings?.summary.base_url || '')
  const [apiKey, setApiKey] = useState('')
  const [removeKey, setRemoveKey] = useState(false)
  const [saving, setSaving] = useState(false)
  const [installing, setInstalling] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const selectedModel = settings?.speech.models?.find(item => item.id === model)
  const ready = model === settings?.transcription.model ? speechReady(settings?.speech) : Boolean(selectedModel?.installed && settings?.speech.dependencies_ready)
  const modelDetail = model === settings?.transcription.model ? settings?.speech.detail : selectedModel?.installed ? `${selectedModel.name} is downloaded. Save preferences to use it.` : 'Download this model to transcribe offline.'
  const setupBusy = installing || settings?.speech.installing
  async function save() {
    setError(null); setSuccess(null); setSaving(true)
    try {
      const next = await api<Settings>('/settings', json('PUT', { transcription: { model, language, speaker_count: speakers ? Number(speakers) : null }, summary: { provider, model: summaryModel, base_url: url, ...(apiKey ? { api_key: apiKey } : removeKey ? { api_key: '' } : {}) } }))
      onSave(next); setApiKey(''); setRemoveKey(false); setSuccess('Your preferences have been saved on this device.'); return next
    } catch (err) { setError((err as Error).message); return null }
    finally { setSaving(false) }
  }
  async function install() {
    setError(null); setSuccess(null)
    const next = await save()
    if (!next) return
    setInstalling(true); setSuccess(null)
    try { await api('/models/install', json('POST', { model })); await onRefresh(); setSuccess('Model download started. You can keep using the app while setup completes.') }
    catch (err) { setError((err as Error).message) }
    finally { setInstalling(false) }
  }
  function changeProvider(value: Settings['summary']['provider']) {
    setProvider(value); setApiKey(''); setRemoveKey(value !== settings?.summary.provider)
    const defaults = { local: ['', ''], ollama: ['llama3.2', 'http://127.0.0.1:11434'], 'openai-compatible': ['', 'https://api.openai.com/v1'], anthropic: ['', 'https://api.anthropic.com'] }
    setSummaryModel(defaults[value][0]); setUrl(defaults[value][1])
  }
  return <div className="settings-page page-enter"><button className="text-button back-button" onClick={onBack}><ChevronLeft size={16} />Back to meetings</button><div className="page-heading"><div><p className="eyebrow">MAKE IT YOURS</p><h1>Settings</h1><p>A quiet workspace, configured your way.</p></div><PrivacyBadge compact /></div>
    <Feedback error={error} success={success} />
    <section className="settings-section"><div className="section-intro"><span className="section-icon"><AudioLines size={20} /></span><div><h2>Local transcription</h2><p>Audio is processed on your computer, including speaker detection.</p></div></div>
      <div className={`model-state ${ready ? 'ready' : ''}`}><span className="model-state-icon">{setupBusy ? <Spinner size={22} /> : ready ? <Check size={22} /> : <ArrowDownToLine size={22} />}</span><div><strong>{setupBusy ? 'Preparing your local models' : ready ? 'Your local models are ready' : 'Set up your speech models'}</strong><p>{modelDetail || (ready ? 'Ready to transcribe and distinguish speakers offline.' : 'A one-time download enables offline transcription and speaker detection. This does not upload any recordings.')}</p>{settings?.speech.error && <p className="inline-error">{settings.speech.error}</p>}{setupBusy && typeof settings?.speech.progress === 'number' && <progress max={100} value={settings.speech.progress} aria-label="Model setup progress" />}</div><span className={`status-pill ${ready ? 'green' : ''}`}>{setupBusy ? 'Setting up' : ready ? 'Ready' : 'Setup needed'}</span></div>
      <div className="form-grid settings-grid"><label className="field">Speech model<select value={model} onChange={event => setModel(event.target.value)} disabled={Boolean(setupBusy)}>{settings?.speech.models?.map(item => <option key={item.id} value={item.id}>{item.name} · {item.tier}</option>)}</select><small>Fast / light ←→ Quality</small>{selectedModel && <small>{(selectedModel.download_mb / 1000).toFixed(1)} GB download · {selectedModel.languages}<br />{selectedModel.timing} · <a href={selectedModel.url} target="_blank" rel="noreferrer">Hugging Face</a></small>}<small>Larger models need more memory and processing time.</small></label><label className="field">Default language<select value={language} onChange={event => setLanguage(event.target.value)}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label className="field">Default speaker count<select value={speakers} onChange={event => setSpeakers(event.target.value)}><option value="">Detect automatically</option>{Array.from({ length: 10 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} speaker{i ? 's' : ''}</option>)}</select><small>Optional hint for the model; speaker counts are estimates.</small></label></div>
      <div className="settings-footer"><span><HardDrive size={15} />Models are stored on this computer</span><button className="button secondary" onClick={() => void install()} disabled={Boolean(setupBusy) || saving}>{setupBusy ? <Spinner /> : <ArrowDownToLine size={16} />}{setupBusy ? 'Downloading models…' : ready && model === settings?.transcription.model ? 'Check / repair models' : 'Download & set up models'}</button></div>
    </section>
    <section className="settings-section"><div className="section-intro"><span className="section-icon lavender"><Sparkles size={20} /></span><div><h2>Meeting summaries</h2><p>Use the built-in local summary or connect a model of your choice.</p></div></div>
      <div className="provider-grid">{([{ value: 'local', label: 'Built-in', detail: 'Local, extractive summary', Icon: Cpu }, { value: 'ollama', label: 'Ollama', detail: 'Your local language model', Icon: HardDrive }, { value: 'openai-compatible', label: 'OpenAI compatible', detail: 'Connect a provider', Icon: Globe2 }, { value: 'anthropic', label: 'Anthropic', detail: 'Connect Claude', Icon: Sparkles }] as const).map(({ value, label, detail, Icon }) => <button className={`provider-card ${provider === value ? 'selected' : ''}`} key={value} onClick={() => changeProvider(value)} aria-pressed={provider === value}><span><Icon size={19} />{provider === value && <Check size={15} />}</span><strong>{label}</strong><small>{detail}</small></button>)}</div>
      {provider === 'local' ? <div className="info-box"><ShieldCheck size={19} /><p>The built-in summary picks out important points from the transcript without sending data anywhere. It works immediately and doesn’t require an API key or language model.</p></div> : <>
        <div className="form-grid"><label className="field">Model name<input value={summaryModel} onChange={event => setSummaryModel(event.target.value)} placeholder={provider === 'ollama' ? 'e.g. llama3.2' : 'Enter a model supported by your provider'} autoComplete="off" /><small>{provider === 'ollama' ? 'Install this model in Ollama before generating a summary.' : 'Use the exact model ID from your provider.'}</small></label><label className="field">Endpoint URL<input value={url} onChange={event => setUrl(event.target.value)} type="url" spellCheck={false} autoComplete="off" /></label></div>
        <label className="field">API key <span className="optional">{provider === 'ollama' ? 'optional' : settings?.summary.api_key_set && !removeKey ? 'saved on this device' : ''}</span><input type="password" value={apiKey} onChange={event => setApiKey(event.target.value)} placeholder={settings?.summary.api_key_set && !removeKey ? 'Leave blank to keep saved key' : 'Enter API key'} autoComplete="new-password" /></label>
        {settings?.summary.api_key_set && <label className="check-option"><input type="checkbox" checked={removeKey} onChange={event => setRemoveKey(event.target.checked)} />Remove the saved API key</label>}
        <div className="info-box"><LockKeyhole size={19} /><p>Audio and transcription always stay local. When a summary uses a remote endpoint, you’ll be asked before the transcript is sent. Credentials are stored locally.</p></div>
      </>}
    </section>
    <div className="settings-bottom"><p><ShieldCheck size={16} />Private by default. Always your choice.</p><button className="button primary" onClick={() => void save()} disabled={saving || Boolean(setupBusy)}>{saving ? <Spinner /> : <Check size={17} />}{saving ? 'Saving…' : 'Save preferences'}</button></div>
  </div>
}
