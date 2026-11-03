// Run:  node --test supabase/functions/quai-data/*.test.ts     (Node 22.18+ / 24 runs TypeScript directly)
import test from 'node:test'
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { handle, type Env } from './handler.ts'

const SECRET = 's'.repeat(40)
const SERVICE = 'SERVICE-ROLE-KEY-VALUE'
const URL_ = 'https://p.supabase.test'
const env: Env = { url: URL_, serviceKey: SERVICE, secret: SECRET }
const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url')
function mint(carrier: string, appRole: string, names: string[] = [carrier], secret = SECRET, over: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000)
  const h = b64({ alg: 'HS256', typ: 'JWT' })
  const p = b64({ iss: 'quai-exchange', aud: 'authenticated', role: 'authenticated', sub: '00000000-0000-5000-8000-000000000001', carrier, app_role: appRole, names, iat: now, exp: now + 600, ...over })
  return h + '.' + p + '.' + createHmac('sha256', secret).update(h + '.' + p).digest('base64url')
}
const GAT = mint('Gat - Sam', 'carrier')
const QUAI2 = mint('SADM - Quai2go', 'carrier')
const LOGI = mint('SADM - Logistique', 'logistique', ['SADM - David', 'RIDEAU GOOSENECK'])
const SU = mint('SuperUser', 'superuser', [])

interface Call { method: string; url: string; headers: Record<string, string>; body: any; raw: any }
function fake(handlers: { rest?: (c: Call) => Response | undefined; status?: number } = {}) {
  const calls: Call[] = []
  const f = (async (input: any, init: any = {}) => {
    const headers: Record<string, string> = {}
    for (const [k, v] of Object.entries(init.headers || {})) headers[k.toLowerCase()] = String(v)
    let body: any = init.body
    if (typeof body === 'string') { try { body = JSON.parse(body) } catch { /* keep */ } }
    const c: Call = { method: init.method || 'GET', url: String(input), headers, body, raw: init.body }
    calls.push(c)
    const custom = handlers.rest?.(c)
    if (custom) return custom
    if (handlers.status) return new Response('boom ' + SERVICE, { status: handlers.status })
    if (c.method === 'POST' && c.url.includes('/rest/v1/') && c.headers.prefer?.includes('representation')) {
      return new Response(JSON.stringify([{ id: '11111111-1111-4111-8111-111111111111' }]), { status: 201 })
    }
    if (c.method === 'GET') return new Response(JSON.stringify([{ so_num: 'SO1' }]), { status: 200 })
    return new Response('', { status: 201 })
  }) as typeof fetch
  return { f, calls }
}
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 6, 7, 8])
const call = (token: string | null, op: string, body: Record<string, unknown> = {}, f?: typeof fetch) =>
  handle(new Request(URL_ + '/functions/v1/quai-data', {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ANON', ...(token ? { 'X-Quai-Session': token } : {}) },
    body: JSON.stringify({ op, ...body }),
  }), env, f)
const up = (token: string | null, bucket: string, path: string, bytes: Uint8Array = JPG, type = 'image/jpeg', f?: typeof fetch) =>
  handle(new Request(URL_ + '/functions/v1/quai-data?op=upload&bucket=' + bucket + '&path=' + encodeURIComponent(path), {
    method: 'POST', headers: { 'Content-Type': type, Authorization: 'Bearer ANON', ...(token ? { 'X-Quai-Session': token } : {}) }, body: bytes,
  }), env, f)
const j = async (r: Response) => r.json() as Promise<any>
const ID = '22222222-2222-4222-8222-222222222222'
const ANN_ID = '33333333-3333-4333-8333-333333333333'
const ANN_PATH = ANN_ID + '/1762000000000-photo.jpg'

