// supabase/functions/quai-data/handler.ts
// Every database write, file upload and private read of the Flutter app goes through here, so the
// public (anon) key can be locked to read-only. Authentication: the session token minted by the
// exchange server (HS256, SESSION_JWT_SECRET), sent in X-Quai-Session. Authorization rules are the
// same ones the earlier RLS design enforced, now in code, with the service role doing the work.
//
// Pure: no Deno APIs. Takes (Request, Env, fetch) and returns a Response, so tests run in Node.
import {
  canUploadBol, canUploadReceipt, encodePath, isUuid, sessionTokenFrom, validBolPath, validReceiptPath, verifySession,
  type Session,
} from './guard.ts'

export interface Env { url: string; serviceKey: string; secret: string }

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*', // auth is a bearer token, never a cookie
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-quai-session, x-supabase-api-version',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '600',
}
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } })

class HttpError extends Error {
  status: number
  code: string
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code }
}
const deny = (status: number, code: string): never => { throw new HttpError(status, code) }

export const MAX_JSON_BYTES = 2 * 1024 * 1024
export const MAX_UPLOAD_BYTES = 8 * 1024 * 1024
export const UPLOAD_TYPES = ['image/jpeg', 'image/png', 'image/webp']
const DATE = /^\d{4}-\d{2}-\d{2}$/
const FILE = '[A-Za-z0-9._-]{1,200}'
const ANNOUNCEMENT_PATH = new RegExp('^[0-9a-fA-F-]{36}/[0-9]{9,16}-' + FILE + '$')
const ADJUSTMENT_PATH = new RegExp('^adjustments/[0-9]{4}-[0-9]{2}-[0-9]{2}/' + FILE + '$')

/** The bytes must really be the picture type the caller claims (no html/svg/script uploads). */
export function looksLike(type: string, b: Uint8Array): boolean {
  const at = (i: number, s: string) => [...s].every((c, k) => b[i + k] === c.charCodeAt(0))
  if (type === 'image/jpeg') return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff
  if (type === 'image/png') return b[0] === 0x89 && at(1, 'PNG')
  if (type === 'image/webp') return at(0, 'RIFF') && at(8, 'WEBP')
  return false
}

const str = (v: unknown, max: number, field: string, required = false): string => {
  if (v === undefined || v === null) { if (required) deny(400, field + '_required'); return '' }
  if (typeof v !== 'string' || v.length > max) deny(400, field + '_invalid')
  const s = (v as string)
  if (required && !s.trim()) deny(400, field + '_required')
  return s
}

// ---------------------------------------------------------------------------------------------
class Db {
  private env: Env
  private f: typeof fetch
  constructor(env: Env, f: typeof fetch) { this.env = env; this.f = f }

  publicBase(bucket: string) { return this.env.url + '/storage/v1/object/public/' + bucket }

  private headers(extra: Record<string, string> = {}) {
    return { apikey: this.env.serviceKey, Authorization: 'Bearer ' + this.env.serviceKey, ...extra }
  }

  async rest(method: string, table: string, opts: { query?: Record<string, string>; body?: unknown; prefer?: string } = {}) {
    const q = opts.query ? '?' + new URLSearchParams(opts.query).toString() : ''
    let res: Response
    try {
      res = await this.f(this.env.url + '/rest/v1/' + table + q, {
        method,
        headers: this.headers({
          ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...(opts.prefer ? { Prefer: opts.prefer } : {}),
        }),
        body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      })
    } catch { throw new HttpError(502, 'database_unreachable') }
    if (res.status === 409) throw new HttpError(409, 'already_exists')
    if (!res.ok) { console.error('quai-data database', method, table, res.status); throw new HttpError(502, 'database_error') }
    const text = await res.text()
    return text ? JSON.parse(text) : null
  }

  async storage(method: string, path: string, init: { body?: BodyInit; headers?: Record<string, string> }) {
    let res: Response
    try {
      res = await this.f(this.env.url + '/storage/v1/object/' + path, { method, headers: this.headers(init.headers), body: init.body })
    } catch { throw new HttpError(502, 'storage_unreachable') }
    if (res.status === 409) throw new HttpError(409, 'already_exists')
    if (!res.ok) { console.error('quai-data storage', method, res.status); throw new HttpError(502, 'storage_error') }
  }
}

