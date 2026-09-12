import { useEffect, useRef, useState } from 'react'
import type { SyntheticEvent } from 'react'
import { ArrowDownToLine, ArrowLeft, AudioLines, CalendarDays, Check, ChevronDown, Clock3, Copy, FileText, ListChecks, Monitor, Pause, Pencil, Play, RefreshCw, Search, Settings2, SkipBack, Sparkles, Trash2, Users, X } from 'lucide-react'
import { Feedback, Modal, Spinner } from './components'
import ContextPanel from './ContextPanel'
import AgentIcon from './AgentIcon'
import { agentDefaults, api, busy, dateLabel, duration, json, languages, speechReady } from './types'
import type { Meeting, Segment, Settings } from './types'

export default function MeetingWorkspace({ meeting, settings, onUpdate, onDelete, onBack, onSettings }: { meeting: Meeting; settings: Settings | null; onUpdate: (meeting: Meeting) => void; onDelete: (id: string) => void; onBack: () => void; onSettings: () => void }) {
  const [tab, setTab] = useState<'summary' | 'transcript' | 'context'>('summary')
  const [title, setTitle] = useState(meeting.title)
  const draftKey = `stillnote:notes:${meeting.id}`
  const [notes, setNotes] = useState(() => { try { return localStorage.getItem(draftKey) ?? meeting.notes } catch { return meeting.notes } })
  const notesRef = useRef(notes)
  notesRef.current = notes
  const lastServerNotes = useRef(meeting.notes)
  const lastAutosaveAttempt = useRef<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const [exportOpen, setExportOpen] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [retranscribeOpen, setRetranscribeOpen] = useState(false)
  const [transcriptionLanguage, setTranscriptionLanguage] = useState(meeting.language || 'auto')
  const [transcriptionSpeakers, setTranscriptionSpeakers] = useState(meeting.speaker_count?.toString() || '')
  const [consentOpen, setConsentOpen] = useState(false)
  const [renaming, setRenaming] = useState<string | null>(null)
  const [speakerName, setSpeakerName] = useState('')
  const [editSegment, setEditSegment] = useState<Segment | null>(null)
  const [search, setSearch] = useState('')
  const [playing, setPlaying] = useState(false)
  const [time, setTime] = useState(0)
  const [audioDuration, setAudioDuration] = useState(meeting.duration)
  const [speed, setSpeed] = useState(1)
  const audio = useRef<HTMLMediaElement | null>(null)
  const pending = busy(meeting)
  const noSpeech = !meeting.segments.length && ['transcribed', 'complete'].includes(meeting.status)
  const speakers = Object.entries(meeting.speakers)
  useEffect(() => { setTitle(meeting.title) }, [meeting.title])
  useEffect(() => {
    if (notesRef.current === lastServerNotes.current) setNotes(meeting.notes)
    lastServerNotes.current = meeting.notes
  }, [meeting.notes])
  useEffect(() => {
    try { if (notes === meeting.notes) localStorage.removeItem(draftKey); else localStorage.setItem(draftKey, notes) } catch { /* Browser storage can be disabled; unload protection remains active. */ }
  }, [notes, meeting.notes, draftKey])
  useEffect(() => {
    if (notes === meeting.notes) { lastAutosaveAttempt.current = null; return }
    if (pending || saving || lastAutosaveAttempt.current === notes) return
    const timeout = setTimeout(() => {
      lastAutosaveAttempt.current = notes
      void patch({ notes })
    }, 700)
    return () => clearTimeout(timeout)
  }, [notes, meeting.notes, pending, saving])
  useEffect(() => { if (meeting.duration > 0) setAudioDuration(meeting.duration) }, [meeting.duration])
  useEffect(() => { if (!success) return; const timeout = setTimeout(() => setSuccess(null), 3500); return () => clearTimeout(timeout) }, [success])
  useEffect(() => {
    if (notes === meeting.notes) return
    const handle = (event: BeforeUnloadEvent) => { event.preventDefault() }
    window.addEventListener('beforeunload', handle)
    return () => window.removeEventListener('beforeunload', handle)
  }, [notes, meeting.notes])
  async function patch(body: unknown, message?: string) {
    setSaving(true); setError(null)
    try { onUpdate(await api<Meeting>(`/meetings/${meeting.id}`, json('PATCH', body))); if (message) setSuccess(message); return true }
    catch (err) { setError((err as Error).message); return false }
    finally { setSaving(false) }
  }
  async function transcribe(confirmed = false) {
    if (meeting.segments.length && !confirmed) { setRetranscribeOpen(true); return }
    setRetranscribeOpen(false)
    setSaving(true); setError(null)
    try { onUpdate(await api<Meeting>(`/meetings/${meeting.id}/transcribe`, json('POST', { language: transcriptionLanguage, speaker_count: transcriptionSpeakers ? Number(transcriptionSpeakers) : null }))) }
    catch (err) { setError((err as Error).message) }
    finally { setSaving(false) }
  }
  async function stopTranscription() {
    setSaving(true); setError(null)
    try { onUpdate(await api<Meeting>(`/meetings/${meeting.id}/transcribe/cancel`, json('POST', {}))) }
    catch (err) { setError((err as Error).message) }
    finally { setSaving(false) }
  }
  async function summarize(allowRemote = false) {
    if (!allowRemote) { setConsentOpen(true); return }
    setSaving(true); setError(null); setConsentOpen(false)
    try { onUpdate(await api<Meeting>(`/meetings/${meeting.id}/summary`, json('POST', { allow_remote: allowRemote }))) }
    catch (err) { setError((err as Error).message) }
    finally { setSaving(false) }
  }
  async function remove() {
    setSaving(true); setError(null)
    try { await api(`/meetings/${meeting.id}`, { method: 'DELETE' }); try { localStorage.removeItem(draftKey) } catch { /* storage unavailable */ } onDelete(meeting.id) }
    catch (err) { setError((err as Error).message); setDeleteOpen(false) }
    finally { setSaving(false) }
  }
  async function seek(value: number) { if (audio.current) { audio.current.currentTime = value; setTime(value); try { await audio.current.play() } catch { setError('Playback could not start. Try the play button, or download the original audio.') } } }
  async function togglePlayback() { if (!audio.current) return; if (audio.current.paused) { try { await audio.current.play() } catch { setError('Your browser could not play this file. Download the original audio to play it in another app.') } } else audio.current.pause() }
  async function copyTranscript() {
    try { await navigator.clipboard.writeText(meeting.segments.map(segment => `[${duration(segment.start)}] ${meeting.speakers[segment.speaker] || segment.speaker}: ${segment.text}`).join('\n\n')); setSuccess('Transcript copied.') }
    catch { setError('Clipboard access is unavailable. Use Export to download the transcript instead.') }
  }
  const filtered = meeting.segments.filter(segment => `${meeting.speakers[segment.speaker]} ${segment.text}`.toLowerCase().includes(search.toLowerCase()))
  const metadataDuration = audioDuration > 0 ? duration(audioDuration) : 'Audio saved'
  const mediaProps = {
    ref: (element: HTMLMediaElement | null) => { audio.current = element },
    onPlay: () => setPlaying(true), onPause: () => setPlaying(false), onEnded: () => setPlaying(false),
    onTimeUpdate: (event: SyntheticEvent<HTMLMediaElement>) => setTime(event.currentTarget.currentTime),
    onLoadedMetadata: (event: SyntheticEvent<HTMLMediaElement>) => { const length = event.currentTarget.duration; if (Number.isFinite(length)) setAudioDuration(length) },
  }
  return <div className="meeting-page page-enter">
    <button className="text-button back-button" disabled={saving || (pending && notes !== meeting.notes)} onClick={async () => { if (notes !== meeting.notes && !(await patch({ notes }))) return; onBack() }}><ArrowLeft size={15} />All meetings</button>
    <div className="meeting-heading"><div className="meeting-title-area"><input className="meeting-title" aria-label="Meeting title" value={title} onChange={event => setTitle(event.target.value)} disabled={pending || saving} maxLength={200} onBlur={() => { if (title.trim() && title.trim() !== meeting.title) void patch({ title: title.trim() }); else setTitle(meeting.title) }} onKeyDown={event => { if (event.key === 'Enter') event.currentTarget.blur() }} /><div className="meeting-meta"><span><CalendarDays size={14} />{dateLabel(meeting.created_at)}</span><span><Clock3 size={14} />{metadataDuration}</span><span><Users size={14} />{speakers.length ? `${speakers.length} speaker${speakers.length === 1 ? '' : 's'}` : 'No speakers'}</span></div></div><div className="meeting-actions"><div className="dropdown-wrap"><button className="button secondary" onClick={() => setExportOpen(!exportOpen)} aria-expanded={exportOpen}><ArrowDownToLine size={15} />Export<ChevronDown size={13} /></button>{exportOpen && <><button className="dropdown-dismiss" aria-label="Close export menu" onClick={() => setExportOpen(false)} /><div className="dropdown-menu">{[['md', 'Markdown notes'], ['txt', 'Plain text transcript'], ['srt', 'Subtitles (.srt)'], ['json', 'All meeting data (.json)']].map(([format, label]) => <a key={format} href={`/api/meetings/${meeting.id}/export?format=${format}`} download onClick={() => setExportOpen(false)}><FileText size={14} />{label}</a>)}<a href={meeting.audio_url} download={meeting.audio_name} onClick={() => setExportOpen(false)}><AudioLines size={14} />Original audio</a>{meeting.video_url && <a href={meeting.video_url} download="screen.mp4" onClick={() => setExportOpen(false)}><Play size={14} />Screen recording</a>}</div></>}</div><button className="icon-button" title="Delete meeting" aria-label="Delete meeting" disabled={pending || saving} onClick={() => setDeleteOpen(true)}><Trash2 size={18} /></button></div></div>
    <Feedback error={error || meeting.error} success={success} />
    {pending && <div className="job-progress" role="status"><span className="progress-symbol"><Spinner size={21} /></span><div><strong>{meeting.status === 'transcribing' ? 'Transcribing…' : 'Summarizing…'}</strong><span>{meeting.stage || 'Preparing…'}</span><progress max={100} value={Math.max(0, Math.min(100, meeting.progress))} aria-label="Processing progress" /></div><span className="progress-number">{Math.round(meeting.progress)}%</span>{meeting.status === 'transcribing' && <button className="button secondary" disabled={saving || meeting.stage === 'Stopping transcription…'} onClick={() => void stopTranscription()}><X size={16} />{meeting.stage === 'Stopping transcription…' ? 'Stopping…' : 'Stop'}</button>}</div>}
    {meeting.video_url && <video {...mediaProps} className="meeting-screen" src={meeting.video_url} preload="metadata" playsInline aria-label="Meeting screen recording" />}
    <div className="audio-player">{!meeting.video_url && <audio {...mediaProps} src={meeting.audio_url} preload="metadata" />}<button className="play-button" onClick={() => void togglePlayback()} aria-label={playing ? 'Pause audio' : 'Play audio'}>{playing ? <Pause size={18} fill="currentColor" /> : <Play size={18} fill="currentColor" />}</button><button className="icon-button skip-button" aria-label="Skip back 10 seconds" onClick={() => { if (audio.current) audio.current.currentTime = Math.max(0, audio.current.currentTime - 10) }}><SkipBack size={17} /></button><span className="audio-time">{duration(time)}</span><input className="audio-seek" type="range" min="0" max={audioDuration || 1} step="0.1" value={Math.min(time, audioDuration || 1)} disabled={!audioDuration} aria-label="Playback position" onChange={event => { if (audio.current) { audio.current.currentTime = Number(event.target.value); setTime(Number(event.target.value)) } }} /><span className="audio-time total">{duration(audioDuration)}</span><button className="speed-button" aria-label={`Playback speed ${speed} times. Change speed`} onClick={() => { const next = speed === 2 ? 0.75 : speed === 0.75 ? 1 : speed + 0.25; setSpeed(next); if (audio.current) audio.current.playbackRate = next }}>{speed}×</button></div>
    <div className="workspace-tabs" role="tablist" aria-label="Meeting content"><button role="tab" aria-selected={tab === 'summary'} onClick={() => setTab('summary')}>Summary</button><button role="tab" aria-selected={tab === 'transcript'} onClick={() => setTab('transcript')}>Transcript</button><button role="tab" aria-selected={tab === 'context'} onClick={() => setTab('context')}>Context{notes !== meeting.notes && <i aria-label="Unsaved changes" />}</button></div>
    <div className="meeting-body" role="tabpanel">
      {tab === 'summary' && settings && <div className="summary-agent" title="Active summary agent">
        <AgentIcon provider={settings.summary.provider} size={16} />
        <span>{agentDefaults[settings.summary.provider].label}</span><span aria-hidden="true">·</span>
        <span className="summary-agent-model">{settings.summary.model || agentDefaults[settings.summary.provider].model}</span>
      </div>}
      {tab === 'summary' && <label className="toggle-option summary-video-option">
        <Monitor size={19} aria-hidden="true" />
        <span><strong>Send video path to AI</strong><small id="summary-video-description">{meeting.video_url ? 'Include the local video path in summary prompts for this recording. This shares the path only; video analysis is not enabled.' : 'Available for recordings with saved screen video.'}</small></span>
        <input type="checkbox" aria-label="Send video path to AI" aria-describedby="summary-video-description" checked={meeting.summary_include_video_path ?? false} disabled={pending || saving || !meeting.video_url} onChange={event => void patch({ summary_include_video_path: event.target.checked })} />
        <span className="toggle" aria-hidden="true" />
      </label>}
      {tab === 'context' ? <ContextPanel notes={notes} savedNotes={meeting.notes} links={meeting.context_links} pending={pending} saving={saving} onNotesChange={setNotes} onSave={patch} /> : !meeting.segments.length ? <div className="content-empty"><h2>{pending ? 'Transcribing…' : noSpeech ? 'No speech detected' : 'No transcript yet'}</h2>{!pending && (noSpeech || !speechReady(settings?.speech)) && <p>{noSpeech ? 'Check the audio, then try again.' : 'Download a speech model to transcribe this recording.'}</p>}{!pending && <button className="button primary" disabled={saving} onClick={() => speechReady(settings?.speech) ? void transcribe() : onSettings()}>{speechReady(settings?.speech) ? <AudioLines size={17} /> : <Settings2 size={17} />}{speechReady(settings?.speech) ? 'Transcribe recording' : 'Set up transcription'}</button>}</div> : tab === 'summary' ? <>
        {meeting.summary ? <div className="summary-layout"><div className="summary-main"><div className="panel-heading"><h2>Overview</h2><button className="icon-button" title="Regenerate summary" aria-label="Regenerate summary" disabled={pending || saving} onClick={() => void summarize()}><RefreshCw size={16} /></button></div><p className="summary-overview">{meeting.summary.overview}</p><div className="summary-block"><h3><ListChecks size={18} />Key takeaways</h3>{meeting.summary.key_points.length ? <ul className="takeaways">{meeting.summary.key_points.map((point, index) => <li key={index}>{point}</li>)}</ul> : <p className="muted small">No key points.</p>}</div><div className="summary-block"><h3><Check size={18} />Decisions</h3>{meeting.summary.decisions.length ? <ul className="takeaways">{meeting.summary.decisions.map((point, index) => <li key={index}>{point}</li>)}</ul> : <p className="muted small">No decisions.</p>}</div><p className="summary-caption">Generated with {`${agentDefaults[meeting.summary.provider as keyof typeof agentDefaults]?.label || meeting.summary.provider} · ${meeting.summary.model}`}</p></div><aside className="action-panel"><h3>Next steps</h3>{meeting.summary.action_items.length ? <ul className="action-list">{meeting.summary.action_items.map((item, index) => <li key={index}><span className="action-checkbox" aria-hidden="true" /><div><p>{item.text}</p>{(item.owner || item.due) && <small>{item.owner || 'Unassigned'}{item.due && ` · ${item.due}`}</small>}</div></li>)}</ul> : <div className="no-actions"><p>No action items.</p></div>}</aside></div> : <div className="content-empty"><h2>No summary yet</h2><button className="button primary" disabled={pending || saving} onClick={() => void summarize()}>{pending || saving ? <Spinner /> : <Sparkles size={17} />}{meeting.status === 'summarizing' ? 'Creating summary…' : 'Create summary'}</button></div>}
      </> : <div className="transcript-layout"><section className="transcript-main"><div className="panel-heading"><h2>Transcript</h2><div className="button-row"><button className="icon-button" onClick={() => void copyTranscript()} aria-label="Copy transcript" title="Copy transcript"><Copy size={16} /></button><button className="icon-button" title="Transcribe again" aria-label="Transcribe again" disabled={pending || saving} onClick={() => void transcribe()}><RefreshCw size={16} /></button></div></div><label className="transcript-search"><Search size={15} /><input value={search} onChange={event => setSearch(event.target.value)} placeholder="Search transcript…" aria-label="Search transcript" />{search && <button className="icon-button" aria-label="Clear transcript search" onClick={() => setSearch('')}><X size={14} /></button>}</label><div className="segments">{filtered.map(segment => { const index = Math.max(0, speakers.findIndex(([id]) => id === segment.speaker)); return <article key={segment.id} className={`segment ${time >= segment.start && time < segment.end ? 'segment-active' : ''}`}><button className={`speaker-avatar color-${index % 5}`} title={`Rename ${meeting.speakers[segment.speaker] || segment.speaker}`} aria-label={`Rename ${meeting.speakers[segment.speaker] || segment.speaker}`} disabled={pending || saving} onClick={() => { setRenaming(segment.speaker); setSpeakerName(meeting.speakers[segment.speaker] || segment.speaker) }}>{(meeting.speakers[segment.speaker] || segment.speaker).slice(0, 1).toUpperCase()}</button><div className="segment-content"><div className="segment-heading"><button className="speaker-name" onClick={() => { setRenaming(segment.speaker); setSpeakerName(meeting.speakers[segment.speaker] || segment.speaker) }} disabled={pending || saving}>{meeting.speakers[segment.speaker] || segment.speaker}</button><button className="timestamp" onClick={() => void seek(segment.start)} aria-label={`Play from ${duration(segment.start)}`}>{duration(segment.start)}</button><button className="segment-edit icon-button" onClick={() => setEditSegment({ ...segment })} title="Edit transcript segment" aria-label="Edit transcript segment" disabled={pending || saving}><Pencil size={13} /></button></div><p>{segment.text}</p></div></article> })}{!filtered.length && <div className="no-search-results">No transcript segments match “{search}”.</div>}</div></section><aside className="speakers-panel"><div className="aside-heading"><h3>Speakers</h3></div>{speakers.map(([id, name], index) => <button className="speaker-row" key={id} disabled={pending || saving} onClick={() => { setRenaming(id); setSpeakerName(name) }}><span className={`speaker-avatar color-${index % 5}`}>{name.slice(0, 1).toUpperCase()}</span><strong>{name}</strong><Pencil size={13} /></button>)}</aside></div>}
    </div>
    {retranscribeOpen && <Modal title="Transcribe again" onClose={() => setRetranscribeOpen(false)}><h2>Transcribe again?</h2><p className="modal-description">Replaces the transcript, corrections, speaker names, and summary. Keeps the recording and context.</p><div className="form-grid"><label className="field">Language<select value={transcriptionLanguage} onChange={event => setTranscriptionLanguage(event.target.value)}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label className="field">Speakers<select value={transcriptionSpeakers} onChange={event => setTranscriptionSpeakers(event.target.value)}><option value="">Detect automatically</option>{Array.from({ length: 10 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1} speaker{i ? 's' : ''}</option>)}</select></label></div><div className="button-row modal-actions"><button className="button secondary" onClick={() => setRetranscribeOpen(false)}>Cancel</button><button className="button primary" onClick={() => void transcribe(true)}><RefreshCw size={15} />Transcribe again</button></div></Modal>}
    {deleteOpen && <Modal title="Delete meeting" onClose={() => setDeleteOpen(false)} closeDisabled={saving}><h2>Delete this meeting?</h2><p className="modal-description">Permanently deletes “{meeting.title}” and its recording, transcript, summary, and context.</p><div className="button-row modal-actions"><button className="button secondary" onClick={() => setDeleteOpen(false)} disabled={saving}>Cancel</button><button className="button danger" onClick={() => void remove()} disabled={saving}>{saving ? <Spinner /> : <Trash2 size={15} />}Delete meeting</button></div></Modal>}
    {consentOpen && <Modal title="Allow remote summary" onClose={() => setConsentOpen(false)}><h2>{meeting.summary_include_video_path ? 'Send transcript and video path?' : 'Send transcript?'}</h2><p className="modal-description">{meeting.summary_include_video_path ? 'Sends the transcript, speaker labels, and local video path to the selected agent’s model provider for this summary. The video file, audio, and context stay on this device.' : 'Sends the transcript and speaker labels to the selected agent’s model provider for this summary. Video, audio, and context stay on this device.'}</p><div className="consent-details"><span>Provider</span><strong>{agentDefaults[settings?.summary.provider || 'codex'].label}</strong><span>Thinking</span><strong>{settings?.summary.reasoning_effort || 'high'}</strong><span>Model</span><strong>{settings?.summary.model || 'Provider default'}</strong></div><div className="button-row modal-actions"><button className="button secondary" onClick={() => setConsentOpen(false)}>Cancel</button><button className="button primary" onClick={() => void summarize(true)}><Sparkles size={16} />Send & summarize</button></div></Modal>}
    {renaming && <Modal title="Rename speaker" onClose={() => setRenaming(null)} closeDisabled={saving}><h2>Rename speaker</h2><p className="modal-description">Renames this speaker and clears the summary.</p><Feedback error={error} /><form onSubmit={event => { event.preventDefault(); if (speakerName.trim()) void patch({ speakers: { ...meeting.speakers, [renaming]: speakerName.trim() } }, 'Speaker renamed.').then(saved => { if (saved) setRenaming(null) }) }}><label className="field">Speaker name<input value={speakerName} onChange={event => setSpeakerName(event.target.value)} maxLength={80} required /></label><div className="modal-actions button-row"><button type="button" className="button secondary" onClick={() => setRenaming(null)} disabled={saving}>Cancel</button><button className="button primary" disabled={saving || !speakerName.trim()}>{saving ? <Spinner /> : <Check size={16} />}Save name</button></div></form></Modal>}
    {editSegment && <Modal title="Edit transcript segment" onClose={() => setEditSegment(null)} closeDisabled={saving}><h2>Edit transcript</h2><p className="modal-description">Editing at {duration(editSegment.start)} clears the current summary.</p><Feedback error={error} /><label className="field">Speaker<select value={editSegment.speaker} onChange={event => setEditSegment({ ...editSegment, speaker: event.target.value })}>{speakers.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></label><label className="field">Transcript<textarea className="edit-transcript" value={editSegment.text} onChange={event => setEditSegment({ ...editSegment, text: event.target.value })} /></label><div className="modal-actions button-row"><button className="button secondary" onClick={() => setEditSegment(null)} disabled={saving}>Cancel</button><button className="button primary" disabled={saving || !editSegment.text.trim()} onClick={() => void patch({ segments: meeting.segments.map(segment => segment.id === editSegment.id ? { ...editSegment, text: editSegment.text.trim() } : segment) }, 'Transcript updated.').then(saved => { if (saved) setEditSegment(null) })}>{saving ? <Spinner /> : <Check size={16} />}Save changes</button></div></Modal>}
  </div>
}