test('no session / anon key / garbage / expired / wrong secret: 401 and the database is never touched', async () => {
  const { f, calls } = fake()
  for (const t of [null, 'ANON', 'a.b.c', mint('Gat - Sam', 'carrier', ['x'], SECRET, { exp: 1 }), mint('Gat - Sam', 'carrier', ['x'], 'z'.repeat(40))]) {
    const r = await call(t, 'announcement.insert', { row: { title: 'a', body: 'b' } }, f)
    assert.equal(r.status, 401, String(t))
  }
  // the anon key in the Authorization bearer is NOT accepted as a session
  const r = await handle(new Request(URL_ + '/f', { method: 'POST', headers: { Authorization: 'Bearer ' + SU }, body: JSON.stringify({ op: 'announcement.delete', id: ANN_ID }) }), env, f)
  assert.equal(r.status, 401, 'the session must come in X-Quai-Session')
  assert.equal(calls.length, 0)
})

test('server must be configured: short or missing secret, missing service key -> 500, nothing runs', async () => {
  for (const bad of [{ ...env, secret: 'short' }, { ...env, secret: '' }, { ...env, serviceKey: '' }, { ...env, url: '' }]) {
    const { f, calls } = fake()
    const r = await handle(new Request(URL_ + '/f', { method: 'POST', headers: { 'X-Quai-Session': SU }, body: '{"op":"announcement.delete"}' }), bad, f)
    assert.equal(r.status, 500); assert.equal(calls.length, 0)
  }
})

test('CORS preflight allows the headers the app sends; other verbs are 405', async () => {
  const r = await handle(new Request(URL_ + '/f', { method: 'OPTIONS' }), env)
  assert.equal(r.status, 204)
  const h = (r.headers.get('access-control-allow-headers') || '').toLowerCase()
  for (const x of ['x-quai-session', 'authorization', 'apikey', 'content-type']) assert.ok(h.includes(x), x)
  assert.equal((await handle(new Request(URL_ + '/f', { method: 'GET' }), env)).status, 405)
})

test('announcements: SuperUser only; carriers and Logistique get 403 and nothing is sent', async () => {
  const { f, calls } = fake()
  for (const t of [GAT, LOGI]) {
    assert.equal((await call(t, 'announcement.insert', { row: { title: 'a', body: 'b' } }, f)).status, 403)
    assert.equal((await call(t, 'announcement.update', { id: ANN_ID, row: { title: 'a' } }, f)).status, 403)
    assert.equal((await call(t, 'announcement.delete', { id: ANN_ID }, f)).status, 403)
    assert.equal((await call(t, 'announcement.image.add', { announcementId: ANN_ID, url: URL_ + '/storage/v1/object/public/announcement-images/' + ANN_PATH }, f)).status, 403)
    assert.equal((await call(t, 'announcement.image.remove', { url: URL_ + '/storage/v1/object/public/announcement-images/' + ANN_PATH }, f)).status, 403)
    assert.equal((await call(t, 'files.remove', { bucket: 'announcement-images', paths: [ANN_PATH] }, f)).status, 403)
    assert.equal((await up(t, 'announcement-images', ANN_PATH, JPG, 'image/jpeg', f)).status, 403)
  }
  assert.equal(calls.length, 0)
})