const isSuper = (s: Session) => s.appRole === 'superuser'
const needSuper = (s: Session) => { if (!isSuper(s)) deny(403, 'superuser_only') }

// ---------------------------------------------------------------------------------------------
async function upload(url: URL, req: Request, s: Session, db: Db) {
  const bucket = url.searchParams.get('bucket') || ''
  const path = url.searchParams.get('path') || ''
  const type = (req.headers.get('content-type') || '').split(';')[0].trim().toLowerCase()

  if (bucket === 'announcement-images') {
    needSuper(s)
    if (!ANNOUNCEMENT_PATH.test(path)) deny(422, 'bad_path')
  } else if (bucket === 'receipts') {
    if (ADJUSTMENT_PATH.test(path)) { /* any signed-in app user */ }
    else if (validBolPath(path)) { if (!canUploadBol(s)) deny(403, 'role_not_allowed') }
    else if (validReceiptPath(path)) { if (!canUploadReceipt(s)) deny(403, 'role_not_allowed') }
    else deny(422, 'bad_path')
  } else deny(422, 'bad_bucket')

  if (!UPLOAD_TYPES.includes(type)) deny(415, 'unsupported_type')
  const declared = Number(req.headers.get('content-length') || 0)
  if (declared > MAX_UPLOAD_BYTES) deny(413, 'too_large')
  const bytes = new Uint8Array(await req.arrayBuffer())
  if (bytes.length === 0) deny(400, 'empty_file')
  if (bytes.length > MAX_UPLOAD_BYTES) deny(413, 'too_large')
  if (!looksLike(type, bytes)) deny(415, 'content_mismatch')

  await db.storage('POST', bucket + '/' + encodePath(path), { body: bytes, headers: { 'Content-Type': type, 'x-upsert': 'false' } })
  return { url: db.publicBase(bucket) + '/' + encodePath(path) }
}

const ANNOUNCEMENT_FIELDS: Array<[string, number]> = [['title', 200], ['body', 8000], ['title_fr', 200], ['body_fr', 8000]]
function announcementRow(input: any, requireAll: boolean) {
  if (!input || typeof input !== 'object') deny(400, 'row_required')
  const row: Record<string, string> = {}
  for (const [k, max] of ANNOUNCEMENT_FIELDS) {
    if (input[k] === undefined) { if (requireAll && (k === 'title' || k === 'body')) deny(400, k + '_required'); continue }
    row[k] = str(input[k], max, k, k === 'title' || k === 'body')
  }
  return row
}

const HISTORY_COLUMNS = [
  'so_num', 'so_id', 'customer', 'service_type', 'service_type_id', 'status', 'event_status', 'ship_date', 'event_start_date',
  'city', 'state', 'shipping_location_id', 'shipping_location_name', 'sale_location_id', 'sale_location_name', 'truck_id',
  'truck_name', 'service_event_id', 'service_event_name', 'carrier_id', 'carrier_name', 'source',
]
const scalar = (v: unknown) => v === null || typeof v === 'number' || typeof v === 'boolean' || (typeof v === 'string' && v.length <= 300)

