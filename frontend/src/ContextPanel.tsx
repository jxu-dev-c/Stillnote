import { useState } from 'react'
import { Check, Globe2, Pencil, Plus, Trash2 } from 'lucide-react'
import { Feedback, Modal, Spinner } from './components'
import { api, json } from './types'
import type { ContextLink } from './types'
import './context.css'

function websiteUrl(value: string): URL {
  const input = value.trim()
  const url = new URL(/^[a-z][a-z\d+.-]*:/i.test(input) ? input : `https://${input}`)
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) {
    throw new Error('Enter a valid http or https website link without a username or password.')
  }
  return url
}

function WebsiteIcon({ origin }: { origin: string }) {
  const [failed, setFailed] = useState(false)
  return <span className="context-link-icon" aria-hidden="true">
    <Globe2 size={20} />
    {!failed && <img src={`${origin}/favicon.ico`} alt="" width={22} height={22} referrerPolicy="no-referrer" onError={() => setFailed(true)} />}
  </span>
}

export default function ContextPanel({ notes, savedNotes, links, pending, saving, onNotesChange, onSave }: {
  notes: string; savedNotes: string; links: ContextLink[]; pending: boolean; saving: boolean;
  onNotesChange: (notes: string) => void;
  onSave: (body: { notes: string; context_links?: ContextLink[] }, message?: string) => Promise<boolean>;
}) {
  const [editor, setEditor] = useState<{ originalUrl: string | null; url: string; title: string } | null>(null)
  const [linkError, setLinkError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const disabled = pending || saving || submitting
  const dirty = notes !== savedNotes

  function openEditor(link?: ContextLink) {
    setLinkError(null)
    setEditor({ originalUrl: link?.url ?? null, url: link?.url ?? '', title: link?.title ?? '' })
  }
  async function saveLink() {
    if (!editor || disabled) return
    let url: string
    try { url = websiteUrl(editor.url).href }
    catch { setLinkError('Enter a valid http or https website link without a username or password.'); return }
    if (links.some(link => link.url === url && link.url !== editor.originalUrl)) {
      setLinkError('This link is already in your context.'); return
    }
    setLinkError(null)
    setSubmitting(true)
    try {
      let title = editor.title.trim()
      if (!title) {
        try { title = (await api<{ title: string }>('/context/link-title', json('POST', { url }))).title }
        catch { /* A missing page title never prevents saving the link. */ }
      }
      const next = { url, title }
      const contextLinks = editor.originalUrl ? links.map(link => link.url === editor.originalUrl ? next : link) : [...links, next]
      if (await onSave({ notes, context_links: contextLinks }, editor.originalUrl ? 'Link updated.' : 'Link added.')) setEditor(null)
      else setLinkError('Your link could not be saved. Your changes are still here; try again.')
    } finally { setSubmitting(false) }
  }

  return <section className="context-panel" aria-label="Meeting context">
    <section className="context-links" aria-labelledby="context-links-heading">
      <div className="context-section-heading">
        <h3 id="context-links-heading">Links</h3>
        <button className="button secondary" disabled={disabled || links.length >= 100} onClick={() => openEditor()}><Plus size={15} />Add link</button>
      </div>
      {links.length ? <ul className="context-link-list">{links.map(link => {
        const url = websiteUrl(link.url)
        const host = url.hostname.replace(/^www\./, '')
        return <li key={link.url} className="context-link-row">
          <a className="context-link" href={link.url} target="_blank" rel="noopener noreferrer" aria-label={`Open ${link.title || host} in a new tab`}>
            <WebsiteIcon key={url.origin} origin={url.origin} />
            <span className="context-link-text"><strong>{link.title || host}</strong><span>{link.title ? `${host}${url.pathname === '/' ? '' : url.pathname}` : `${url.host}${url.pathname}${url.search}${url.hash}`}</span></span>
          </a>
          <div className="context-link-actions">
            <button className="icon-button" aria-label={`Edit ${link.title || host}`} title="Edit link" disabled={disabled} onClick={() => openEditor(link)}><Pencil size={18} /></button>
            <button className="icon-button" aria-label={`Remove ${link.title || host}`} title="Remove link" disabled={disabled} onClick={() => void onSave({ notes, context_links: links.filter(item => item.url !== link.url) }, 'Link removed.')}><Trash2 size={18} /></button>
          </div>
        </li>
      })}</ul> : <p className="context-links-empty">No links yet</p>}
      {links.length >= 100 && <p className="context-caption">This meeting has 100 links. Remove one to add another.</p>}
    </section>
    <div className="context-section-heading">
      <label htmlFor="meeting-context-text">Notes</label>
      <button className="button secondary" disabled={disabled || !dirty} onClick={() => void onSave({ notes }, 'Context saved.')}>
        {saving ? <Spinner size={15} /> : <Check size={15} />}{saving ? 'Saving…' : dirty ? 'Save' : 'Saved'}
      </button>
    </div>
    <textarea id="meeting-context-text" aria-label="Meeting notes" value={notes} onChange={event => onNotesChange(event.target.value)} disabled={pending} maxLength={100000} placeholder={'Add notes…'} />

    {editor && <Modal title={editor.originalUrl ? 'Edit context link' : 'Add context link'} onClose={() => setEditor(null)} closeDisabled={submitting}>
      <h2>{editor.originalUrl ? 'Edit link' : 'Add link'}</h2>
      <Feedback error={linkError} />
      <form onSubmit={event => { event.preventDefault(); void saveLink() }}>
        <label className="field">URL<input type="text" inputMode="url" autoCapitalize="none" autoCorrect="off" spellCheck={false} value={editor.url} onChange={event => { setEditor({ ...editor, url: event.target.value }); setLinkError(null) }} placeholder="https://example.com/document" maxLength={4096} required disabled={submitting} aria-invalid={!!linkError} /></label>
        <label className="field">Label <span className="optional">(optional)</span><input value={editor.title} onChange={event => setEditor({ ...editor, title: event.target.value })} placeholder="Use the page title" maxLength={240} disabled={submitting} /></label>
        <div className="button-row modal-actions"><button type="button" className="button secondary" onClick={() => setEditor(null)} disabled={submitting}>Cancel</button><button className="button primary" disabled={disabled || !editor.url.trim()}>{submitting ? <Spinner /> : <Check size={15} />}{submitting ? 'Saving…' : editor.originalUrl ? 'Save link' : 'Add link'}</button></div>
      </form>
    </Modal>}
  </section>
}