test('announcements: SuperUser insert / update / delete / images, with the service key and a field allow-list', async () => {
  const { f, calls } = fake()
  let r = await call(SU, 'announcement.insert', { row: { title: ' T ', body: 'B', title_fr: 'TF', body_fr: 'BF', is_active: false, id: 'evil', created_at: 'x' } }, f)
  assert.equal(r.status, 200); assert.deepEqual(await j(r), { ok: true, id: '11111111-1111-4111-8111-111111111111' })
  assert.equal(calls[0].url, URL_ + '/rest/v1/announcements')
  assert.equal(calls[0].headers.authorization, 'Bearer ' + SERVICE)
  assert.deepEqual(calls[0].body, { title: ' T ', body: 'B', title_fr: 'TF', body_fr: 'BF' }, 'only the four text fields')

  assert.equal((await call(SU, 'announcement.insert', { row: { title: '', body: 'x' } }, f)).status, 400)
  assert.equal((await call(SU, 'announcement.insert', { row: { title: 'x', body: 'y'.repeat(9000) } }, f)).status, 400)

  r = await call(SU, 'announcement.update', { id: ANN_ID, row: { title: 'N', is_active: false } }, f)
  assert.equal(r.status, 200)
  const patch = calls.find((c) => c.method === 'PATCH')!
  assert.equal(patch.url, URL_ + '/rest/v1/announcements?id=eq.' + ANN_ID)
  assert.deepEqual(Object.keys(patch.body).sort(), ['title', 'updated_at'])

  assert.equal((await call(SU, 'announcement.update', { id: ANN_ID + '&or=(1=1)', row: { title: 'x' } }, f)).status, 400, 'filter injection')
  assert.equal((await call(SU, 'announcement.delete', { id: 'not-a-uuid' }, f)).status, 400)
  assert.equal((await call(SU, 'announcement.delete', { id: ANN_ID }, f)).status, 200)
  assert.ok(calls.some((c) => c.method === 'DELETE' && c.url === URL_ + '/rest/v1/announcements?id=eq.' + ANN_ID))

  const good = URL_ + '/storage/v1/object/public/announcement-images/' + ANN_PATH
  assert.equal((await call(SU, 'announcement.image.add', { announcementId: ANN_ID, url: good }, f)).status, 200)
  assert.equal((await call(SU, 'announcement.image.add', { announcementId: ANN_ID, url: 'https://evil.example/x.jpg' }, f)).status, 422)
  assert.equal((await call(SU, 'announcement.image.remove', { url: good }, f)).status, 200)
  const del = calls.filter((c) => c.method === 'DELETE').pop()!
  assert.equal(new URL(del.url).searchParams.get('storage_url'), 'eq.' + good)
})

test('uploads: path rules per role, picture types only, real picture bytes, size cap', async () => {
  const { f, calls } = fake()
  const D = '2026-11-03'
  const ok = async (t: string, bucket: string, path: string) => (await up(t, bucket, path, JPG, 'image/jpeg', f)).status
  assert.equal(await ok(GAT, 'receipts', D + '/abc.jpg'), 200)
  assert.equal(await ok(QUAI2, 'receipts', D + '/abc.jpg'), 403, 'Quai2go is not on the receipts list')
  assert.equal(await ok(QUAI2, 'receipts', 'adjustments/' + D + '/abc-photo.jpg'), 200, 'but may attach a change-report photo')
  assert.equal(await ok(GAT, 'receipts', 'bol/' + D + '/abc.jpg'), 403)
  assert.equal(await ok(LOGI, 'receipts', 'bol/' + D + '/abc.jpg'), 200)
  assert.equal(await ok(GAT, 'receipts', '../../evil.html'), 422)
  assert.equal(await ok(GAT, 'receipts', D + '/a/b.jpg'), 422)
  assert.equal(await ok(GAT, 'order-photos', D + '/abc.jpg'), 422)
  assert.equal(await ok(GAT, 'other', D + '/abc.jpg'), 422)
  assert.equal(await ok(SU, 'announcement-images', ANN_PATH), 200)
  assert.equal(await ok(SU, 'announcement-images', 'x.jpg'), 422)

  assert.equal((await up(GAT, 'receipts', D + '/a.html', JPG, 'text/html', f)).status, 415)
  assert.equal((await up(GAT, 'receipts', D + '/a.jpg', new Uint8Array([60, 104, 116, 109, 108, 62]), 'image/jpeg', f)).status, 415, '<html> labelled as jpeg')
  assert.equal((await up(GAT, 'receipts', D + '/a.png', JPG, 'image/png', f)).status, 415, 'jpeg bytes labelled png')
  assert.equal((await up(GAT, 'receipts', D + '/a.jpg', new Uint8Array(0), 'image/jpeg', f)).status, 400)
  const big = new Uint8Array(8 * 1024 * 1024 + 1); big.set(JPG)
  assert.equal((await up(GAT, 'receipts', D + '/a.jpg', big, 'image/jpeg', f)).status, 413)
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]); const webp = new Uint8Array([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80])
  assert.equal((await up(GAT, 'receipts', D + '/a.png', png, 'image/png', f)).status, 200)
  assert.equal((await up(GAT, 'receipts', D + '/a.webp', webp, 'image/webp', f)).status, 200)

  const first = calls[0]
  assert.equal(first.method, 'POST'); assert.equal(first.url, URL_ + '/storage/v1/object/receipts/' + D + '/abc.jpg')
  assert.equal(first.headers['x-upsert'], 'false'); assert.equal(first.headers.authorization, 'Bearer ' + SERVICE)
  const r = await up(GAT, 'receipts', D + '/zzz.jpg', JPG, 'image/jpeg', f)
  assert.deepEqual(await j(r), { ok: true, url: URL_ + '/storage/v1/object/public/receipts/' + D + '/zzz.jpg' })
})