const inList = (xs: Array<string | number>) => 'in.(' + xs.map((x) => (typeof x === 'number' ? String(x) : '"' + x.replace(/["\\]/g, '') + '"')).join(',') + ')'

async function run(op: string, b: any, s: Session, db: Db): Promise<Record<string, unknown>> {
  switch (op) {
    // --- announcements: SuperUser only ----------------------------------------------------------
    case 'announcement.insert': {
      needSuper(s)
      const rows = await db.rest('POST', 'announcements', { body: announcementRow(b.row, true), prefer: 'return=representation' })
      if (!Array.isArray(rows) || !rows[0]?.id) deny(502, 'database_error')
      return { id: String(rows[0].id) }
    }
    case 'announcement.update': {
      needSuper(s)
      if (!isUuid(b.id)) deny(400, 'id_invalid')
      await db.rest('PATCH', 'announcements', { query: { id: 'eq.' + b.id }, body: { ...announcementRow(b.row, false), updated_at: new Date().toISOString() }, prefer: 'return=minimal' })
      return {}
    }
    case 'announcement.delete': {
      needSuper(s)
      if (!isUuid(b.id)) deny(400, 'id_invalid')
      await db.rest('DELETE', 'announcements', { query: { id: 'eq.' + b.id } })
      return {}
    }
    case 'announcement.image.add': {
      needSuper(s)
      if (!isUuid(b.announcementId)) deny(400, 'announcementId_invalid')
      const u = str(b.url, 600, 'url', true)
      if (!u.startsWith(db.publicBase('announcement-images') + '/')) deny(422, 'bad_url')
      await db.rest('POST', 'announcement_images', { body: { announcement_id: b.announcementId, storage_url: u }, prefer: 'return=minimal' })
      return {}
    }
    case 'announcement.image.remove': {
      needSuper(s)
      const u = str(b.url, 600, 'url', true)
      if (!u.startsWith(db.publicBase('announcement-images') + '/')) deny(422, 'bad_url')
      await db.rest('DELETE', 'announcement_images', { query: { storage_url: 'eq.' + u } })
      return {}
    }
    case 'files.remove': {
      needSuper(s)
      if (b.bucket !== 'announcement-images') deny(422, 'bad_bucket')
      const paths = b.paths
      if (!Array.isArray(paths) || paths.length === 0 || paths.length > 20 || !paths.every((p: unknown) => typeof p === 'string' && ANNOUNCEMENT_PATH.test(p))) deny(422, 'bad_path')
      await db.storage('DELETE', 'announcement-images', { body: JSON.stringify({ prefixes: paths }), headers: { 'Content-Type': 'application/json' } })
      return {}
    }

    // --- receipts / BOL log ---------------------------------------------------------------------
    case 'receipt.insert': {
      const r = b.row
      if (!r || typeof r !== 'object') deny(400, 'row_required')
      const path = r.storage_path
      const isBol = validBolPath(path)
      if (!isBol && !validReceiptPath(path)) deny(422, 'bad_storage_path')
      if (isBol ? !canUploadBol(s) : !canUploadReceipt(s)) deny(403, 'role_not_allowed')
      const publicUrl = db.publicBase('receipts') + '/' + encodePath(path)
      if (r.public_url !== publicUrl) deny(422, 'bad_url')
      const rows = await db.rest('POST', 'receipts', {
        body: {
          driver_name: str(r.driver_name, 120, 'driver_name', true), note: str(r.note, 2000, 'note'),
          storage_path: path, public_url: publicUrl,
          carrier_name: s.carrier, email_sent: false, // from the verified session, never from the body
        },
        prefer: 'return=representation',
      })
      return { id: Array.isArray(rows) && rows[0]?.id ? String(rows[0].id) : null }
    }

    // --- change reports ---------------------------------------------------------------------------
    case 'adjustment.insert': {
      const r = b.row
      if (!r || typeof r !== 'object') deny(400, 'row_required')
      if (!isUuid(r.id)) deny(400, 'id_invalid')
      if (r.order_kind !== 'SO' && r.order_kind !== 'TO') deny(400, 'order_kind_invalid')
      if (!Array.isArray(r.items) || r.items.length === 0 || r.items.length > 50 || JSON.stringify(r.items).length > 20000) deny(400, 'items_invalid')
      let photo: string | null = null
      if (r.photo_url !== undefined && r.photo_url !== null) {
        photo = str(r.photo_url, 600, 'photo_url')
        if (!photo.startsWith(db.publicBase('receipts') + '/adjustments/')) deny(422, 'bad_url')
      }
      let locations: string[] | null = null
      if (r.order_kind === 'TO' && r.transfer_locations !== undefined && r.transfer_locations !== null) {
        const t = r.transfer_locations
        if (!Array.isArray(t) || t.length > 4 || !t.every((x: unknown) => typeof x === 'string' && x.length <= 80)) deny(400, 'transfer_locations_invalid')
        locations = t
      }
      await db.rest('POST', 'order_adjustments', {
        body: {
          id: r.id, order_num: str(r.order_num, 40, 'order_num', true), order_kind: r.order_kind,
          reporter_name: str(r.reporter_name, 120, 'reporter_name'), items: r.items, note: str(r.note, 4000, 'note'),
          photo_url: photo, transfer_locations: locations,
          carrier_name: s.carrier, email_sent: false, // from the verified session, never from the body
        },
        prefer: 'return=minimal',
      })
      return { id: r.id }
    }

    // --- delivery history ---------------------------------------------------------------------------
    case 'history.upsert': {
      const rows = b.rows
      if (!Array.isArray(rows) || rows.length > 500) deny(400, 'rows_invalid')
      const mine = new Set(s.names)
      const bySo = new Map<string, Record<string, unknown>>()
      for (const r of rows) {
        if (!r || typeof r !== 'object') continue
        const so = r.so_num
        if (typeof so !== 'string' || !so || so.length > 40) continue
        if (!isSuper(s) && !(typeof r.carrier_name === 'string' && mine.has(r.carrier_name))) continue // not yours: skipped
        const clean: Record<string, unknown> = {}
        for (const k of HISTORY_COLUMNS) {
          const v = r[k]
          clean[k] = v === undefined || !scalar(v) ? null : v
        }
        clean.source = typeof r.source === 'string' && r.source ? r.source : 'app'
        bySo.set(so, clean)
      }
      if (bySo.size === 0) return { count: 0 }
      await db.rest('POST', 'delivery_history', {
        query: { on_conflict: 'so_num' }, body: [...bySo.values()], prefer: 'resolution=merge-duplicates,return=minimal',
      })
      return { count: bySo.size }
    }
    case 'history.list': {
      if (typeof b.from !== 'string' || !DATE.test(b.from) || typeof b.to !== 'string' || !DATE.test(b.to)) deny(400, 'range_invalid')
      const query: Record<string, string> = {
        select: '*', and: '(ship_date.gte.' + b.from + ',ship_date.lt.' + b.to + ')', order: 'ship_date.desc', limit: '2000',
      }
      if (b.carrierNames !== undefined && (!Array.isArray(b.carrierNames) || b.carrierNames.length > 50 || !b.carrierNames.every((n: unknown) => typeof n === 'string' && n.length <= 80))) deny(400, 'carrierNames_invalid')
      if (b.carrierIds !== undefined && (!Array.isArray(b.carrierIds) || b.carrierIds.length > 50 || !b.carrierIds.every((n: unknown) => Number.isInteger(n)))) deny(400, 'carrierIds_invalid')
      if (!isSuper(s)) {
        // a carrier only ever sees rows labelled with the names its login covers
        const asked: string[] | undefined = b.carrierNames && b.carrierNames.length ? b.carrierNames : undefined
        const allowed = asked ? s.names.filter((n) => asked.includes(n)) : s.names
        if (allowed.length === 0) return { rows: [] }
        query.carrier_name = inList(allowed)
      } else if (b.carrierNames && b.carrierNames.length && !(b.carrierIds && b.carrierIds.length)) {
        query.carrier_name = inList(b.carrierNames)
      }
      if (b.carrierIds && b.carrierIds.length) query.carrier_id = inList(b.carrierIds)
      const rows = await db.rest('GET', 'delivery_history', { query })
      return { rows: Array.isArray(rows) ? rows : [] }
    }
  }
  return deny(404, 'unknown_op')
}

// ---------------------------------------------------------------------------------------------
export async function handle(req: Request, env: Env, f: typeof fetch = fetch): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' })
  if (!env.url || !env.serviceKey || !env.secret || env.secret.length < 32) {
    console.error('quai-data: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SESSION_JWT_SECRET (32+ chars)')
    return json(500, { error: 'server_configuration' })
  }
  const session = await verifySession(sessionTokenFrom({ get: (n: string) => (n.toLowerCase() === 'authorization' ? null : req.headers.get(n)) }), env.secret)
  if (!session) return json(401, { error: 'invalid_session' })

  const url = new URL(req.url)
  const db = new Db(env, f)
  try {
    if (url.searchParams.get('op') === 'upload') return json(200, { ok: true, ...(await upload(url, req, session, db)) })
    const declared = Number(req.headers.get('content-length') || 0)
    if (declared > MAX_JSON_BYTES) deny(413, 'too_large')
    const text = await req.text()
    if (text.length > MAX_JSON_BYTES) deny(413, 'too_large')
    let body: any
    try { body = JSON.parse(text) } catch { return json(400, { error: 'invalid_json' }) }
    if (!body || typeof body !== 'object' || typeof body.op !== 'string') return json(400, { error: 'op_required' })
    return json(200, { ok: true, ...(await run(body.op, body, session, db)) })
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.code })
    console.error('quai-data failed', (e as Error)?.message)
    return json(500, { error: 'internal_error' })
  }
}
