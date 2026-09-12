export type Segment = { id: string; start: number; end: number; speaker: string; text: string }
export type ContextLink = { url: string; title: string }
export type Summary = { overview: string; key_points: string[]; decisions: string[]; action_items: { text: string; owner: string | null; due: string | null }[]; provider: string; model: string; generated_at: string }
export type Meeting = {
  id: string; title: string; created_at: string; updated_at: string; duration: number;
  status: 'ready' | 'transcribing' | 'transcribed' | 'summarizing' | 'complete' | 'error';
  progress: number; stage: string; error: string | null; audio_name: string; audio_url: string; video_url: string | null;
  language: string; speaker_count: number | null; speakers: Record<string, string>; segments: Segment[];
  summary: Summary | null; notes: string; context_links: ContextLink[];
}
export type SpeechModel = { id: string; name: string; tier: string; installed: boolean; download_mb: number; url: string; languages: string; timing: string }
export type SpeechStatus = { models?: SpeechModel[]; ready?: boolean; transcription_ready?: boolean; diarization_ready?: boolean; installing?: boolean; error?: string | null; detail?: string; progress?: number; stage?: string; [key: string]: unknown }
export const agentDefaults = { codex: { label: 'Codex', model: 'gpt-5.6-luna' }, 'claude-code': { label: 'Claude Code', model: 'claude-sonnet-5' } } as const
export type AgentProvider = keyof typeof agentDefaults
export type Settings = { transcription: { model: string; language: string; speaker_count: number | null }; summary: { provider: AgentProvider; model: string; reasoning_effort: 'low' | 'medium' | 'high' }; agents: Record<AgentProvider, { installed: boolean; command: string }>; speech: SpeechStatus }
export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  let response: Response
  try { response = await fetch(`/api${path}`, options) } catch { throw new Error('Could not reach the local server. Make sure Stillnote is running, then try again.') }
  if (!response.ok) {
    const data = await response.json().catch(() => null) as { detail?: unknown } | null
    const detail = typeof data?.detail === 'string' ? data.detail : 'The request could not be completed.'
    throw new Error(detail)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}
export function json(method: string, body: unknown): RequestInit { return { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } }
export function duration(seconds: number): string { const s = Math.max(0, Math.floor(seconds || 0)); return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s % 3600 / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` }
export function dateLabel(value: string): string { return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) }
export const languages = [['auto', 'Detect automatically'], ['en', 'English'], ['es', 'Spanish'], ['fr', 'French'], ['de', 'German'], ['it', 'Italian'], ['pt', 'Portuguese'], ['zh', 'Chinese'], ['ja', 'Japanese'], ['ko', 'Korean'], ['ar', 'Arabic'], ['hi', 'Hindi'], ['nl', 'Dutch'], ['ru', 'Russian']] as const
export const busy = (meeting: Meeting) => meeting.status === 'transcribing' || meeting.status === 'summarizing'
export const speechReady = (status?: SpeechStatus) => Boolean(status?.ready ?? (status?.transcription_ready && status?.diarization_ready))