test('receipts: allow-list + forced carrier_name + exact url; BOL only for Logistique/SuperUser', async () => {
  const { f, calls } = fake()
  const path = '2026-11-03/abc.jpg'
  const row = (p: string, extra: Record<string, unknown> = {}) => ({ driver_name: 'Bob', carrier_name: 'Lindsay - Cole', note: 'n', storage_path: p, public_url: URL_ + '/storage/v1/object/public/receipts/' + p, email_sent: true, ...extra })
  let r = await call(GAT, 'receipt.insert', { row: row(path) }, f)
  assert.equal(r.status, 200); assert.equal((await j(r)).id, '11111111-1111-4111-8111-111111111111')
  assert.equal(calls[0].body.carrier_name, 'Gat - Sam', 'taken from the session, not from the body')
  assert.equal(calls[0].body.email_sent, false)
  assert.equal((await call(QUAI2, 'receipt.insert', { row: row(path) }, f)).status, 403)
  assert.equal((await call(GAT, 'receipt.insert', { row: row('bol/' + path) }, f)).status, 403)
  assert.equal((await call(LOGI, 'receipt.insert', { row: row('bol/' + path) }, f)).status, 200)
  assert.equal((await call(GAT, 'receipt.insert', { row: row(path, { public_url: 'https://evil.example/x.jpg' }) }, f)).status, 422)
  assert.equal((await call(GAT, 'receipt.insert', { row: row('../x') }, f)).status, 422)
  assert.equal((await call(GAT, 'receipt.insert', { row: row(path, { driver_name: '  ' }) }, f)).status, 400)
})

test('change reports: any signed-in user, carrier_name forced, shape checked, duplicate id = 409', async () => {
  const photo = URL_ + '/storage/v1/object/public/receipts/adjustments/2026-11-03/x-photo.jpg'
  const base = { id: ID, order_num: 'TO123', order_kind: 'TO', carrier_name: 'Lindsay - Cole', reporter_name: 'Bob', items: [{ sku: 'A', qty: 1 }], note: 'n', photo_url: photo, transfer_locations: ['Ste-Agathe', 'Québec'], email_sent: true }
  const { f, calls } = fake()
  let r = await call(QUAI2, 'adjustment.insert', { row: base }, f)
  assert.equal(r.status, 200)
  assert.equal(calls[0].url, URL_ + '/rest/v1/order_adjustments')
  assert.equal(calls[0].body.carrier_name, 'SADM - Quai2go'); assert.equal(calls[0].body.email_sent, false)
  assert.deepEqual(calls[0].body.transfer_locations, ['Ste-Agathe', 'Québec'])
  r = await call(GAT, 'adjustment.insert', { row: { ...base, order_kind: 'SO', transfer_locations: ['Québec'] } }, f)
  assert.equal(calls[1].body.transfer_locations, null, 'locations only count for transfer orders')
  for (const bad of [{ id: 'x' }, { order_kind: 'XX' }, { items: [] }, { items: new Array(51).fill({}) }, { order_num: '' }, { photo_url: 'https://evil.example/a.jpg' },
    { transfer_locations: ['a', 'b', 'c', 'd', 'e'] }, { transfer_locations: 'Québec' }, { note: 'x'.repeat(4001) }]) {
    assert.equal((await call(GAT, 'adjustment.insert', { row: { ...base, ...bad } }, f)).status, 400 + ((bad as any).photo_url ? 22 : 0), JSON.stringify(bad).slice(0, 40))
  }
  const dup = fake({ status: 409 })
  assert.equal((await call(GAT, 'adjustment.insert', { row: base }, dup.f)).status, 409)
})

