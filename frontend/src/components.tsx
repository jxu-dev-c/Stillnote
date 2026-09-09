import { useEffect, useRef } from 'react'
import type { ReactNode } from 'react'
import { Check, LoaderCircle, ShieldCheck, X } from 'lucide-react'

export function Modal({ title, children, onClose, wide = false, closeDisabled = false }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean; closeDisabled?: boolean }) {
  const dialog = useRef<HTMLDivElement>(null)
  const close = useRef(onClose)
  close.current = onClose
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const oldOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const focusable = () => Array.from(dialog.current?.querySelectorAll<HTMLElement>('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex="0"]') || [])
    const first = focusable().find(el => !el.classList.contains('modal-close')) || focusable()[0]
    first?.focus()
    const handle = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !closeDisabled) close.current()
      if (event.key === 'Tab') {
        const items = focusable(); const firstItem = items[0]; const last = items[items.length - 1]
        if (event.shiftKey && document.activeElement === firstItem) { event.preventDefault(); last?.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); firstItem?.focus() }
      }
    }
    document.addEventListener('keydown', handle)
    return () => { document.removeEventListener('keydown', handle); document.body.style.overflow = oldOverflow; previous?.focus() }
  }, [closeDisabled])
  return <div className="modal-backdrop" onMouseDown={event => { if (event.target === event.currentTarget && !closeDisabled) onClose() }}><div className={`modal ${wide ? 'modal-wide' : ''}`} role="dialog" aria-modal="true" aria-label={title} ref={dialog}><button className="icon-button modal-close" aria-label="Close dialog" onClick={onClose} disabled={closeDisabled}><X size={19} /></button>{children}</div></div>
}
export function PrivacyBadge({ compact = false }: { compact?: boolean }) { return <span className={`privacy-badge ${compact ? 'compact' : ''}`}><ShieldCheck size={14} />{compact ? 'Local & private' : 'Your audio stays on this device'}</span> }
export function Spinner({ size = 16 }: { size?: number }) { return <LoaderCircle className="spin" size={size} aria-hidden="true" /> }
export function Feedback({ error, success }: { error?: string | null; success?: string | null }) { return error ? <div className="feedback error" role="alert">{error}</div> : success ? <div className="feedback success" role="status"><Check size={16} />{success}</div> : null }
export function BrandMark({ large = false }: { large?: boolean }) { return <div className={`brand-mark ${large ? 'large' : ''}`} aria-hidden="true"><span /><span /><span /><span /></div> }
