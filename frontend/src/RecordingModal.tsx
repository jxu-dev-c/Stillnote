import { useEffect, useRef, useState } from 'react'
import { ArrowUpRight, AudioLines, Check, Mic, Monitor, Pause, Play, Square, Upload, X } from 'lucide-react'
import { Modal, PrivacyBadge, Spinner, Feedback } from './components'
import { api, duration, json, languages, speechReady } from './types'
import type { Meeting, Settings } from './types'

type Props = { mode: 'record' | 'import'; settings: Settings | null; onClose: () => void; onSaved: (meeting: Meeting) => void }
export default function RecordingModal({ mode, settings, onClose, onSaved }: Props) {
  const [title, setTitle] = useState('')
  const [language, setLanguage] = useState(settings?.transcription.language || 'auto')
  const [speakerCount, setSpeakerCount] = useState(settings?.transcription.speaker_count?.toString() || '')
  const [sharedAudio, setSharedAudio] = useState(false)
  const [file, setFile] = useState<File | null>(null)
  const [status, setStatus] = useState<'idle' | 'starting' | 'recording' | 'paused' | 'saving'>('idle')
  const [elapsed, setElapsed] = useState(0)
  const [levels, setLevels] = useState<number[]>(Array(38).fill(4))
  const [error, setError] = useState<string | null>(null)
  const [discard, setDiscard] = useState(false)
  const [retryRecording, setRetryRecording] = useState<{ blob: Blob; name: string } | null>(null)
  const recorder = useRef<MediaRecorder | null>(null)
  const streams = useRef<MediaStream[]>([])
  const context = useRef<AudioContext | null>(null)
  const analyser = useRef<AnalyserNode | null>(null)
  const animation = useRef<number>(0)
  const chunks = useRef<Blob[]>([])
  const captureStart = useRef(0)
  const elapsedBefore = useRef(0)
  const shouldDiscard = useRef(false)
  const mounted = useRef(true)
  const currentStatus = useRef(status)
  currentStatus.current = status
  const active = status === 'recording' || status === 'paused'
  const ready = speechReady(settings?.speech)
  function cleanup() {
    cancelAnimationFrame(animation.current)
    streams.current.forEach(stream => stream.getTracks().forEach(track => track.stop()))
    streams.current = []
    recorder.current?.stream.getTracks().forEach(track => track.stop())
    if (context.current) void context.current.close().catch(() => {})
    context.current = null; analyser.current = null
  }
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; shouldDiscard.current = true; if (recorder.current?.state !== 'inactive') recorder.current?.stop(); cleanup() } }, [])
  useEffect(() => {
    if (!active) return
    const interval = window.setInterval(() => { if (currentStatus.current === 'recording') setElapsed(elapsedBefore.current + (Date.now() - captureStart.current) / 1000) }, 200)
    return () => clearInterval(interval)
  }, [active])
  useEffect(() => {
    if (!active && status !== 'saving' && status !== 'starting' && !retryRecording) return
    const preventUnload = (event: BeforeUnloadEvent) => { event.preventDefault() }
    window.addEventListener('beforeunload', preventUnload)
    return () => window.removeEventListener('beforeunload', preventUnload)
  }, [active, status, retryRecording])

  async function save(blob: Blob, name: string) {
    setStatus('saving'); setError(null)
    const body = new FormData()
    body.append('file', blob, name)
    body.append('title', title.trim() || (mode === 'import' ? name.replace(/\.[^.]+$/, '') : `Meeting · ${new Date().toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}`))
    body.append('language', language)
    if (speakerCount) body.append('speaker_count', speakerCount)
    try {
      const meeting = await api<Meeting>('/meetings', { method: 'POST', body })
      if (ready) {
        try { onSaved(await api<Meeting>(`/meetings/${meeting.id}/transcribe`, json('POST', { language, speaker_count: speakerCount ? Number(speakerCount) : null }))) }
        catch { onSaved(meeting) }
      } else onSaved(meeting)
    } catch (err) { if (mounted.current) { setError((err as Error).message); setStatus('idle'); if (mode === 'record') setRetryRecording({ blob, name }) } }
  }
  async function start() {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') { setError('Recording needs a browser with microphone access. Open Stillnote at localhost in a recent Chrome, Edge, Firefox, or Safari browser.'); return }
    setStatus('starting'); setError(null); shouldDiscard.current = false
    try {
      if (sharedAudio) {
        const display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true })
        if (!mounted.current || shouldDiscard.current) { display.getTracks().forEach(track => track.stop()); return }
        streams.current.push(display)
        if (!display.getAudioTracks().length) throw new Error('No shared audio was selected. Choose a browser tab and enable “Share tab audio,” or turn off shared audio to record your microphone.')
        display.getAudioTracks()[0].onended = () => { if (mounted.current && !shouldDiscard.current && ['recording', 'paused'].includes(currentStatus.current)) { setSharedAudio(false); setError('Audio sharing ended. Recording is continuing with your microphone only.') } }
      }
      const microphone = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } })
      if (!mounted.current || shouldDiscard.current) { microphone.getTracks().forEach(track => track.stop()); cleanup(); return }
      streams.current.push(microphone)
      const audioContext = new AudioContext()
      context.current = audioContext
      await audioContext.resume()
      if (!mounted.current || shouldDiscard.current) { cleanup(); return }
      const destination = audioContext.createMediaStreamDestination()
      const meter = audioContext.createAnalyser(); meter.fftSize = 256
      analyser.current = meter
      for (const stream of streams.current) {
        const audioStream = new MediaStream(stream.getAudioTracks())
        const source = audioContext.createMediaStreamSource(audioStream)
        source.connect(destination); source.connect(meter)
      }
      const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'].find(type => MediaRecorder.isTypeSupported(type))
      const capture = new MediaRecorder(destination.stream, mimeType ? { mimeType } : undefined)
      recorder.current = capture; chunks.current = []
      capture.ondataavailable = event => { if (event.data.size > 0) chunks.current.push(event.data) }
      capture.onerror = () => { setError('The microphone recorder stopped unexpectedly. Try saving the captured audio.'); if (capture.state !== 'inactive') capture.stop() }
      capture.onstop = () => {
        const blob = new Blob(chunks.current, { type: capture.mimeType })
        cleanup()
        if (!shouldDiscard.current && mounted.current) {
          if (!blob.size) { setStatus('idle'); setError('The recording was empty. Please check your microphone and try again.'); return }
          void save(blob, `meeting-${Date.now()}.${capture.mimeType.includes('mp4') ? 'm4a' : capture.mimeType.includes('ogg') ? 'ogg' : 'webm'}`)
        }
      }
      microphone.getAudioTracks()[0].onended = () => { if (capture.state !== 'inactive' && !shouldDiscard.current) capture.stop() }
      capture.start(1000); captureStart.current = Date.now(); elapsedBefore.current = 0; setElapsed(0); setStatus('recording')
      const data = new Uint8Array(meter.frequencyBinCount)
      let lastDraw = 0
      const draw = (time: number) => {
        if (time - lastDraw > 90) {
          meter.getByteFrequencyData(data)
          setLevels(Array.from({ length: 38 }, (_, index) => currentStatus.current === 'paused' ? 4 : Math.max(4, data[Math.floor(index * 1.8) + 1] / 255 * 90)))
          lastDraw = time
        }
        animation.current = requestAnimationFrame(draw)
      }
      animation.current = requestAnimationFrame(draw)
    } catch (err) {
      cleanup(); if (!mounted.current) return; setStatus('idle')
      const problem = err as Error
      setError(problem.name === 'NotAllowedError' ? 'Microphone or screen-sharing permission was not granted. Allow access in your browser, then try again.' : problem.name === 'NotFoundError' ? 'No microphone was found. Connect a microphone and try again.' : problem.message)
    }
  }
  function pauseResume() {
    if (status === 'recording') { recorder.current?.pause(); elapsedBefore.current += (Date.now() - captureStart.current) / 1000; setElapsed(elapsedBefore.current); setStatus('paused') }
    else { recorder.current?.resume(); captureStart.current = Date.now(); setStatus('recording') }
  }
  function discardRecording() { shouldDiscard.current = true; if (recorder.current?.state !== 'inactive') recorder.current?.stop(); cleanup(); onClose() }
  function requestClose() { if (active || retryRecording) setDiscard(true); else if (status === 'idle') onClose() }
  const saving = status === 'saving' || status === 'starting'
  return <Modal title={mode === 'record' ? 'Record a meeting' : 'Import a recording'} onClose={requestClose} closeDisabled={saving}>
    <div className="modal-symbol"><AudioLines size={25} /></div>
    <p className="eyebrow">{mode === 'record' ? 'ROOM TO LISTEN' : 'PICK UP WHERE YOU LEFT OFF'}</p>
    <h2>{mode === 'record' ? 'Capture the conversation.' : 'Bring your recording.'}</h2>
    <p className="modal-description">{mode === 'record' ? 'Be present. We’ll take care of remembering.' : 'Turn an audio or video file into a searchable, speaker-labeled transcript.'}</p>
    {discard ? <div className="discard-box"><strong>Discard this recording?</strong><p>The audio hasn’t been saved. Closing now will permanently discard it.</p><div className="button-row"><button className="button secondary" onClick={() => setDiscard(false)}>Keep recording</button><button className="button danger" onClick={discardRecording}>Discard recording</button></div></div> : <>
    <Feedback error={error} />
    {!active && !retryRecording && <>
      <label className="field">Meeting title <span className="optional">optional</span><input placeholder="e.g. Monday product catch-up" value={title} onChange={event => setTitle(event.target.value)} disabled={saving} maxLength={200} /></label>
      {mode === 'import' && <label className={`file-drop ${file ? 'selected' : ''}`} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); if (!saving && event.dataTransfer.files[0]) setFile(event.dataTransfer.files[0]) }}><input type="file" accept="audio/*,video/*,.m4a,.mp3,.wav,.webm,.ogg,.flac,.mp4,.mkv" onChange={event => setFile(event.target.files?.[0] || null)} disabled={saving} /><span className="file-drop-icon">{file ? <Check size={24} /> : <Upload size={24} />}</span><strong>{file ? file.name : 'Choose a recording or drop it here'}</strong><small>{file ? `${(file.size / 1024 / 1024).toFixed(1)} MB · click to change` : 'MP3, WAV, M4A, WebM, MP4, and more'}</small></label>}
      <div className="form-grid"><label className="field">Language<select value={language} disabled={saving} onChange={event => setLanguage(event.target.value)}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label className="field">Speakers<select value={speakerCount} disabled={saving} onChange={event => setSpeakerCount(event.target.value)}><option value="">Detect automatically</option>{Array.from({ length: 10 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} speaker{i ? 's' : ''}</option>)}</select></label></div>
      {mode === 'record' && <label className="toggle-option"><Monitor size={19} /><span><strong>Include shared audio</strong><small>Choose a browser tab with audio. Availability depends on your browser.</small></span><input type="checkbox" checked={sharedAudio} onChange={event => setSharedAudio(event.target.checked)} disabled={saving || !navigator.mediaDevices?.getDisplayMedia} /><span className="toggle" aria-hidden="true" /></label>}
    </>}
    {active && <div className={`recorder ${status === 'paused' ? 'is-paused' : ''}`}><span className="recording-state"><i />{status === 'paused' ? 'RECORDING PAUSED' : 'RECORDING ON THIS DEVICE'}</span><div className="recording-clock">{duration(elapsed)}</div><div className="waveform" role="img" aria-label="Live audio input level">{levels.map((level, i) => <span key={i} style={{ height: `${level}px` }} />)}</div><p>{title || 'Untitled meeting'}{sharedAudio && <span> · Microphone + shared audio</span>}</p><div className="recorder-buttons"><button className="button secondary" onClick={pauseResume}>{status === 'paused' ? <Play size={16} /> : <Pause size={16} />}{status === 'paused' ? 'Resume' : 'Pause'}</button><button className="button primary" onClick={() => { setStatus('saving'); recorder.current?.stop() }}><Square size={14} fill="currentColor" />{ready ? 'Finish & transcribe' : 'Save recording'}</button></div><button className="text-button muted" onClick={() => setDiscard(true)}><X size={13} />Discard recording</button></div>}
    {retryRecording && <div className="retry-recording"><strong>Your recording is still here.</strong><p>Retry saving it to the local server, or download a copy before closing.</p><div className="button-row"><button className="button primary" disabled={saving} onClick={() => void save(retryRecording.blob, retryRecording.name)}>{saving ? <Spinner /> : <Upload size={16} />}Retry saving</button><button className="button secondary" onClick={() => { const url = URL.createObjectURL(retryRecording.blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = retryRecording.name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000) }}>Download audio</button></div></div>}
    {!active && !retryRecording && <button className="button primary full start-recording" disabled={saving || (mode === 'import' && !file)} onClick={() => mode === 'record' ? void start() : file && void save(file, file.name)}>{saving ? <Spinner /> : mode === 'record' ? <Mic size={17} /> : <ArrowUpRight size={18} />}{status === 'starting' ? 'Connecting microphone…' : status === 'saving' ? 'Saving on your device…' : mode === 'record' ? 'Start recording' : ready ? 'Import & transcribe' : 'Import recording'}</button>}
    {!ready && !active && <p className="setup-hint">Recordings save locally. Download the speech models in Settings to enable transcription and speaker detection.</p>}
    <div className="modal-privacy"><PrivacyBadge /></div>
    </>}
  </Modal>
}