test('history.upsert: a carrier only writes rows labelled with its own names; SuperUser any; at most 500; one row per so_num', async () => {
  const { f, calls } = fake()
  const rows = [
    { so_num: 'SO1', carrier_name: 'Gat - Sam', customer: 'c', ship_date: '2026-11-03', evil_column: 1 },
    { so_num: 'SO2', carrier_name: 'Lindsay - Cole' },
    { so_num: 'SO1', carrier_name: 'Gat - Sam', customer: 'later' },
    { so_num: '', carrier_name: 'Gat - Sam' },
    { carrier_name: 'Gat - Sam' },
    { so_num: 'SO3', carrier_name: 'Gat - Sam', customer: { nested: true } },
  ]
  let r = await call(GAT, 'history.upsert', { rows }, f)
  assert.equal(r.status, 200); assert.equal((await j(r)).count, 2)
  const c = calls[0]
  assert.equal(c.url, URL_ + '/rest/v1/delivery_history?on_conflict=so_num')
  assert.equal(c.headers.prefer, 'resolution=merge-duplicates,return=minimal')
  assert.deepEqual(c.body.map((x: any) => x.so_num).sort(), ['SO1', 'SO3'])
  assert.equal(c.body.find((x: any) => x.so_num === 'SO1').customer, 'later')
  assert.equal(c.body.find((x: any) => x.so_num === 'SO3').customer, null, 'objects are not stored')
  assert.equal(c.body[0].source, 'app'); assert.ok(!('evil_column' in c.body[0]))
  assert.equal(new Set(c.body.map((x: any) => Object.keys(x).join())).size, 1, 'same keys on every row (PostgREST bulk upsert)')

  // nothing of theirs -> nothing written
  calls.length = 0
  r = await call(GAT, 'history.upsert', { rows: [{ so_num: 'SO2', carrier_name: 'Lindsay - Cole' }] }, f)
  assert.equal((await j(r)).count, 0); assert.equal(calls.length, 0)
  // Logistique writes for its linked trucks, SuperUser for anyone
  assert.equal((await j(await call(LOGI, 'history.upsert', { rows: [{ so_num: 'A', carrier_name: 'RIDEAU GOOSENECK' }, { so_num: 'B', carrier_name: 'Gat - Sam' }] }, f))).count, 1)
  assert.equal((await j(await call(SU, 'history.upsert', { rows: [{ so_num: 'A', carrier_name: 'x' }, { so_num: 'B', carrier_name: 'y' }] }, f))).count, 2)
  assert.equal((await call(GAT, 'history.upsert', { rows: new Array(501).fill({ so_num: 'x', carrier_name: 'Gat - Sam' }) }, f)).status, 400)
  assert.equal((await call(GAT, 'history.upsert', { rows: 'nope' }, f)).status, 400)
})

