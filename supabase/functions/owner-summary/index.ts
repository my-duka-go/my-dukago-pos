// supabase/functions/owner-summary/index.ts
//
// Owner multi-branch dashboard (Phase 2). Read-only. Given an Admin PIN for ONE branch, it resolves
// that branch's group (shops.group_id) and returns a performance summary for every branch in the group:
// sales (today / 7 days / month, value + count), gross profit, top products this month, staff active
// today, and a recent-activity feed — per branch. The client shows a side-by-side comparison + per-branch
// detail. Aggregation runs in public.owner_group_summary() (SECURITY DEFINER), called here with the exact
// shop_ids resolved from the group, so one branch can only ever see its own group's siblings.
//
// Auth mirrors shop-auth: called from the browser with the anon key; the Admin PIN is verified on the
// server (scrambled-PIN match), rate-limited per shop, and the official app origin is enforced.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const MAX_FAILS = 10, WINDOW_MS = 10 * 60 * 1000, LOCK_MS = 5 * 60 * 1000;

const ALLOWED_ORIGINS = (Deno.env.get('ALLOWED_ORIGINS') || 'https://my-duka-go.github.io,https://muturifrancis25-dev.github.io').split(',').map(x => x.trim()).filter(Boolean);
const CORS = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGINS[0],
  'Vary': 'Origin',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

function clientIp(req: Request) {
  return (req.headers.get('cf-connecting-ip') || req.headers.get('x-real-ip') || (req.headers.get('x-forwarded-for') || '').split(',')[0] || 'unknown').trim().slice(0, 64);
}
async function hit(key: string, limit = MAX_FAILS) {
  const { data, error } = await admin.rpc('auth_attempt_hit', { p_key: key, p_window_s: Math.round(WINDOW_MS / 1000), p_limit: limit, p_lock_s: Math.round(LOCK_MS / 1000) });
  if (error) throw new Error('rate limit: ' + error.message);
  const d = data as { allowed: boolean; retry_seconds: number };
  return { allowed: !!d?.allowed, retry: Number(d?.retry_seconds || 0) };
}
async function clearFails(key: string) { await admin.rpc('auth_attempt_clear', { p_key: key }); }

const handle = async (req: Request) => {
  const origin = req.headers.get('origin');
  if (origin && !ALLOWED_ORIGINS.includes(origin)) return json({ ok: false, code: 'forbidden_origin' }, 403);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const shopId = String(body.shopId || '');
    const pin = String(body.adminPin || '');
    if (!/^[0-9a-f-]{36}$/i.test(shopId)) return json({ ok: false, code: 'bad_request' }, 400);
    if (!/^(\d{4}|\d{6})$/.test(pin)) return json({ ok: false, code: 'bad_request' }, 400);

    // Rate-limit wrong Admin PINs for this shop (shares the sign-in lock behaviour).
    const key = 'ownsum:' + shopId, ipKey = 'ownsumip:' + clientIp(req);
    if (!(await hit(ipKey, 40)).allowed) return json({ ok: false, code: 'locked' }, 429);
    const att = await hit(key);
    if (!att.allowed) return json({ ok: false, code: 'locked', retry_seconds: att.retry }, 429);

    // Verify the Admin PIN against THIS shop (scrambled-PIN match, same as shop-auth).
    const { data: ph, error: phe } = await admin.rpc('pin_hash', { p_pin: pin });
    if (phe || !ph) return json({ ok: false, code: 'server_error', detail: phe?.message || 'hash failed' }, 500);
    const { data: staffRow } = await admin.from('staff').select('id,role')
      .eq('shop_id', shopId).eq('active', true).eq('role', 'admin')
      .or(`pin.eq.${ph},pin.eq.${pin}`).limit(1).maybeSingle();
    if (!staffRow) return json({ ok: false, code: 'bad_pin' }, 401);
    await clearFails(key);

    // Resolve this shop's group, then every ACTIVE branch in it.
    const { data: me } = await admin.from('shops').select('id,name,group_id,group_name').eq('id', shopId).maybeSingle();
    if (!me) return json({ ok: false, code: 'not_found' }, 404);
    if (!me.group_id) {
      return json({ ok: true, grouped: false, group_name: null, branches: [], generated_at: new Date().toISOString() });
    }
    const { data: sibs } = await admin.from('shops').select('id').eq('group_id', me.group_id).neq('active', false);
    const ids = (sibs || []).map(r => r.id);
    if (!ids.length) return json({ ok: true, grouped: false, group_name: me.group_name || null, branches: [], generated_at: new Date().toISOString() });

    const { data: summary, error: se } = await admin.rpc('owner_group_summary', { p_shop_ids: ids, p_tz: 'Africa/Nairobi' });
    if (se) return json({ ok: false, code: 'server_error', detail: se.message }, 500);

    return json({
      ok: true,
      grouped: true,
      group_name: me.group_name || 'My branches',
      branches: summary || [],
      generated_at: new Date().toISOString(),
    });
  } catch (e) {
    return json({ ok: false, code: 'server_error', detail: String(e) }, 500);
  }
};

Deno.serve(async (req) => {
  const res = await handle(req);
  const origin = req.headers.get('origin');
  if (origin && ALLOWED_ORIGINS.includes(origin)) res.headers.set('Access-Control-Allow-Origin', origin);
  return res;
});
