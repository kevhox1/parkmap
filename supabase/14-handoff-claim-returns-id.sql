-- WePark 14 — handoff_claim also returns the pass `id`.
--
-- WHY: handoff-depart / handoff-extend / handoff-cancel require {id, claimer_secret}, but handoff_claim (13) returned
-- {status, leave_at, expires_at, claimer_secret} with no id, and handoff_peek does not return it either, so a claimer
-- (web fallback, App Clip, full-app driver) could never depart/extend/cancel. Fix: add 'id', r.id to the armed result.
-- Security: no new oracle. The id is useless without the 128-bit claimer_secret (handoff_gate needs both), only the
-- successful claimer ever receives it (together with the secret), and every failure shape is still the uniform
-- {"status":"unavailable"}.
--
-- IDEMPOTENT: create or replace with the identical signature; grants re-asserted. DEPENDS ON 13 (apply 13 first).
-- Body is identical to 13's handoff_claim except the final jsonb_build_object. Feature stays dark
-- (HANDOFF_ENABLED=false); this does not touch the flag.
-- Deploy after applying: supabase functions deploy handoff-claim --no-verify-jwt

create or replace function public.handoff_claim(
  p_token text, p_leave_at timestamptz, p_push_token text, p_activity_token text, p_topic text,
  p_claimer uuid, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r        public.spot_handoffs;
  v_now    timestamptz := now();
  v_leave  timestamptz;
  v_secret text;
  v_cap    timestamptz := internal.floor5(now() + interval '240 minutes');   -- HANDOFF_MAX_HORIZON_MIN
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('claim', coalesce(p_ip_hash, 'unknown'), 20, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  -- value-only validation (independent of the token => reveals nothing about token state). Horizon cap = 240 min.
  if p_leave_at is null or p_leave_at > v_now + interval '240 minutes 30 seconds' or p_leave_at < v_now - interval '10 minutes' then
    return '{"invalid_leave_at":true}'::jsonb;
  end if;

  select * into r from public.spot_handoffs where token_hash = internal.sha(p_token) for update;   -- row lock = atomic single claim
  if not found or r.status <> 'created' or r.expires_at <= v_now then return '{"status":"unavailable"}'::jsonb; end if;
  if internal.handoff_user_suspended(r.seeker_id) or internal.handoff_user_suspended(p_claimer) then
    return '{"status":"unavailable"}'::jsonb;
  end if;
  if p_claimer is not null and p_claimer = r.seeker_id then return '{"status":"unavailable"}'::jsonb; end if;   -- self-scan
  if p_push_token is not null and exists (select 1 from public.device_push_tokens
                                           where user_id = r.seeker_id and apns_token = p_push_token) then
    return '{"status":"unavailable"}'::jsonb;                                                                    -- same device
  end if;

  v_leave  := least(to_timestamp(round(extract(epoch from p_leave_at) / 300.0) * 300), v_cap);   -- round to 5 min
  v_secret := internal.rand_b64url(16);                                                          -- 128-bit
  update public.spot_handoffs set
      status = 'armed', armed_at = v_now, leave_at = v_leave,
      expires_at = v_leave + interval '15 minutes',                                              -- HANDOFF_GRACE_MIN
      claimer_anon_id = p_claimer, claimer_secret_hash = internal.sha(v_secret),
      claimer_push_token = p_push_token, claimer_activity_token = p_activity_token,
      claimer_topic = case when p_push_token is not null or p_activity_token is not null then p_topic end,
      claimer_tokens_until = null
    where id = r.id returning * into r;

  perform internal.handoff_push('armed', r.id);
  return jsonb_build_object('status', 'armed', 'id', r.id, 'leave_at', internal.iso(r.leave_at),
                            'expires_at', internal.iso(r.expires_at), 'claimer_secret', v_secret);
end $$;

-- Same ACL posture as 13: service_role only.
revoke all on function public.handoff_claim(text,timestamptz,text,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.handoff_claim(text,timestamptz,text,text,text,uuid,text) to service_role;

-- Verify after applying (Kevin, SQL Editor, read-only, one table):
--   select p.prosrc like '%''id'', r.id%' as returns_id,                      -- t
--          pg_get_function_identity_arguments(p.oid) as args,
--          p.prosecdef as secdef,                                               -- t
--          array_to_string(p.proconfig, ',') as cfg,                            -- search_path=""
--          has_function_privilege('anon', p.oid, 'execute') as anon_x,          -- f
--          has_function_privilege('authenticated', p.oid, 'execute') as authed_x, -- f
--          has_function_privilege('service_role', p.oid, 'execute') as svc_x    -- t
--     from pg_proc p where p.oid = 'public.handoff_claim(text,timestamptz,text,text,text,uuid,text)'::regprocedure;