test('history.list: scoped to the caller\'s names, ids/names narrow it further, SuperUser sees all', async () => {
  const { f, calls } = fake()
  const q = (i = 0) => new URL(calls[i].url).searchParams
  let r = await call(GAT, 'history.list', { from: '2026-11-01', to: '2026-12-01' }, f)
  assert.equal(r.status, 200); assert.deepEqual((await j(r)).rows, [{ so_num: 'SO1' }])
  assert.equal(q().get('carrier_name'), 'in.("Gat - Sam")'); assert.equal(q().get('and'), '(ship_date.gte.2026-11-01,ship_date.lt.2026-12-01)')
  assert.equal(calls[0].headers.authorization, 'Bearer ' + SERVICE)

  calls.length = 0
  await call(LOGI, 'history.list', { from: '2026-11-01', to: '2026-12-01', carrierNames: ['RIDEAU GOOSENECK', 'Gat - Sam'] }, f)
  assert.equal(q().get('carrier_name'), 'in.("RIDEAU GOOSENECK")', 'a name outside the login is dropped')
  calls.length = 0
  await call(GAT, 'history.list', { from: '2026-11-01', to: '2026-12-01', carrierIds: [64, 65] }, f)
  assert.equal(q().get('carrier_id'), 'in.(64,65)'); assert.equal(q().get('carrier_name'), 'in.("Gat - Sam")')
  calls.length = 0
  const none = await call(GAT, 'history.list', { from: '2026-11-01', to: '2026-12-01', carrierNames: ['Lindsay - Cole'] }, f)
  assert.deepEqual((await j(none)).rows, []); assert.equal(calls.length, 0, 'asking for someone else\'s rows never reaches the database')
  const noNames = await call(mint('Nobody', 'carrier', []), 'history.list', { from: '2026-11-01', to: '2026-12-01' }, f)
  assert.deepEqual((await j(noNames)).rows, []); assert.equal(calls.length, 0)
  await call(SU, 'history.list', { from: '2026-11-01', to: '2026-12-01' }, f)
  assert.equal(q().get('carrier_name'), null)
  assert.equal((await call(GAT, 'history.list', { from: '2026-11-01;drop', to: '2026-12-01' }, f)).status, 400)
  assert.equal((await call(GAT, 'history.list', { from: '2026-11-01', to: '2026-12-01', carrierIds: ['1)or(1=1'] }, f)).status, 400)
})

test('database / storage failures: 502 with a fixed body that never contains upstream text or the service key', async () => {
  for (const status of [500, 401, 404]) {
    const { f } = fake({ status })
    for (const r of [await call(SU, 'announcement.delete', { id: ANN_ID }, f), await up(GAT, 'receipts', '2026-11-03/a.jpg', JPG, 'image/jpeg', f)]) {
      assert.equal(r.status, 502)
      const text = await r.text()
      assert.ok(!text.includes(SERVICE) && !text.includes('boom'), text)
    }
  }
  const down = (async () => { throw new Error('ECONNREFUSED ' + SERVICE) }) as typeof fetch
  const r = await call(SU, 'announcement.delete', { id: ANN_ID }, down)
  assert.equal(r.status, 502); assert.ok(!(await r.text()).includes(SERVICE))
})

test('unknown op 404, bad JSON 400, oversized JSON 413', async () => {
  const { f, calls } = fake()
  assert.equal((await call(GAT, 'drop.everything', {}, f)).status, 404)
  const bad = await handle(new Request(URL_ + '/f', { method: 'POST', headers: { 'X-Quai-Session': GAT }, body: '{nope' }), env, f)
  assert.equal(bad.status, 400)
  const huge = await handle(new Request(URL_ + '/f', { method: 'POST', headers: { 'X-Quai-Session': GAT, 'Content-Length': String(3 * 1024 * 1024) }, body: '{}' }), env, f)
  assert.equal(huge.status, 413)
  assert.equal(calls.length, 0)
})

test('guard.ts is the same file in both functions, and index.ts passes only the three settings', () => {
  const here = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8')
  try {
    assert.equal(here('./guard.ts'), here('../send-transactional-email/guard.ts'))
  } catch (e: any) { if (e.code !== 'ENOENT') throw e } // the email function lives elsewhere in some checkouts
  assert.ok(/SESSION_JWT_SECRET/.test(here('./index.ts')) && !/SUPABASE_JWT_SECRET/.test(here('./index.ts')))
})
