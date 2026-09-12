import { useCallback, useEffect, useRef, useState } from 'react'
import { ArrowDownToLine, ArrowRight, AudioLines, ChevronRight, FolderOpen, HardDrive, Menu, Plus, Search, Settings2, Upload, X } from 'lucide-react'
import { BrandMark, Feedback, Spinner } from './components'
import MeetingWorkspace from './MeetingWorkspace'
import RecordingModal from './RecordingModal'
import SettingsPanel from './SettingsPanel'
import { api, busy, dateLabel, duration, speechReady } from './types'
import type { Meeting, Settings } from './types'

export default function App() {
  const [meetings, setMeetings] = useState<Meeting[]>([])
  const [settings, setSettings] = useState<Settings | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [page, setPage] = useState<'meetings' | 'settings'>('meetings')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [capture, setCapture] = useState<'record' | 'import' | null>(null)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const mutationVersion = useRef(0)
  const refreshVersion = useRef(0)
  const refresh = useCallback(async () => {
    const version = mutationVersion.current
    const request = ++refreshVersion.current
    const results = await Promise.allSettled([api<Meeting[]>('/meetings'), api<Settings>('/settings')])
    if (request !== refreshVersion.current) return
    if (results[0].status === 'fulfilled' && version === mutationVersion.current) setMeetings(previous => results[0].status === 'fulfilled' ? results[0].value.map(incoming => { const current = previous.find(item => item.id === incoming.id); return current && current.updated_at > incoming.updated_at ? current : incoming }) : previous)
    if (results[1].status === 'fulfilled' && version === mutationVersion.current) setSettings(results[1].value)
    const failed = results.find(result => result.status === 'rejected') as PromiseRejectedResult | undefined
    if (failed) setError((failed.reason as Error).message)
    else setError(null)
    setLoading(false)
  }, [])
  useEffect(() => { void refresh(); const interval = setInterval(() => { if (!document.hidden) void refresh() }, 3500); return () => clearInterval(interval) }, [refresh])
  function update(meeting: Meeting) { mutationVersion.current += 1; setMeetings(previous => [meeting, ...previous.filter(item => item.id !== meeting.id)].sort((a, b) => b.created_at.localeCompare(a.created_at))) }
  function navigate(id: string | null) { setSelectedId(id); setPage('meetings'); setSidebarOpen(false) }
  function showSettings() { setPage('settings'); setSidebarOpen(false) }
  const selected = meetings.find(meeting => meeting.id === selectedId)
  const ready = speechReady(settings?.speech)
  const filtered = meetings.filter(meeting => `${meeting.title} ${meeting.segments.map(segment => segment.text).join(' ')}`.toLowerCase().includes(search.toLowerCase()))
  return <div className="app-shell">
    {sidebarOpen && <button className="sidebar-scrim" aria-label="Close navigation" onClick={() => setSidebarOpen(false)} />}
    <aside className={`sidebar ${sidebarOpen ? 'open' : ''}`}><button className="brand" onClick={() => navigate(null)} aria-label="Stillnote home"><BrandMark /><span>stillnote<span className="brand-period">.</span></span></button><div className="sidebar-actions"><button className="button primary new-recording" onClick={() => { setCapture('record'); setSidebarOpen(false) }}><Plus size={18} />New recording</button><button className="button secondary import-audio" onClick={() => { setCapture('import'); setSidebarOpen(false) }}><Upload size={17} />Import audio</button></div><nav className="main-nav" aria-label="Main navigation"><button className={page === 'meetings' && !selectedId ? 'active' : ''} onClick={() => navigate(null)}><FolderOpen size={18} />All meetings</button><button className={page === 'settings' ? 'active' : ''} onClick={showSettings}><Settings2 size={18} />Settings</button></nav>{meetings.length > 0 && <div className="sidebar-recent"><p className="nav-label">Recent</p>{ meetings.slice(0, 6).map(meeting => <button className={`recent-meeting ${selectedId === meeting.id && page === 'meetings' ? 'selected' : ''}`} key={meeting.id} onClick={() => navigate(meeting.id)}>{busy(meeting) ? <Spinner size={15} /> : <AudioLines size={16} />}<span>{meeting.title}</span></button>)}</div>}<div className="sidebar-bottom"><div className="storage-label"><HardDrive size={14} />Stored locally</div></div></aside>
    <main className="main-shell"><header className="topbar"><div><button className="icon-button mobile-menu" aria-label="Open navigation" onClick={() => setSidebarOpen(true)}><Menu size={21} /></button><span>{page === 'settings' ? 'Settings' : selected ? selected.title : 'All meetings'}</span></div></header><div className="main-content">
    {error && <div className="connection-error"><Feedback error={error} /><button className="text-button" onClick={() => void refresh()}>Try again</button><button className="icon-button" aria-label="Dismiss connection message" onClick={() => setError(null)}><X size={15} /></button></div>}
    {page === 'settings' ? settings ? <SettingsPanel settings={settings} onSave={next => { mutationVersion.current += 1; setSettings(next) }} onBack={() => navigate(selectedId)} onRefresh={refresh} /> : <div className="loading-state"><Spinner size={22} /><p>{loading ? 'Loading settings…' : 'Couldn’t load settings. Check the server connection.'}</p></div> : selected ? <MeetingWorkspace key={selected.id} meeting={selected} settings={settings} onUpdate={update} onDelete={id => { mutationVersion.current += 1; setMeetings(previous => previous.filter(item => item.id !== id)); setSelectedId(null) }} onBack={() => navigate(null)} onSettings={showSettings} /> : <div className="home-page page-enter">
      {!loading && !ready && <div className="setup-banner"><span className="setup-banner-icon">{settings?.speech.installing ? <Spinner size={19} /> : <ArrowDownToLine size={19} />}</span><div><strong>{settings?.speech.installing ? 'Downloading speech model…' : 'Set up transcription'}</strong><p>{settings?.speech.installing ? settings.speech.detail || 'Downloading…' : 'Download a speech model to transcribe recordings.'}</p></div><button className="text-button" onClick={showSettings}>{settings?.speech.installing ? 'View progress' : 'Set up models'}<ArrowRight size={16} /></button></div>}
      <section className="meetings-section"><div className="section-heading"><div><h1>Meetings</h1></div><label className="meeting-search"><Search size={16} /><input value={search} onChange={event => setSearch(event.target.value)} placeholder="Search meetings…" aria-label="Search meetings" />{search && <button className="icon-button" aria-label="Clear meeting search" onClick={() => setSearch('')}><X size={13} /></button>}</label></div>
      {loading ? <div className="loading-state"><Spinner size={24} /><p>Loading…</p></div> : !meetings.length ? <div className="meetings-empty"><h3>No meetings yet</h3><button className="text-button" onClick={() => setCapture('record')}>New recording<ArrowRight size={16} /></button></div> : filtered.length ? <div className="meeting-list"><div className="meeting-list-labels"><span>MEETING</span><span>DATE</span><span>DURATION</span><span>STATUS</span></div>{filtered.map(meeting => <button className="meeting-list-row" onClick={() => navigate(meeting.id)} key={meeting.id}><div className="meeting-row-title">{busy(meeting) && <Spinner size={19} />}<span><strong>{meeting.title}</strong></span></div><span className="row-date">{dateLabel(meeting.created_at)}</span><span className="row-duration">{meeting.duration > 0 ? duration(meeting.duration) : '—'}</span><span className={`status-pill ${meeting.status === 'complete' ? 'green' : meeting.status === 'error' ? 'red' : ''}`}>{meeting.status === 'transcribing' ? 'Transcribing' : meeting.status === 'summarizing' ? 'Summarizing' : meeting.status === 'complete' ? 'Complete' : meeting.status === 'transcribed' ? 'Transcribed' : meeting.status === 'error' ? 'Needs attention' : 'Recorded'}</span><ChevronRight className="meeting-row-arrow" size={16} /></button>)}</div> : <div className="search-empty"><h3>No meetings found</h3><button className="text-button" onClick={() => setSearch('')}>Clear search</button></div>}
      </section>
    </div>}
    </div></main>
    {capture && <RecordingModal mode={capture} settings={settings} onClose={() => setCapture(null)} onSaved={meeting => { update(meeting); setCapture(null); navigate(meeting.id) }} />}
  </div>
}
