// supabase/functions/quai-data/index.ts   (NEW edge function)
// Entry point only; all logic is in handler.ts (unit-tested in Node).
//
// Needs function secrets: SESSION_JWT_SECRET (the SAME value as the exchange server's).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to every edge function automatically.
// config.toml: leave verify_jwt at its default (true). The app sends the public (anon) key as
// the Authorization bearer, which Supabase's gateway accepts; the session token travels in
// X-Quai-Session and is verified here.
import { handle } from './handler.ts'

Deno.serve((req) =>
  handle(req, {
    url: (Deno.env.get('SUPABASE_URL') || '').replace(/\/+$/, ''),
    serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
    secret: Deno.env.get('SESSION_JWT_SECRET') || '',
  }, fetch))
