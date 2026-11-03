// supabase/functions/<fn>/guard.ts  (identical copy in send-transactional-email and quai-data)
// Pure helpers for the hardened send-transactional-email function. No Deno / network calls in
// here, so they are unit-tested in plain Node (see guard.test.ts).

export type AppRole = 'carrier' | 'logistique' | 'superuser'
export interface Session { carrier: string; uid: string; appRole: AppRole; exp: number; names: string[] }

const enc = new TextEncoder()

function b64uToBytes(s: string): Uint8Array {
  const pad = '='.repeat((4 - (s.length % 4)) % 4)
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad)
  return Uint8Array.from(bin, (c) => c.charCodeAt(0))
}

/** Verifies an HS256 session JWT from the exchange server. Returns null for anything wrong. */
export async function verifySession(
  token: string | null | undefined,
  secret: string,
  nowSec: number = Math.floor(Date.now() / 1000),
): Promise<Session | null> {
  if (!token || !secret) return null
  const parts = token.split('.')
  if (parts.length !== 3) return null
  try {
    const header = JSON.parse(new TextDecoder().decode(b64uToBytes(parts[0])))
    if (!header || header.alg !== 'HS256') return null // never "none", never another algorithm
    const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'])
    const ok = await crypto.subtle.verify('HMAC', key, b64uToBytes(parts[2]), enc.encode(parts[0] + '.' + parts[1]))
    if (!ok) return null
    const p = JSON.parse(new TextDecoder().decode(b64uToBytes(parts[1])))
    if (p.iss !== 'quai-exchange' || p.aud !== 'authenticated') return null
    if (typeof p.exp !== 'number' || p.exp <= nowSec) return null
    if (!['carrier', 'logistique', 'superuser'].includes(p.app_role)) return null
    // sub is a deterministic UUID (v5 of the carrier name); the readable name is the "carrier" claim.
    if (typeof p.carrier !== 'string' || !p.carrier || typeof p.sub !== 'string' || !p.sub) return null
    const names = Array.isArray(p.names) ? p.names.filter((n: unknown): n is string => typeof n === 'string') : []
    return { carrier: p.carrier, uid: p.sub, appRole: p.app_role, exp: p.exp, names }
  } catch {
    return null
  }
}

/** Token from X-Quai-Session, else from "Authorization: Bearer" (the app can send either). */
export function sessionTokenFrom(headers: { get(name: string): string | null }): string | null {
  const x = headers.get('x-quai-session')
  if (x) return x
  const a = headers.get('authorization') || ''
  return a.toLowerCase().startsWith('bearer ') ? a.slice(7).trim() : null
}

// --- routing tables: copied from lib/data/carriers.dart (same order, same rules) ----------------
const ALIAS_GROUP: Array<[string, string]> = [
  ["SADM - David", "SADM"],
  ["SADM - Éric", "SADM"],
  ["SADM - Jayson", "SADM"],
  ["SADM - Mathieu", "SADM"],
  ["SADM - Quai2go", "SADM"],
  ["SADM - Steve", "SADM"],
  ["Gat - Sam", "Gatineau"],
  ["Lindsay - Brendan", "Lindsay"],
  ["Lindsay - Cole", "Lindsay"],
  ["Lindsay - Laurent", "Lindsay"],
  ["Mt-Laurier - Steve", "Mt-Laurier"],
  ["Québec - Justin", "Québec"],
  ["Québec - Marc", "Québec"],
  ["Sherbrooke - Hervé", "Sherbrooke"],
  ["InterQL", "Gooseneck"],
  ["RIDEAU GOOSENECK", "Gooseneck"],
  ["OPEN GOOSENECK", "Gooseneck"],
  ["DA TRANSPORT", "Externe"],
  ["LANCEZ TRANSPORT", "Externe"],
  ["SD PRESTIGE", "Externe"],
  ["SADM - Logistique", "SADM"],
]

const GROUP_INBOX: Record<string, string> = {
  'SADM': 'sadm@groupeql.com',
  'Gooseneck': 'sadm@groupeql.com',
  'Gatineau': 'gatineau@groupeql.com',
  'Lindsay': 'lindsay@groupeql.com',
  'Mt-Laurier': 'mt-laurier@groupeql.com',
  'Québec': 'quebec@groupeql.com',
  'Externe': 'quebec@groupeql.com',
  'Sherbrooke': 'estrie@groupeql.com',
}
export const FALLBACK_INBOX = 'comptabilite@groupeql.com'
export const RECEIPT_INBOX = 'comptabilite@groupeql.com'
export const BOL_INBOX = 'sadm@groupeql.com'

/** Verbatim from lib/logic/receipts_policy.dart. "SADM - Quai2go" is deliberately absent. */
export const RECEIPTS_ALLOWED = new Set([
  'SADM - David', 'SADM - Éric', 'SADM - Jayson', 'SADM - Mathieu', 'SADM - Steve', 'Gat - Sam',
  'InterQL', 'Lindsay - Brendan', 'Lindsay - Cole', 'Lindsay - Laurent', 'Mt-Laurier - Steve',
  'Québec - Justin', 'Québec - Marc', 'Sherbrooke - Hervé', 'SADM - Logistique',
])

export function canUploadReceipt(s: Session): boolean {
  return s.appRole === 'superuser' || RECEIPTS_ALLOWED.has(s.carrier)
}
export function canUploadBol(s: Session): boolean {
  return s.appRole === 'logistique' || s.appRole === 'superuser'
}

export function adjustmentInbox(carrierName: string): string {
  const hit = ALIAS_GROUP.find(([n]) => n === carrierName)
  return (hit && GROUP_INBOX[hit[1]]) || FALLBACK_INBOX
}

/** Store inbox for a NetSuite location name (only ever returns one of OUR fixed addresses). */
export function locationInbox(location: string): string | null {
  const n = String(location).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
  if (/agathe|sadm/.test(n)) return GROUP_INBOX['SADM']
  if (n.includes('gatineau')) return GROUP_INBOX['Gatineau']
  if (n.includes('lindsay')) return GROUP_INBOX['Lindsay']
  if (n.includes('laurier')) return GROUP_INBOX['Mt-Laurier']
  if (n.includes('quebec')) return GROUP_INBOX['Québec']
  if (/sherbrooke|estrie/.test(n)) return GROUP_INBOX['Sherbrooke']
  return null
}

/** Change reports: transfers go to the stores involved; otherwise the carrier's group inbox. */
export function adjustmentRecipients(carrierName: string, transferLocations: string[] = []): string[] {
  const stores = transferLocations.map(locationInbox).filter((x): x is string => !!x)
  const list = stores.length ? stores : [adjustmentInbox(carrierName)]
  return [...new Set(list)]
}

export const isGroupeQl = (email: string) => /^[^@\s]+@groupeql\.com$/i.test(email.trim())
export const isUuid = (s: unknown): s is string =>
  typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)

const FILE = '[A-Za-z0-9._-]{1,120}'
const RECEIPT_PATH = new RegExp('^[0-9]{4}-[0-9]{2}-[0-9]{2}/' + FILE + '$')
const BOL_PATH = new RegExp('^bol/[0-9]{4}-[0-9]{2}-[0-9]{2}/' + FILE + '$')
export const validReceiptPath = (p: unknown): p is string => typeof p === 'string' && RECEIPT_PATH.test(p)
export const validBolPath = (p: unknown): p is string => typeof p === 'string' && BOL_PATH.test(p)

export const encodePath = (p: string) => p.split('/').map(encodeURIComponent).join('/')
