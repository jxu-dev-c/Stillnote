import { useEffect, useRef, useState } from 'react'
import { AudioLines, Mic, Monitor, Pause, Play, RefreshCw, Square, X } from 'lucide-react'
import { Feedback, Modal, Spinner } from './components'
import { api, duration, json, languages, speechReady } from './types'
import type { Meeting, Settings } from './types'
import './recording.css'

export type CaptureCapabilities = {
  available: boolean; reason: string | null;
  microphones: { id: string; name: string }[]; displays: { id: number; name: string }[];
  default_display_id: number | null;
}
export type CaptureSession = {
  id: string; status: 'starting' | 'recording' | 'paused' | 'stopping' | 'stopped'; elapsed: number; error: string | null;
  levels: Record<string, { rms: number; peak: number }>;
  options: { title: string; language: string; speaker_count: number | null; microphone_id: string; display_id: number | null; system_audio: boolean; screen_video: boolean };
}

type Props = {
  capabilities: CaptureCapabilities; initialSession: CaptureSession | null; settings: Settings | null;
  onClose: () => void; onSaved: (meeting: Meeting) => void; onBrowser: () => void;
}
function LevelMeter({ label, level, paused }: { label: string; level?: { rms: number; peak: number }; paused: boolean }) {
  const rms = paused ? 0 : level?.rms || 0
  const peak = paused ? 0 : level?.peak || 0
  const percent = Math.max(0, Math.min(100, (20 * Math.log10(Math.max(rms, 0.001)) + 60) / 60 * 100))
  return <div className="capture-meter"><div><span>{label}</span><small>{paused ? 'Paused' : peak >= 0.98 ? 'Input clipping' : rms > 0.002 ? 'Receiving audio' : 'Quiet'}</small></div><meter min={0} max={100} value={percent} aria-label={`${label} input level`} /><span className="capture-meter-value">{rms > 0.001 ? `${Math.round(20 * Math.log10(rms))} dB` : '−∞ dB'}</span></div>
}
export default function NativeRecordingModal({ capabilities, initialSession, settings, onClose, onSaved, onBrowser }: Props) {
  const [devices, setDevices] = useState(capabilities)
  const [session, setSession] = useState(initialSession)
  const [title, setTitle] = useState('')
  const [language, setLanguage] = useState(settings?.transcription.language || 'auto')
  const [speakerCount, setSpeakerCount] = useState(settings?.transcription.speaker_count?.toString() || '')
  const [microphone, setMicrophone] = useState('')
  const [display, setDisplay] = useState<number | null>(capabilities.default_display_id)
  const [systemAudio, setSystemAudio] = useState(true)
  const [screenVideo, setScreenVideo] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [discard, setDiscard] = useState(false)
  const mounted = useRef(true)
  const operation = useRef(false)
  const ready = speechReady(settings?.speech)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  useEffect(() => {
    if (!session) return
    let cancelled = false
    let timer = 0
    const poll = async () => {
      try {
        const current = await api<CaptureSession | null>('/recordings/current')
        if (!cancelled && !operation.current) {
          setSession(current)
          if (!current) setError('This recording was saved or discarded in another window.')
        }
      } catch (err) { if (!cancelled) setError((err as Error).message + ' The native recording may still be running. Reconnect to stop or save it.') }
      if (!cancelled) timer = window.setTimeout(poll, 350)
    }
    timer = window.setTimeout(poll, 350)
    return () => { cancelled = true; clearTimeout(timer) }
  }, [session?.id])
  useEffect(() => {
    if (!session && !busy) return
    const protect = (event: BeforeUnloadEvent) => event.preventDefault()
    window.addEventListener('beforeunload', protect)
    return () => window.removeEventListener('beforeunload', protect)
  }, [Boolean(session), busy])

  async function run(action: () => Promise<void>) {
    if (operation.current) return
    operation.current = true; setBusy(true); setError(null)
    try { await action() }
    catch (err) { if (mounted.current) setError((err as Error).message) }
    finally { operation.current = false; if (mounted.current) setBusy(false) }
  }
  async function refresh() {
    await run(async () => {
      const result = await api<CaptureCapabilities>('/recordings/capabilities')
      setDevices(result)
      if (microphone && !result.microphones.some(device => device.id === microphone)) setMicrophone('')
      if (!result.displays.some(device => device.id === display)) setDisplay(result.default_display_id)
    })
  }
  async function start() {
    await run(async () => {
      try {
        const result = await api<CaptureSession>('/recordings', json('POST', {
          title: title.trim() || `Meeting · ${new Date().toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}`,
          language, speaker_count: speakerCount ? Number(speakerCount) : null,
          microphone_id: microphone, display_id: display, system_audio: systemAudio, screen_video: screenVideo,
        }))
        setSession(result)
      } catch (err) {
        // A lost start response must not strand an already-running native recorder.
        const existing = await api<CaptureSession | null>('/recordings/current').catch(() => null)
        if (existing) setSession(existing)
        throw err
      }
    })
  }
  async function finish() {
    if (!session) return
    await run(async () => {
      let meeting = await api<Meeting>(`/recordings/${session.id}/stop`, json('POST', {}))
      if (ready && !meeting.error) {
        try { meeting = await api<Meeting>(`/meetings/${meeting.id}/transcribe`, json('POST', { language: meeting.language, speaker_count: meeting.speaker_count })) }
        catch { /* The recording remains saved if transcription cannot start. */ }
      }
      onSaved(meeting)
    })
  }
  function requestClose() { if (busy) return; if (session) setDiscard(true); else onClose() }
  const paused = session?.status === 'paused'
  const stopped = session?.status === 'stopped'
  const starting = session?.status === 'starting'
  const stopping = session?.status === 'stopping'
  return <Modal title="Record a meeting" onClose={requestClose} closeDisabled={busy}>
    <h2>New recording</h2>
    <Feedback error={error || session?.error} />
    {discard ? <div className="discard-box"><strong>Discard this recording?</strong><p>Stops recording and deletes unsaved audio and video.</p><div className="button-row"><button className="button secondary" disabled={busy} onClick={() => setDiscard(false)}>Keep recording</button><button className="button danger" disabled={busy} onClick={() => void run(async () => { if (session) await api(`/recordings/${session.id}`, { method: 'DELETE' }); onClose() })}>{busy ? <Spinner /> : null}Discard recording</button></div></div> : session ? <div className={`recorder ${paused ? 'is-paused' : ''}`}>
      <span className="recording-state"><i />{starting ? 'WAITING FOR MACOS PERMISSIONS' : stopping ? 'FINISHING RECORDING' : stopped ? 'READY TO SAVE' : paused ? 'PAUSED' : 'RECORDING'}</span>
      <div className="recording-clock">{duration(session.elapsed)}</div>
      <div className="capture-levels"><LevelMeter label="Microphone" level={session.levels.microphone} paused={Boolean(paused || stopped)} />{session.options.system_audio && <LevelMeter label="System audio" level={session.levels.system} paused={Boolean(paused || stopped)} />}</div>
      <p>{session.options.title}{session.options.screen_video && <span className="capture-screen-status"><Monitor size={14} />Screen video enabled</span>}</p>
      {starting && <p className="capture-hint">Allow Microphone and Screen &amp; System Audio Recording in the macOS permission prompts. If access was denied, enable Stillnote Capture in System Settings → Privacy &amp; Security.</p>}
      <div className="recorder-buttons">{!stopped && !starting && !stopping && <button className="button secondary" disabled={busy} onClick={() => void run(async () => { await api(`/recordings/${session.id}/${paused ? 'resume' : 'pause'}`, json('POST', {})) })}>{paused ? <Play size={16} /> : <Pause size={16} />}{paused ? 'Resume' : 'Pause'}</button>}
        {!starting && <button className="button primary" disabled={busy || stopping} onClick={() => void finish()}>{busy || stopping ? <Spinner /> : <Square size={14} fill="currentColor" />}{busy ? 'Saving…' : ready ? 'Finish & transcribe' : 'Save recording'}</button>}
      </div>
      <button className="text-button muted" disabled={busy} onClick={() => setDiscard(true)}><X size={13} />{starting ? 'Cancel capture' : 'Discard recording'}</button>
      <p className="capture-hint">After a reload, open New recording to reconnect.</p>
    </div> : <>
      {!devices.available && <p className="capture-unavailable" role="status">{devices.reason}</p>}
      <label className="field">Meeting title <span className="optional">optional</span><input value={title} onChange={event => setTitle(event.target.value)} placeholder="Untitled meeting" disabled={busy} maxLength={200} /></label>
      <div className="capture-source-heading"><button className="text-button" onClick={() => void refresh()} disabled={busy}><RefreshCw size={13} />Refresh devices</button></div>
      <label className="field">Microphone<select value={microphone} onChange={event => setMicrophone(event.target.value)} disabled={busy || !devices.available}><option value="">System default microphone</option>{devices.microphones.map(device => <option key={device.id} value={device.id}>{device.name}</option>)}</select></label>
      <label className="toggle-option"><AudioLines size={19} /><span><strong>Include system audio</strong></span><input type="checkbox" checked={systemAudio} onChange={event => setSystemAudio(event.target.checked)} disabled={busy} /><span className="toggle" aria-hidden="true" /></label>
      <label className="toggle-option"><Monitor size={19} /><span><strong>Record screen video</strong></span><input type="checkbox" checked={screenVideo} onChange={event => setScreenVideo(event.target.checked)} disabled={busy} /><span className="toggle" aria-hidden="true" /></label>
      {screenVideo && <label className="field">Display to record<select value={display ?? ''} onChange={event => setDisplay(Number(event.target.value))} disabled={busy || !devices.available}>{devices.displays.map(device => <option key={device.id} value={device.id}>{device.name}</option>)}</select></label>}
      <div className="form-grid"><label className="field">Language<select value={language} onChange={event => setLanguage(event.target.value)} disabled={busy}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label className="field">Speakers<select value={speakerCount} onChange={event => setSpeakerCount(event.target.value)} disabled={busy}><option value="">Detect automatically</option>{Array.from({ length: 10 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} speaker{i ? 's' : ''}</option>)}</select></label></div>
      <button className="button primary full start-recording" disabled={busy || !devices.available} onClick={() => void start()}>{busy ? <Spinner /> : <Mic size={17} />}{busy ? 'Starting…' : 'Start recording'}</button>
      <button className="text-button capture-browser" onClick={onBrowser} disabled={busy}>Use browser recording</button>
      {!ready && <p className="setup-hint">Download a speech model in Settings to transcribe later.</p>}
    </>}
  </Modal>
}
