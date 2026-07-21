-- PTM Admin local-only compacted Supabase baseline.
-- Source: production public-schema snapshot captured 2026-07-16.
-- Source SHA-256: 04B39BF486C7AFB6380A6845C31A18F1B1BCF74FEFA14910A53B8A7A55B2B97F
-- Supabase CLI used for the snapshot: 2.107.0
-- Deployment commit base: d28246d5a68572f00883650777e411d458869afe
-- Deliberate sanitization: ownership commands removed; required extensions and
-- private dependencies reconstructed from the final local migration contracts.
-- This migration contains schema only and must never be linked or pushed remotely.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";




COMMENT ON SCHEMA "public" IS 'standard public schema';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."app_releases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" "text" NOT NULL,
    "platform" "text" DEFAULT 'win32-x64'::"text" NOT NULL,
    "channel" "text" DEFAULT 'stable'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "release_notes" "text",
    "artifact_uri" "text",
    "artifact_hash" "text",
    "signature" "text",
    "released_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_current" boolean DEFAULT false NOT NULL,
    "mandatory" boolean DEFAULT true NOT NULL,
    "minimum_version" "text",
    "title" "text" NOT NULL,
    "manifest_key" "text",
    "installer_key" "text",
    "blockmap_key" "text",
    "sha512" "text",
    "size_bytes" bigint,
    "created_by" "uuid",
    "approved_by" "uuid",
    "released_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "approved_at" timestamp with time zone,
    "blocked_at" timestamp with time zone,
    "blocked_by" "uuid",
    "block_reason" "text",
    CONSTRAINT "app_releases_minimum_version_semver_check" CHECK ((("minimum_version" IS NULL) OR ("minimum_version" ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::"text"))),
    CONSTRAINT "app_releases_size_bytes_check" CHECK ((("size_bytes" IS NULL) OR ("size_bytes" > 0))),
    CONSTRAINT "app_releases_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'testing'::"text", 'approved'::"text", 'released'::"text", 'blocked'::"text", 'superseded'::"text"]))),
    CONSTRAINT "app_releases_title_not_blank_check" CHECK ((NULLIF("btrim"("title"), ''::"text") IS NOT NULL)),
    CONSTRAINT "app_releases_version_semver_check" CHECK (("version" ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::"text"))
);




CREATE TABLE IF NOT EXISTS "public"."challenge_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "challenge_id" "uuid" NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "session_id" "uuid",
    "status" "text" DEFAULT 'created'::"text" NOT NULL,
    "answer_result" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "pending_at" timestamp with time zone,
    "displayed_at" timestamp with time zone,
    "paused_at" timestamp with time zone,
    "resumed_at" timestamp with time zone,
    "answered_at" timestamp with time zone,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:05:00'::interval) NOT NULL,
    "closed_at" timestamp with time zone,
    "pause_reason" "text",
    "revision" bigint DEFAULT 1 NOT NULL,
    "scheduled_for" timestamp with time zone,
    "answer" "jsonb",
    "abandoned_at" timestamp with time zone,
    "answer_feedback" "jsonb",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "challenge_logs_answer_result_check" CHECK (("answer_result" = ANY (ARRAY['correct'::"text", 'incorrect'::"text"]))),
    CONSTRAINT "challenge_logs_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'pending'::"text", 'displayed'::"text", 'paused'::"text", 'answered'::"text", 'failed'::"text", 'expired'::"text", 'idle'::"text", 'abandoned'::"text"])))
);




COMMENT ON COLUMN "public"."challenge_logs"."metadata" IS 'Server-side challenge lifecycle metadata, including rule-change reschedule audit fields.';



CREATE TABLE IF NOT EXISTS "public"."admin_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "role" "text" DEFAULT 'superadmin'::"text" NOT NULL,
    "unit_scope" "uuid"[] DEFAULT '{}'::"uuid"[],
    "active" boolean DEFAULT true NOT NULL,
    "mfa_required" boolean DEFAULT false NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "admin_users_role_check" CHECK (("role" = ANY (ARRAY['superadmin'::"text", 'unit_manager'::"text", 'operations_manager'::"text", 'content_manager'::"text", 'challenge_manager'::"text", 'release_manager'::"text", 'auditor'::"text", 'support_readonly'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."operator_states" (
    "operator_id" "uuid" NOT NULL,
    "session_id" "uuid",
    "status" "text" DEFAULT 'offline'::"text" NOT NULL,
    "activity" "text",
    "reason_code" "text",
    "effective_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "call_active" boolean DEFAULT false NOT NULL,
    "call_source" "text",
    "call_started_at" timestamp with time zone,
    "call_event_id" "uuid",
    "call_previous_status" "text",
    CONSTRAINT "operator_states_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'idle'::"text", 'in_call'::"text", 'blocked'::"text", 'outside_shift'::"text", 'offline'::"text"])))
);




CREATE OR REPLACE FUNCTION "public"."_app_envelope"("p_request_id" "text", "p_success" boolean, "p_data" "jsonb", "p_error" "jsonb", "p_meta" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object(
    'success', p_success,
    'request_id', p_request_id,
    'server_now', to_char((now() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'contract_version', 1,
    'api_version', 'v1',
    'data', p_data,
    'error', p_error,
    'meta', p_meta
  );
$$;




CREATE OR REPLACE FUNCTION "public"."_app_semver_ge"("a" "text", "b" "text") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  ca text := regexp_replace(split_part(split_part(coalesce(a,'0'),'-',1),'+',1),'[^0-9.]','','g');
  cb text := regexp_replace(split_part(split_part(coalesce(b,'0'),'-',1),'+',1),'[^0-9.]','','g');
  pa text[] := string_to_array(ca,'.');
  pb text[] := string_to_array(cb,'.');
  i int; va int; vb int;
begin
  for i in 1..greatest(coalesce(array_length(pa,1),0),coalesce(array_length(pb,1),0),1) loop
    va := coalesce(nullif(pa[i],'')::int,0);
    vb := coalesce(nullif(pb[i],'')::int,0);
    if va > vb then return true; end if;
    if va < vb then return false; end if;
  end loop;
  return true;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."_app_shift_info"("p_shift" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare s record; v_tz text; v_local timestamp; v_dow int; v_time time;
  v_end_local timestamp; v_end timestamptz; v_in boolean; v_period text; v_display text;
begin
  if p_shift is null then return null; end if;
  select * into s from public.shifts where id = p_shift;
  if not found then return null; end if;
  v_tz := coalesce(nullif(s.timezone,''),'America/Sao_Paulo');
  v_local := (now() at time zone v_tz);
  v_dow := extract(dow from v_local)::int;
  v_time := v_local::time;
  v_end_local := (v_local::date + s.ends_at);
  if s.ends_at <= s.starts_at then v_end_local := v_end_local + interval '1 day'; end if;
  v_end := v_end_local at time zone v_tz;
  if s.days_of_week is not null and v_dow = ANY(s.days_of_week) then
    if s.ends_at >= s.starts_at then
      v_in := (v_time >= s.starts_at and v_time <= s.ends_at);
    else
      v_in := (v_time >= s.starts_at or v_time <= s.ends_at);
    end if;
  else
    v_in := false;
  end if;

  -- period: pelo nome (Diurno/Noturno); senÃ£o deriva do horÃ¡rio de inÃ­cio
  if s.name ilike '%diurno%' then v_period := 'day';
  elsif s.name ilike '%noturno%' then v_period := 'night';
  elsif s.starts_at >= time '05:00' and s.starts_at < time '17:00' then v_period := 'day';
  else v_period := 'night';
  end if;

  -- display_name: nome curto sem o prefixo da escala (12x36 / 6x1)
  v_display := btrim(regexp_replace(s.name, '^\s*(12x36|6x1)\s*', '', 'i'));
  if v_display is null or v_display = '' then
    v_display := case when v_period = 'day' then 'Diurno' else 'Noturno' end;
  end if;

  return jsonb_build_object(
    'id', s.id,
    'name', s.name,
    'display_name', v_display,
    'period', v_period,
    'ends_at', v_end,
    'in_shift', v_in
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."_app_version_check"("p_unit" "uuid", "p_version" "text", "p_platform" "text", "p_channel" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare r record; v_allowed boolean;
begin
  select * into r from public.app_release_rules
   where active = true
     and platform = coalesce(nullif(p_platform,''),'win32-x64')
     and channel  = coalesce(nullif(p_channel,''),'stable')
     and (scope_type='global' or (scope_type='unit' and scope_id = p_unit))
   order by (scope_type='unit') desc, priority desc, updated_at desc
   limit 1;
  if not found then
    return jsonb_build_object('allowed',true,'update_policy','none','minimum_version',null,'latest_version',null);
  end if;
  v_allowed := case
    when r.update_policy='blocked' then false
    when r.update_policy='required' and r.minimum_version is not null and not public._app_semver_ge(p_version, r.minimum_version) then false
    else true end;
  return jsonb_build_object('allowed',v_allowed,'update_policy',r.update_policy,'minimum_version',r.minimum_version,'latest_version',r.latest_version);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."_enforce_secondary_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_count int; c_limit constant int := 2;
begin
  if NEW.type <> 'secondary' then return NEW; end if;
  -- Secundarias criadas por admin (sem operador dono) nao entram nesse limite.
  if NEW.created_by_operator_id is null then return NEW; end if;

  -- Serializa por operador: dois inserts simultaneos nao passam da contagem.
  perform pg_advisory_xact_lock(hashtext('secondary_limit:'||NEW.created_by_operator_id::text));

  select count(*) into v_count from public.playlists
   where created_by_operator_id = NEW.created_by_operator_id
     and type = 'secondary'
     and status <> 'archived'
     and approval_status <> 'rejected';

  if v_count >= c_limit then
    raise exception 'SECONDARY_LIMIT_REACHED' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_acknowledge_playlist_import_error"("p_playlist_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin public.admin_users%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  update public.playlists p
  set import_error_acknowledged_at = now()
  where p.id = p_playlist_id
    and exists (
      select 1
      from public.download_jobs j
      where j.playlist_id = p.id
        and j.status in ('partial', 'error')
    );

  if not found then
    raise exception 'playlist_import_error_not_found';
  end if;
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_analytics_answered_calls"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_answered_calls integer;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_end <= v_start then
    raise exception 'invalid_period';
  end if;

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  with visible_operators as (
    select
      o.id,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join public.units u on u.id = o.unit_id and u.active = true
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or o.unit_id = v_unit)
      and (v_operator is null or o.id = v_operator)
  )
  select count(*)::integer into v_answered_calls
  from public.operator_status_history h
  join visible_operators o on o.id = h.operator_id
  where h.to_status = 'in_call'
    and h.occurred_at >= v_start
    and h.occurred_at < v_end
    and (v_shift = 'all' or o.shift_kind = v_shift);

  return jsonb_build_object('answered_calls', coalesce(v_answered_calls, 0));
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_analytics_dashboard"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_rank_page int := greatest(coalesce(nullif(p_request->>'ranking_page', '')::int, 1), 1);
  v_rank_page_size int := least(greatest(coalesce(nullif(p_request->>'ranking_page_size', '')::int, 50), 1), 50);
  v_rank_offset int;
  v_bucket_interval interval;
  v_bucket_grain text;
  v_payload jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  if v_end <= v_start then
    raise exception 'invalid_period';
  end if;

  v_rank_offset := (v_rank_page - 1) * v_rank_page_size;

  if v_end - v_start <= interval '2 days' then
    v_bucket_interval := interval '1 hour';
    v_bucket_grain := 'hour';
  else
    v_bucket_interval := interval '1 day';
    v_bucket_grain := 'day';
  end if;

  with visible_units as (
    select u.id, u.name, u.city, u.state, u.active
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or u.id = v_unit)
  ),
  operator_base as (
    select
      o.id,
      o.display_name,
      o.unit_id,
      u.name as unit_name,
      s.id as shift_id,
      s.name as shift_name,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join visible_units u on u.id = o.unit_id
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (v_operator is null or o.id = v_operator)
  ),
  visible_operators as (
    select *
    from operator_base
    where v_shift = 'all' or shift_kind = v_shift
  ),
  all_filter_units as (
    select u.id, u.name
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
  ),
  all_filter_operators as (
    select o.id, o.display_name, o.unit_id
    from public.operators o
    join all_filter_units u on u.id = o.unit_id
    where o.active = true
  ),
  raw_sessions as (
    select
      s.id,
      s.operator_id,
      s.unit_id,
      s.shift_id,
      s.status,
      s.started_at,
      coalesce(
        s.ended_at,
        case
          when s.status = 'active' then least(now(), s.expires_at)
          else coalesce(s.updated_at, s.last_heartbeat_at, s.started_at)
        end
      ) as raw_end
    from public.operator_sessions s
    join visible_operators o on o.id = s.operator_id
    where s.started_at < v_end
      and coalesce(
        s.ended_at,
        case
          when s.status = 'active' then least(now(), s.expires_at)
          else coalesce(s.updated_at, s.last_heartbeat_at, s.started_at)
        end
      ) > v_start
  ),
  session_segments as (
    select
      id,
      operator_id,
      unit_id,
      shift_id,
      greatest(started_at, v_start) as seg_start,
      least(raw_end, v_end) as seg_end,
      started_at,
      raw_end
    from raw_sessions
    where raw_end > started_at
  ),
  session_agg as (
    select
      count(*)::int as total_sessions,
      count(distinct operator_id)::int as active_operators,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds
    from session_segments
    where seg_end > seg_start
  ),
  ordered_status as (
    select
      h.operator_id,
      h.session_id,
      h.to_status as status,
      h.occurred_at,
      lead(h.occurred_at) over (partition by h.operator_id order by h.occurred_at, h.id) as next_at
    from public.operator_status_history h
    join visible_operators o on o.id = h.operator_id
    where h.occurred_at < v_end
  ),
  status_segments as (
    select
      operator_id,
      session_id,
      status,
      greatest(occurred_at, v_start) as seg_start,
      least(coalesce(next_at, v_end), v_end) as seg_end
    from ordered_status
    where coalesce(next_at, v_end) > v_start
      and occurred_at < v_end
  ),
  status_duration as (
    select
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'in_call'), 0)::bigint as call_seconds
    from status_segments
    where seg_end > seg_start
  ),
  challenge_scope as (
    select cl.*
    from public.challenge_logs cl
    join visible_operators o on o.id = cl.operator_id
    where cl.created_at >= v_start
      and cl.created_at < v_end
  ),
  challenge_agg as (
    select
      count(*)::int as received,
      count(*) filter (where answered_at is not null or status = 'answered')::int as answered,
      count(*) filter (where answer_result in ('correct', 'success', 'right', 'ok'))::int as correct
    from challenge_scope
  ),
  current_status as (
    select
      coalesce(st.status, 'offline') as status,
      count(*)::int as count
    from visible_operators o
    left join public.operator_states st on st.operator_id = o.id
    group by coalesce(st.status, 'offline')
  ),
  status_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'status', status_name,
        'label', status_label,
        'count', coalesce(cs.count, 0)
      )
      order by sort_order
    ), '[]'::jsonb) as rows
    from (
      values
        ('active', 'Ativo', 1),
        ('in_call', 'Atendimento', 2),
        ('idle', 'Ocioso', 3),
        ('offline', 'Offline', 4)
    ) as expected(status_name, status_label, sort_order)
    left join current_status cs on cs.status = expected.status_name
  ),
  buckets as (
    select
      gs as bucket_start,
      least(gs + v_bucket_interval, v_end) as bucket_end
    from generate_series(date_trunc(v_bucket_grain, v_start), v_end, v_bucket_interval) gs
    where gs < v_end
  ),
  timeseries as (
    select
      b.bucket_start,
      coalesce((
        select count(*)::int
        from raw_sessions s
        where s.started_at >= b.bucket_start
          and s.started_at < b.bucket_end
      ), 0) as sessions,
      coalesce((
        select sum(extract(epoch from (least(s.seg_end, b.bucket_end) - greatest(s.seg_start, b.bucket_start))))::bigint
        from session_segments s
        where s.seg_start < b.bucket_end
          and s.seg_end > b.bucket_start
      ), 0) as online_seconds,
      coalesce((
        select sum(extract(epoch from (least(st.seg_end, b.bucket_end) - greatest(st.seg_start, b.bucket_start))))::bigint
        from status_segments st
        where st.status = 'idle'
          and st.seg_start < b.bucket_end
          and st.seg_end > b.bucket_start
      ), 0) as idle_seconds,
      coalesce((
        select sum(extract(epoch from (least(st.seg_end, b.bucket_end) - greatest(st.seg_start, b.bucket_start))))::bigint
        from status_segments st
        where st.status = 'in_call'
          and st.seg_start < b.bucket_end
          and st.seg_end > b.bucket_start
      ), 0) as call_seconds
    from buckets b
  ),
  unit_sessions as (
    select
      unit_id,
      count(*)::int as sessions,
      count(distinct operator_id)::int as active_operators,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds
    from session_segments
    where seg_end > seg_start
    group by unit_id
  ),
  unit_status as (
    select
      o.unit_id,
      coalesce(sum(extract(epoch from (st.seg_end - st.seg_start))) filter (where st.status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (st.seg_end - st.seg_start))) filter (where st.status = 'in_call'), 0)::bigint as call_seconds
    from status_segments st
    join visible_operators o on o.id = st.operator_id
    where st.seg_end > st.seg_start
    group by o.unit_id
  ),
  unit_challenges as (
    select
      o.unit_id,
      count(*)::int as challenges_received,
      count(*) filter (where cl.answered_at is not null or cl.status = 'answered')::int as challenges_answered,
      count(*) filter (where cl.answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct
    from challenge_scope cl
    join visible_operators o on o.id = cl.operator_id
    group by o.unit_id
  ),
  condominium_rows as (
    select
      u.id as unit_id,
      u.name as unit_name,
      coalesce(us.active_operators, 0) as active_operators,
      coalesce(us.sessions, 0) as sessions,
      coalesce(us.online_seconds, 0) as online_seconds,
      coalesce(ust.idle_seconds, 0) as idle_seconds,
      coalesce(ust.call_seconds, 0) as call_seconds,
      coalesce(uc.challenges_answered, 0) as challenges_answered,
      coalesce(uc.challenges_received, 0) as challenges_received,
      coalesce(uc.challenges_correct, 0) as challenges_correct
    from (
      select distinct unit_id as id, unit_name as name
      from visible_operators
    ) u
    left join unit_sessions us on us.unit_id = u.id
    left join unit_status ust on ust.unit_id = u.id
    left join unit_challenges uc on uc.unit_id = u.id
  ),
  operator_sessions_agg as (
    select
      operator_id,
      count(*)::int as sessions,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds,
      max(raw_end) as last_session_at
    from session_segments
    where seg_end > seg_start
    group by operator_id
  ),
  operator_status_agg as (
    select
      operator_id,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'in_call'), 0)::bigint as call_seconds,
      max(seg_end) as last_status_at
    from status_segments
    where seg_end > seg_start
    group by operator_id
  ),
  operator_challenges as (
    select
      operator_id,
      count(*)::int as challenges_received,
      count(*) filter (where answered_at is not null or status = 'answered')::int as challenges_answered,
      count(*) filter (where answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct
    from challenge_scope
    group by operator_id
  ),
  ranking_all as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_name,
      coalesce(os.sessions, 0) as sessions,
      coalesce(os.online_seconds, 0) as online_seconds,
      coalesce(ost.idle_seconds, 0) as idle_seconds,
      coalesce(ost.call_seconds, 0) as call_seconds,
      coalesce(oc.challenges_received, 0) as challenges_received,
      coalesce(oc.challenges_answered, 0) as challenges_answered,
      coalesce(oc.challenges_correct, 0) as challenges_correct,
      greatest(coalesce(os.last_session_at, '-infinity'::timestamptz), coalesce(ost.last_status_at, '-infinity'::timestamptz)) as last_event_at
    from visible_operators o
    left join operator_sessions_agg os on os.operator_id = o.id
    left join operator_status_agg ost on ost.operator_id = o.id
    left join operator_challenges oc on oc.operator_id = o.id
  ),
  ranking_count as (
    select count(*)::int as total from ranking_all
  ),
  ranking_page as (
    select *
    from ranking_all
    order by online_seconds desc, sessions desc, operator_name
    limit v_rank_page_size offset v_rank_offset
  ),
  music_source as (
    select
      false as available,
      'Nao existe log real de reproducao/interacao musical no schema atual; playlist_tracks representa biblioteca/importacao, nao playback.'::text as reason
  )
  select jsonb_build_object(
    'filters', jsonb_build_object(
      'start_at', v_start,
      'end_at', v_end,
      'unit_id', v_unit,
      'operator_id', v_operator,
      'shift', v_shift,
      'ranking_page', v_rank_page,
      'ranking_page_size', v_rank_page_size
    ),
    'filter_options', jsonb_build_object(
      'units', coalesce((
        select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
        from all_filter_units
      ), '[]'::jsonb),
      'operators', coalesce((
        select jsonb_agg(jsonb_build_object('id', id, 'display_name', display_name, 'unit_id', unit_id) order by display_name)
        from all_filter_operators
      ), '[]'::jsonb),
      'shifts', coalesce((
        select jsonb_agg(distinct jsonb_build_object('value', shift_kind, 'label',
          case shift_kind when 'day' then 'Diurno' when 'night' then 'Noturno' else 'Outro' end
        ))
        from operator_base
      ), '[]'::jsonb)
    ),
    'metrics', jsonb_build_object(
      'active_operators', coalesce((select active_operators from session_agg), 0),
      'total_sessions', coalesce((select total_sessions from session_agg), 0),
      'online_seconds', coalesce((select online_seconds from session_agg), 0),
      'idle_seconds', coalesce((select idle_seconds from status_duration), 0),
      'call_seconds', coalesce((select call_seconds from status_duration), 0),
      'challenge_response_rate', case
        when coalesce((select received from challenge_agg), 0) = 0 then null
        else round(((select answered from challenge_agg)::numeric / nullif((select received from challenge_agg), 0)) * 100, 1)
      end,
      'challenge_accuracy_rate', case
        when coalesce((select answered from challenge_agg), 0) = 0 then null
        else round(((select correct from challenge_agg)::numeric / nullif((select answered from challenge_agg), 0)) * 100, 1)
      end,
      'challenges_received', coalesce((select received from challenge_agg), 0),
      'challenges_answered', coalesce((select answered from challenge_agg), 0),
      'music_interactions', null,
      'music_interactions_available', (select available from music_source),
      'music_interactions_unavailable_reason', (select reason from music_source)
    ),
    'timeseries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bucket_start', bucket_start,
        'sessions', sessions,
        'online_seconds', online_seconds,
        'idle_seconds', idle_seconds,
        'call_seconds', call_seconds
      ) order by bucket_start)
      from timeseries
    ), '[]'::jsonb),
    'condominiums', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_id', unit_id,
        'unit_name', unit_name,
        'active_operators', active_operators,
        'sessions', sessions,
        'online_seconds', online_seconds,
        'idle_seconds', idle_seconds,
        'call_seconds', call_seconds,
        'challenges_answered', challenges_answered,
        'challenges_received', challenges_received,
        'challenge_accuracy_rate', case when challenges_answered = 0 then null else round((challenges_correct::numeric / challenges_answered) * 100, 1) end
      ) order by unit_name)
      from condominium_rows
    ), '[]'::jsonb),
    'ranking', jsonb_build_object(
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'operator_id', operator_id,
          'operator_name', operator_name,
          'unit_name', unit_name,
          'sessions', sessions,
          'online_seconds', online_seconds,
          'idle_seconds', idle_seconds,
          'call_seconds', call_seconds,
          'challenges_received', challenges_received,
          'challenges_answered', challenges_answered,
          'challenge_response_rate', case when challenges_received = 0 then null else round((challenges_answered::numeric / challenges_received) * 100, 1) end,
          'challenge_accuracy_rate', case when challenges_answered = 0 then null else round((challenges_correct::numeric / challenges_answered) * 100, 1) end,
          'last_event_at', nullif(last_event_at, '-infinity'::timestamptz)
        ) order by online_seconds desc, sessions desc, operator_name)
        from ranking_page
      ), '[]'::jsonb),
      'total', (select total from ranking_count),
      'page', v_rank_page,
      'page_size', v_rank_page_size
    ),
    'status_breakdown', (select rows from status_json),
    'sources', jsonb_build_array(
      jsonb_build_object('key', 'sessions', 'label', 'Sessoes', 'available', true, 'tables', jsonb_build_array('operator_sessions')),
      jsonb_build_object('key', 'status_durations', 'label', 'Tempo por status', 'available', true, 'tables', jsonb_build_array('operator_status_history', 'operator_states')),
      jsonb_build_object('key', 'challenges', 'label', 'Desafios', 'available', true, 'tables', jsonb_build_array('challenge_logs', 'challenges')),
      jsonb_build_object('key', 'music_playback', 'label', 'Reproducao musical', 'available', false, 'tables', jsonb_build_array(), 'reason', (select reason from music_source))
    )
  )
  into v_payload;

  return v_payload;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_archive_secondary_playlist"("p_playlist" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_before public.playlists%rowtype;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.type <> 'secondary' then
    raise exception 'cannot_archive_principal';
  end if;

  if v_playlist.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  v_before := v_playlist;

  update public.playlists
  set status = 'archived',
      updated_at = now(),
      revision = revision + 1
  where id = p_playlist
  returning * into v_playlist;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  )
  values (
    v_admin.id,
    'music_secondary_playlist_archived',
    'playlist',
    p_playlist,
    jsonb_build_object('status', v_before.status),
    jsonb_build_object('status', v_playlist.status),
    now()
  );

  return jsonb_build_object('ok', true, 'playlist_id', v_playlist.id, 'status', v_playlist.status);
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_can_manage_operator_unit"("p_unit" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from public.admin_users a
    where a.auth_user_id = auth.uid() and a.active and (
      a.role = 'superadmin'
      or (a.role in ('unit_manager','operations_manager') and p_unit = any(a.unit_scope))
    )
  );
$$;




CREATE OR REPLACE FUNCTION "public"."admin_challenge_leaderboard"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_limit int := least(greatest(coalesce(nullif(p_request->>'ranking_page_size', '')::int, 5), 1), 50);
  v_reset timestamptz;
  v_payload jsonb;
begin
  perform private.require_admin_for_backend(null, v_unit);

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  v_reset := private.statistics_reset_at();
  if v_reset is not null and v_reset > v_start then
    v_start := v_reset;
  end if;

  if v_end <= v_start then
    return jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'page', 1, 'page_size', v_limit);
  end if;

  with visible_units as (
    select u.id, u.name, u.city, u.state, u.code
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or u.id = v_unit)
  ),
  visible_operators as (
    select
      o.id,
      o.display_name,
      o.unit_id,
      u.name as unit_name,
      u.city as unit_city,
      u.state as unit_state,
      u.code as unit_code,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join visible_units u on u.id = o.unit_id
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (v_operator is null or o.id = v_operator)
  ),
  challenge_agg as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_id,
      o.unit_name,
      o.unit_city,
      o.unit_state,
      o.unit_code,
      count(cl.id)::int as challenges_received,
      count(cl.id) filter (where cl.answered_at is not null)::int as challenges_answered,
      count(cl.id) filter (where cl.answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct,
      max(coalesce(cl.answered_at, cl.displayed_at, cl.created_at)) as last_challenge_at
    from visible_operators o
    join public.challenge_logs cl
      on cl.operator_id = o.id
     and cl.created_at >= v_start
     and cl.created_at <= v_end
    where (v_shift = 'all' or o.shift_kind = v_shift)
    group by o.id, o.display_name, o.unit_id, o.unit_name, o.unit_city, o.unit_state, o.unit_code
  ),
  eligible as (
    select *,
      round((challenges_correct::numeric / nullif(challenges_answered, 0)) * 100, 1) as challenge_accuracy_rate
    from challenge_agg
    where challenges_answered > 0
  ),
  page_rows as (
    select *
    from eligible
    order by challenge_accuracy_rate desc, challenges_answered desc, challenges_correct desc, operator_name
    limit v_limit
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'challenges_received', challenges_received,
        'challenges_answered', challenges_answered,
        'challenges_correct', challenges_correct,
        'challenge_accuracy_rate', challenge_accuracy_rate,
        'last_challenge_at', last_challenge_at
      ) order by challenge_accuracy_rate desc, challenges_answered desc, challenges_correct desc, operator_name)
      from page_rows
    ), '[]'::jsonb),
    'total', (select count(*) from eligible),
    'page', 1,
    'page_size', v_limit
  ) into v_payload;

  return v_payload;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_correct_operator_registered_name"("p_operator" "uuid", "p_registered_name" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_registered_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_reason text := btrim(regexp_replace(coalesce(p_reason, ''), '[[:space:]]+', ' ', 'g'));
  v_now timestamptz := clock_timestamp();
begin
  select * into v_operator
  from public.operators
  where id = p_operator
  for update;

  if v_operator.id is null then raise exception 'operator_not_found'; end if;
  v_admin := private.require_admin_for_backend(array['superadmin'], v_operator.unit_id);

  if v_registered_name is null or char_length(v_registered_name) < 3 or char_length(v_registered_name) > 120 then
    raise exception 'registered_name_length_invalid';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then
    raise exception 'registered_name_correction_reason_invalid';
  end if;

  if v_registered_name = v_operator.registered_name then
    return jsonb_build_object(
      'success', true,
      'server_now', v_now,
      'data', jsonb_build_object('registered_name', v_operator.registered_name, 'changed', false),
      'error', null
    );
  end if;

  perform set_config('app.audit_source', 'admin_explicit', true);
  update public.operators
  set registered_name = v_registered_name,
      updated_at = v_now
  where id = v_operator.id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    v_admin.id,
    'operator_registered_name_corrected',
    'operator',
    v_operator.id,
    jsonb_build_object('registered_name', v_operator.registered_name),
    jsonb_build_object('registered_name', v_registered_name),
    v_reason,
    v_now
  );

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object('registered_name', v_registered_name, 'changed', true),
    'error', null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_create_operator"("p_auth_user_id" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean DEFAULT true) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if p_auth_user_id is null then raise exception 'auth_user_required'; end if;
  if v_registered_name is null then raise exception 'display_name_required'; end if;
  if v_username is null then raise exception 'username_required'; end if;
  if v_username !~ '^[a-z0-9._-]{3,60}$' then raise exception 'username_invalid'; end if;
  if p_role not in ('operador', 'supervisor') then raise exception 'operator_role_invalid'; end if;
  if p_session_policy not in ('single', 'multi') then raise exception 'session_policy_invalid'; end if;
  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  perform set_config('app.audit_source', 'admin_explicit', true);
  insert into public.operators (
    auth_user_id, registered_name, display_name, username, unit_id, role, session_policy, active
  ) values (
    p_auth_user_id, v_registered_name, v_registered_name, v_username, p_unit_id,
    p_role, p_session_policy, coalesce(p_active, true)
  ) returning * into v_operator;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at, reason
  ) values (
    v_admin.id,
    'operator_created',
    'operator',
    v_operator.id,
    jsonb_build_object(
      'registered_name', v_operator.registered_name,
      'display_name', v_operator.display_name,
      'username', v_operator.username,
      'unit_id', v_operator.unit_id,
      'role', v_operator.role,
      'session_policy', v_operator.session_policy,
      'active', v_operator.active,
      'auth_user_id', v_operator.auth_user_id
    ),
    clock_timestamp(),
    'admin_profile'
  );

  return v_operator.id;
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_create_unit"("p_code" "text", "p_name" "text", "p_address" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_timezone" "text" DEFAULT 'America/Sao_Paulo'::"text", "p_active" boolean DEFAULT true) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_unit public.units%rowtype;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_timezone text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'America/Sao_Paulo');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    null
  );

  if v_code is null then
    raise exception 'unit_code_required';
  end if;

  if v_name is null then
    raise exception 'unit_name_required';
  end if;

  insert into public.units (
    code, name, address, city, state, timezone, active
  ) values (
    v_code,
    v_name,
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(upper(btrim(coalesce(p_state, ''))), ''),
    v_timezone,
    coalesce(p_active, true)
  )
  returning * into v_unit;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'unit_created',
    'unit',
    v_unit.id,
    jsonb_build_object(
      'code', v_unit.code,
      'name', v_unit.name,
      'address', v_unit.address,
      'city', v_unit.city,
      'state', v_unit.state,
      'timezone', v_unit.timezone,
      'active', v_unit.active
    ),
    now()
  );

  return v_unit.id;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_dismiss_skipped_track"("p_playlist_id" "uuid", "p_youtube_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist_details jsonb;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  if nullif(btrim(coalesce(p_youtube_id, '')), '') is null then
    raise exception 'youtube_id_required';
  end if;

  select error_details into v_playlist_details
  from public.playlists
  where id = p_playlist_id
  for update;

  if v_playlist_details is not null and jsonb_typeof(v_playlist_details->'skipped') = 'array' then
    with filtered as (
      select coalesce(jsonb_agg(elem), '[]'::jsonb) as skipped
      from jsonb_array_elements(v_playlist_details->'skipped') elem
      where elem->>'youtube_id' is distinct from p_youtube_id
    )
    select case
      when jsonb_array_length(skipped) = 0 then null
      when v_playlist_details ? 'summary' then
        jsonb_set(
          jsonb_set(v_playlist_details, '{skipped}', skipped),
          '{summary,failed}',
          to_jsonb(jsonb_array_length(skipped))
        )
      else jsonb_set(v_playlist_details, '{skipped}', skipped)
    end
    into v_playlist_details
    from filtered;

    update public.playlists
    set error_details = v_playlist_details
    where id = p_playlist_id;
  end if;

  with candidates as (
    select id, error_details
    from public.download_jobs
    where playlist_id = p_playlist_id
      and error_details is not null
      and jsonb_typeof(error_details->'skipped') = 'array'
    for update
  ), filtered as (
    select
      c.id,
      c.error_details,
      (
        select coalesce(jsonb_agg(item), '[]'::jsonb)
        from jsonb_array_elements(c.error_details->'skipped') item
        where item->>'youtube_id' is distinct from p_youtube_id
      ) as skipped
    from candidates c
  )
  update public.download_jobs job
  set error_details = case
    when jsonb_array_length(filtered.skipped) = 0 then null
    when filtered.error_details ? 'summary' then
      jsonb_set(
        jsonb_set(filtered.error_details, '{skipped}', filtered.skipped),
        '{summary,failed}',
        to_jsonb(jsonb_array_length(filtered.skipped))
      )
    else jsonb_set(filtered.error_details, '{skipped}', filtered.skipped)
  end
  from filtered
  where job.id = filtered.id;
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_enqueue_track_replacement"("p_playlist_id" "uuid", "p_source_url" "text", "p_replace_youtube_id" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_job uuid;
  v_url text := btrim(coalesce(p_source_url, ''));
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  if v_url = '' or (v_url !~* 'youtube\.com' and v_url !~* 'youtu\.be') then
    raise exception 'invalid_url';
  end if;

  if not exists (select 1 from public.playlists where id = p_playlist_id) then
    raise exception 'playlist_not_found';
  end if;

  insert into public.download_jobs (playlist_id, source_url, status, mode, replace_youtube_id)
  values (p_playlist_id, v_url, 'queued', 'single_track', nullif(btrim(coalesce(p_replace_youtube_id, '')), ''))
  returning id into v_job;

  return v_job;
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_grant_app_access"("p_admin_user" "uuid", "p_username" "text", "p_unit_id" "uuid", "p_role" "text" DEFAULT 'operador'::"text", "p_session_policy" "text" DEFAULT 'single'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select * into v_target
  from public.admin_users
  where id = p_admin_user;

  if v_target.id is null then
    raise exception 'admin_user_not_found';
  end if;

  if v_target.auth_user_id is null then
    raise exception 'admin_has_no_login';
  end if;

  if exists (select 1 from public.operators where auth_user_id = v_target.auth_user_id) then
    raise exception 'already_has_app_access';
  end if;

  if v_username is null then
    raise exception 'username_required';
  end if;

  if v_username !~ '^[a-z0-9._-]{3,60}$' then
    raise exception 'username_invalid';
  end if;

  if exists (select 1 from public.operators where username = v_username) then
    raise exception 'username_taken';
  end if;

  if p_role not in ('operador', 'supervisor') then
    raise exception 'operator_role_invalid';
  end if;

  if p_session_policy not in ('single', 'multi') then
    raise exception 'session_policy_invalid';
  end if;

  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  insert into public.operators (
    auth_user_id, display_name, username, unit_id, role, session_policy, active
  ) values (
    v_target.auth_user_id, v_target.display_name, v_username, p_unit_id, p_role, p_session_policy, true
  )
  returning * into v_operator;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'app_access_granted',
    'operator',
    v_operator.id,
    jsonb_build_object(
      'from_admin_user', p_admin_user,
      'auth_user_id', v_target.auth_user_id,
      'username', v_username,
      'unit_id', p_unit_id,
      'role', p_role
    ),
    now()
  );

  return v_operator.id;
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_grant_panel_access"("p_operator" "uuid", "p_mfa_required" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_existing public.admin_users%rowtype;
  v_result_id uuid;
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select * into v_operator
  from public.operators
  where id = p_operator;

  if v_operator.id is null then
    raise exception 'operator_not_found';
  end if;

  if v_operator.auth_user_id is null then
    raise exception 'operator_has_no_login';
  end if;

  -- JÃ¡ existe acesso ao painel para este login? Reativa como superadmin.
  select * into v_existing
  from public.admin_users
  where auth_user_id = v_operator.auth_user_id
  for update;

  if v_existing.id is not null then
    update public.admin_users
    set active = true,
        role = 'superadmin',
        mfa_required = coalesce(p_mfa_required, v_existing.mfa_required),
        updated_at = now()
    where id = v_existing.id;
    v_result_id := v_existing.id;
  else
    insert into public.admin_users (auth_user_id, display_name, role, active, mfa_required)
    values (v_operator.auth_user_id, v_operator.display_name, 'superadmin', true, coalesce(p_mfa_required, false))
    returning id into v_result_id;
  end if;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'panel_access_granted',
    'admin_user',
    v_result_id,
    jsonb_build_object(
      'from_operator', p_operator,
      'auth_user_id', v_operator.auth_user_id,
      'display_name', v_operator.display_name
    ),
    now()
  );

  return v_result_id;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_integration_status"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return jsonb_build_object(
    'database_connected', true,
    'imports', jsonb_build_object(
      'queued', (select count(*) from public.download_jobs where status = 'queued'),
      'running', (select count(*) from public.download_jobs where status = 'running'),
      'completed', (select count(*) from public.download_jobs where status = 'done'),
      'with_errors', (
        with latest_error_job as (
          select distinct on (j.playlist_id)
            j.playlist_id,
            coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
          from public.download_jobs j
          where j.status in ('partial', 'error')
          order by j.playlist_id, coalesce(j.last_error_at, j.updated_at, j.created_at) desc
        )
        select count(*)
        from latest_error_job j
        join public.playlists p on p.id = j.playlist_id
        where p.import_error_acknowledged_at is null
           or j.error_at > p.import_error_acknowledged_at
      ),
      'last_activity_at', (select max(updated_at) from public.download_jobs)
    ),
    'storage_cleanup', jsonb_build_object(
      'queued', (select count(*) from public.storage_deletion_jobs where status = 'queued'),
      'running', (select count(*) from public.storage_deletion_jobs where status = 'running'),
      'with_errors', (select count(*) from public.storage_deletion_jobs where status = 'error'),
      'last_activity_at', (select max(updated_at) from public.storage_deletion_jobs)
    )
  );
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_list_operator_display_name_requests"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_page integer := greatest(coalesce(nullif(p_request->>'page', '')::integer, 1), 1);
  v_page_size integer := least(greatest(coalesce(nullif(p_request->>'page_size', '')::integer, 25), 1), 100);
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_search text := nullif(btrim(coalesce(p_request->>'search', '')), '');
  v_result text := nullif(p_request->>'result', '');
  v_start timestamptz := nullif(p_request->>'start_at', '')::timestamptz;
  v_end timestamptz := nullif(p_request->>'end_at', '')::timestamptz;
  v_total bigint;
  v_rows jsonb;
begin
  perform private.require_admin_for_backend(null, v_unit);

  with scoped as (
    select r.id
    from public.operator_display_name_requests r
    join public.operators o on o.id = r.operator_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(r.unit_id))
      and (v_unit is null or r.unit_id = v_unit)
      and (v_operator is null or r.operator_id = v_operator)
      and (v_start is null or r.occurred_at >= v_start)
      and (v_end is null or r.occurred_at < v_end)
      and (
        v_result is null
        or (v_result = 'allowed' and r.moderation_result = 'allowed')
        or (v_result = 'blocked' and r.moderation_result = 'blocked' and r.review_status = 'pending')
        or (v_result = 'approved' and r.review_status = 'approved')
        or (v_result = 'rejected' and r.review_status = 'rejected')
        or (v_result = 'rate_limited' and r.moderation_result = 'rate_limited')
      )
      and (
        v_search is null
        or o.registered_name ilike '%' || v_search || '%'
        or o.display_name ilike '%' || v_search || '%'
        or r.requested_name ilike '%' || v_search || '%'
      )
  )
  select count(*) into v_total from scoped;

  select coalesce(jsonb_agg(row_data order by occurred_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      r.occurred_at,
      jsonb_build_object(
        'id', r.id,
        'operator_id', r.operator_id,
        'operator_name', o.registered_name,
        'current_display_name', o.display_name,
        'unit_id', r.unit_id,
        'unit_name', u.name,
        'unit_city', u.city,
        'unit_state', u.state,
        'unit_code', u.code,
        'previous_name', r.previous_name,
        'requested_name', r.requested_name,
        'applied_name', r.applied_name,
        'moderation_result', r.moderation_result,
        'moderation_reason', r.moderation_reason,
        'review_status', r.review_status,
        'review_reason', r.review_reason,
        'reviewed_at', r.reviewed_at,
        'reviewed_by', reviewer.display_name,
        'source', r.source,
        'occurred_at', r.occurred_at,
        'applied_at', r.applied_at
      ) as row_data
    from public.operator_display_name_requests r
    join public.operators o on o.id = r.operator_id
    join public.units u on u.id = r.unit_id
    left join public.admin_users reviewer on reviewer.id = r.reviewed_by_admin_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(r.unit_id))
      and (v_unit is null or r.unit_id = v_unit)
      and (v_operator is null or r.operator_id = v_operator)
      and (v_start is null or r.occurred_at >= v_start)
      and (v_end is null or r.occurred_at < v_end)
      and (
        v_result is null
        or (v_result = 'allowed' and r.moderation_result = 'allowed')
        or (v_result = 'blocked' and r.moderation_result = 'blocked' and r.review_status = 'pending')
        or (v_result = 'approved' and r.review_status = 'approved')
        or (v_result = 'rejected' and r.review_status = 'rejected')
        or (v_result = 'rate_limited' and r.moderation_result = 'rate_limited')
      )
      and (
        v_search is null
        or o.registered_name ilike '%' || v_search || '%'
        or o.display_name ilike '%' || v_search || '%'
        or r.requested_name ilike '%' || v_search || '%'
      )
    order by r.occurred_at desc
    limit v_page_size
    offset (v_page - 1) * v_page_size
  ) page_rows;

  return jsonb_build_object(
    'rows', v_rows,
    'total', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_list_operator_display_name_terms"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_page integer := greatest(coalesce(nullif(p_request->>'page', '')::integer, 1), 1);
  v_page_size integer := least(greatest(coalesce(nullif(p_request->>'page_size', '')::integer, 25), 1), 100);
  v_search text := nullif(btrim(coalesce(p_request->>'search', '')), '');
  v_active text := coalesce(nullif(p_request->>'active', ''), 'all');
  v_total bigint;
  v_rows jsonb;
begin
  perform private.require_admin_for_backend(array['superadmin'], null);

  select count(*) into v_total
  from public.operator_display_name_moderation_terms t
  where (v_active = 'all' or (v_active = 'active' and t.active) or (v_active = 'inactive' and not t.active))
    and (v_search is null or t.term ilike '%' || v_search || '%' or t.reason ilike '%' || v_search || '%');

  select coalesce(jsonb_agg(row_data order by updated_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      t.updated_at,
      jsonb_build_object(
        'id', t.id,
        'term', t.term,
        'match_type', t.match_type,
        'active', t.active,
        'reason', t.reason,
        'created_at', t.created_at,
        'updated_at', t.updated_at,
        'created_by', creator.display_name,
        'updated_by', updater.display_name
      ) as row_data
    from public.operator_display_name_moderation_terms t
    left join public.admin_users creator on creator.id = t.created_by_admin_id
    left join public.admin_users updater on updater.id = t.updated_by_admin_id
    where (v_active = 'all' or (v_active = 'active' and t.active) or (v_active = 'inactive' and not t.active))
      and (v_search is null or t.term ilike '%' || v_search || '%' or t.reason ilike '%' || v_search || '%')
    order by t.updated_at desc
    limit v_page_size
    offset (v_page - 1) * v_page_size
  ) page_rows;

  return jsonb_build_object('rows', v_rows, 'total', v_total, 'page', v_page, 'page_size', v_page_size);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_list_orphaned_music_tracks"("p_limit" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "title" "text", "artist" "text", "storage_object_key" "text", "size_bytes" bigint, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return query
  select
    t.id,
    t.title,
    t.artist,
    t.storage_object_key,
    case
      when coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
        then (t.metadata->>'size_bytes')::bigint
      else null
    end,
    t.created_at
  from public.tracks t
  where t.status = 'available'
    and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
  order by t.created_at asc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_list_pending_import_errors"("p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return (
    with latest_error_job as (
      select distinct on (j.playlist_id)
        j.playlist_id,
        j.error,
        j.error_code,
        j.error_message,
        j.error_details,
        coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
      from public.download_jobs j
      where j.status in ('partial', 'error')
      order by j.playlist_id, coalesce(j.last_error_at, j.updated_at, j.created_at) desc
    ), pending_errors as (
      select
        j.*,
        p.name as playlist_name,
        p.type as playlist_type,
        p.approval_status,
        p.source_url,
        o.display_name as operator_name,
        u.name as unit_name
      from latest_error_job j
      join public.playlists p on p.id = j.playlist_id
      left join public.operators o on o.id = p.created_by_operator_id
      left join public.units u on u.id = p.unit_id
      where p.import_error_acknowledged_at is null
         or j.error_at > p.import_error_acknowledged_at
      order by j.error_at desc
      limit v_limit
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'playlist_id', playlist_id,
      'playlist_name', playlist_name,
      'playlist_type', playlist_type,
      'approval_status', approval_status,
      'source_url', source_url,
      'operator_name', operator_name,
      'unit_name', unit_name,
      'error_code', error_code,
      'error_message', coalesce(error_message, error),
      'error_details', error_details,
      'last_error_at', error_at
    )), '[]'::jsonb)
    from pending_errors
  );
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_music_library"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_rows jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select coalesce(jsonb_agg(operator_row order by operator_row->>'display_name'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'display_name', o.display_name,
      'username', o.username,
      'email', au.email,
      'active', o.active,
      'role', o.role,
      'unit_id', o.unit_id,
      'unit_name', u.name,
      'unit_city', u.city,
      'unit_state', u.state,
      'updated_at', o.updated_at,
      'playlists', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'name', p.name,
            'type', p.type,
            'status', p.status,
            'approval_status', p.approval_status,
            'import_status', p.import_status,
            'source_url', p.source_url,
            'platform', public.playlist_source_platform(p.source_url),
            'revision', p.revision,
            'created_at', p.created_at,
            'updated_at', p.updated_at,
            'submitted_at', p.submitted_at,
            'reviewed_at', p.reviewed_at,
            'import_started_at', p.import_started_at,
            'import_finished_at', p.import_finished_at,
            'error_code', p.error_code,
            'error_message', p.error_message,
            'last_error_at', p.last_error_at,
            'track_count', coalesce((
              select count(*)
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), 0),
            'latest_job', (
              select to_jsonb(dj) - 'error_details'
              from public.download_jobs dj
              where dj.playlist_id = p.id
              order by dj.created_at desc
              limit 1
            ),
            'tracks', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'playlist_track_id', pt.id,
                  'track_id', t.id,
                  'position', pt.position,
                  'title', t.title,
                  'artist', t.artist,
                  'duration_ms', t.duration_ms,
                  'source_url', t.metadata->>'source_url',
                  'public_url', t.metadata->>'public_url',
                  'status', t.status,
                  'added_by_type', pt.added_by_type,
                  'created_at', pt.created_at,
                  'updated_at', pt.updated_at
                )
                order by pt.position, pt.created_at
              )
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), '[]'::jsonb)
          )
          order by case p.type when 'principal' then 0 else 1 end, p.created_at
        )
        from public.playlists p
        where p.created_by_operator_id = o.id
          and p.status <> 'archived'
      ), '[]'::jsonb),
      'request_history', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p2.id,
            'name', p2.name,
            'type', p2.type,
            'approval_status', p2.approval_status,
            'import_status', p2.import_status,
            'source_url', p2.source_url,
            'submitted_at', p2.submitted_at,
            'reviewed_at', p2.reviewed_at,
            'rejection_reason', p2.rejection_reason,
            'error_message', p2.error_message
          )
          order by coalesce(p2.submitted_at, p2.created_at) desc
        )
        from public.playlists p2
        where p2.created_by_operator_id = o.id
      ), '[]'::jsonb)
    ) as operator_row
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where public.is_superadmin()
       or public.admin_can_manage_operator_unit(o.unit_id)
  ) q;

  return v_rows;
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_music_library_page"("p_limit" integer DEFAULT 12, "p_offset" integer DEFAULT 0, "p_search" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_rows jsonb := '[]'::jsonb;
begin
  v_payload := public.admin_music_library_page_impl(p_limit, p_offset, p_search);

  select coalesce(jsonb_agg(
    operator_row || jsonb_build_object(
      'request_history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'playlist_id', r.playlist_id,
          'name', p.name,
          'type', p.type,
          'approval_status', r.status,
          'import_status', case latest_job.status
            when 'queued' then 'processing'
            when 'running' then 'processing'
            when 'done' then 'success'
            when 'partial' then 'failed'
            when 'error' then 'failed'
            else case when snapshot.track_count > 0 then 'success' else 'not_started' end
          end,
          'source_url', r.source_url,
          'submitted_at', r.created_at,
          'reviewed_at', r.decided_at,
          'rejection_reason', r.rejection_reason,
          'error_message', coalesce(latest_job.error_message, latest_job.error),
          'track_count', snapshot.track_count,
          'latest_job', latest_job.job,
          'tracks', snapshot.tracks
        ) order by r.created_at desc, r.id desc)
        from public.playlist_requests r
        join public.playlists p on p.id = r.playlist_id
        left join lateral (
          select
            count(*)::integer as track_count,
            coalesce(jsonb_agg(jsonb_build_object(
              'playlist_track_id', prt.id,
              'track_id', t.id,
              'position', prt.position,
              'title', t.title,
              'artist', t.artist,
              'duration_ms', t.duration_ms,
              'source_url', t.metadata->>'source_url',
              'public_url', t.metadata->>'public_url',
              'status', t.status,
              'added_by_type', 'snapshot',
              'created_at', prt.captured_at,
              'updated_at', t.updated_at
            ) order by prt.position, prt.captured_at), '[]'::jsonb) as tracks
          from public.playlist_request_tracks prt
          join public.tracks t on t.id = prt.track_id
          where prt.playlist_request_id = r.id
            and t.status in ('available', 'processing')
        ) snapshot on true
        left join lateral (
          select
            j.status, j.error, j.error_message,
            to_jsonb(j) - 'error_details' as job
          from public.download_jobs j
          where j.playlist_request_id = r.id
          order by j.created_at desc
          limit 1
        ) latest_job on true
        where r.operator_id = (operator_row->>'id')::uuid
        limit 50
      ), '[]'::jsonb)
    )
    order by operator_row->>'display_name'
  ), '[]'::jsonb)
  into v_rows
  from jsonb_array_elements(coalesce(v_payload->'rows', '[]'::jsonb)) operator_row;

  return jsonb_set(v_payload, '{rows}', v_rows, true);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_music_library_page_impl"("p_limit" integer DEFAULT 12, "p_offset" integer DEFAULT 0, "p_search" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 12), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_total bigint := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  with visible_operators as (
    select o.id
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(o.unit_id))
      and (
        v_search is null
        or o.display_name ilike '%' || v_search || '%'
        or o.username ilike '%' || v_search || '%'
        or au.email ilike '%' || v_search || '%'
        or u.name ilike '%' || v_search || '%'
        or u.city ilike '%' || v_search || '%'
        or exists (
          select 1
          from public.playlists px
          where px.created_by_operator_id = o.id
            and (px.name ilike '%' || v_search || '%' or px.source_url ilike '%' || v_search || '%')
        )
      )
  )
  select count(*) into v_total
  from visible_operators;

  with visible_operators as (
    select o.*, u.name as unit_name, u.city as unit_city, u.state as unit_state, au.email
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(o.unit_id))
      and (
        v_search is null
        or o.display_name ilike '%' || v_search || '%'
        or o.username ilike '%' || v_search || '%'
        or au.email ilike '%' || v_search || '%'
        or u.name ilike '%' || v_search || '%'
        or u.city ilike '%' || v_search || '%'
        or exists (
          select 1
          from public.playlists px
          where px.created_by_operator_id = o.id
            and (px.name ilike '%' || v_search || '%' or px.source_url ilike '%' || v_search || '%')
        )
      )
    order by o.display_name
    limit v_limit
    offset v_offset
  )
  select coalesce(jsonb_agg(operator_row order by operator_row->>'display_name'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'display_name', o.display_name,
      'username', o.username,
      'email', o.email,
      'active', o.active,
      'role', o.role,
      'unit_id', o.unit_id,
      'unit_name', o.unit_name,
      'unit_city', o.unit_city,
      'unit_state', o.unit_state,
      'updated_at', o.updated_at,
      'playlists', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'name', p.name,
            'type', p.type,
            'status', p.status,
            'approval_status', p.approval_status,
            'import_status', p.import_status,
            'source_url', p.source_url,
            'platform', public.playlist_source_platform(p.source_url),
            'revision', p.revision,
            'created_at', p.created_at,
            'updated_at', p.updated_at,
            'submitted_at', p.submitted_at,
            'reviewed_at', p.reviewed_at,
            'import_started_at', p.import_started_at,
            'import_finished_at', p.import_finished_at,
            'error_code', p.error_code,
            'error_message', p.error_message,
            'last_error_at', p.last_error_at,
            'track_count', coalesce((
              select count(*)
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), 0),
            'latest_job', (
              select to_jsonb(dj) - 'error_details'
              from public.download_jobs dj
              where dj.playlist_id = p.id
              order by dj.created_at desc
              limit 1
            ),
            'tracks', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'playlist_track_id', tr.id,
                  'track_id', tr.track_id,
                  'position', tr.position,
                  'title', tr.title,
                  'artist', tr.artist,
                  'duration_ms', tr.duration_ms,
                  'source_url', tr.metadata->>'source_url',
                  'public_url', tr.metadata->>'public_url',
                  'status', tr.status,
                  'added_by_type', tr.added_by_type,
                  'created_at', tr.created_at,
                  'updated_at', tr.updated_at
                )
                order by tr.position, tr.created_at
              )
              from (
                select
                  pt.id,
                  pt.track_id,
                  pt.position,
                  pt.added_by_type,
                  pt.created_at,
                  pt.updated_at,
                  t.title,
                  t.artist,
                  t.duration_ms,
                  t.metadata,
                  t.status
                from public.playlist_tracks pt
                join public.tracks t on t.id = pt.track_id
                where pt.playlist_id = p.id
                  and t.status in ('available','processing')
                order by pt.position, pt.created_at
                limit 100
              ) tr
            ), '[]'::jsonb)
          )
          order by case p.type when 'principal' then 0 else 1 end, p.created_at
        )
        from public.playlists p
        where p.created_by_operator_id = o.id
          and p.status <> 'archived'
      ), '[]'::jsonb),
      'request_history', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', hist.id,
            'name', hist.name,
            'type', hist.type,
            'approval_status', hist.approval_status,
            'import_status', hist.import_status,
            'source_url', hist.source_url,
            'submitted_at', hist.submitted_at,
            'reviewed_at', hist.reviewed_at,
            'rejection_reason', hist.rejection_reason,
            'error_message', hist.error_message
          )
          order by coalesce(hist.submitted_at, hist.created_at) desc
        )
        from (
          select p2.*
          from public.playlists p2
          where p2.created_by_operator_id = o.id
          order by coalesce(p2.submitted_at, p2.created_at) desc
          limit 20
        ) hist
      ), '[]'::jsonb)
    ) as operator_row
    from visible_operators o
  ) q;

  return jsonb_build_object('rows', v_rows, 'total', v_total);
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_music_storage_overview"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
  v_result jsonb;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  select jsonb_build_object(
    'total_tracks', count(*),
    'linked_tracks', count(*) filter (
      where exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'orphaned_tracks', count(*) filter (
      where t.status = 'available'
        and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'queued_deletions', (
      select count(*) from public.storage_deletion_jobs j where j.status in ('queued', 'running', 'error')
    ),
    'measured_tracks', count(*) filter (
      where coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
    ),
    'used_bytes', coalesce(sum(
      case
        when coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
          then (t.metadata->>'size_bytes')::bigint
        else 0
      end
    ), 0),
    'last_measured_at', max(nullif(t.metadata->>'storage_checked_at', '')::timestamptz)
  ) into v_result
  from public.tracks t;

  return v_result;
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_operator_attention_leaderboard"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_limit int := least(greatest(coalesce(nullif(p_request->>'ranking_page_size', '')::int, 5), 1), 50);
  v_reset timestamptz;
  v_payload jsonb;
begin
  perform private.require_admin_for_backend(null, v_unit);

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  v_reset := private.statistics_reset_at();
  if v_reset is not null and v_reset > v_start then
    v_start := v_reset;
  end if;

  if v_end <= v_start then
    return jsonb_build_object('idle', '[]'::jsonb, 'blocked', '[]'::jsonb);
  end if;

  with visible_units as (
    select u.id, u.name, u.city, u.state, u.code
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or u.id = v_unit)
  ),
  visible_operators as (
    select
      o.id,
      o.display_name,
      o.unit_id,
      u.name as unit_name,
      u.city as unit_city,
      u.state as unit_state,
      u.code as unit_code,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join visible_units u on u.id = o.unit_id
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (v_operator is null or o.id = v_operator)
  ),
  scoped_operators as (
    select * from visible_operators where v_shift = 'all' or shift_kind = v_shift
  ),
  last_status_before_period as (
    select distinct on (h.operator_id)
      h.operator_id, h.to_status, h.occurred_at
    from public.operator_status_history h
    join scoped_operators o on o.id = h.operator_id
    where h.occurred_at < v_start
    order by h.operator_id, h.occurred_at desc
  ),
  status_points as (
    select operator_id, to_status, occurred_at from last_status_before_period
    union all
    select h.operator_id, h.to_status, h.occurred_at
    from public.operator_status_history h
    join scoped_operators o on o.id = h.operator_id
    where h.occurred_at >= v_start and h.occurred_at < v_end
  ),
  status_ordered as (
    select
      operator_id,
      to_status,
      occurred_at,
      lead(occurred_at) over (partition by operator_id order by occurred_at) as next_at
    from status_points
  ),
  idle_agg as (
    select
      operator_id,
      count(*)::int as idle_events,
      coalesce(sum(extract(epoch from (
        least(coalesce(next_at, v_end), v_end) - greatest(occurred_at, v_start)
      )))::bigint, 0) as idle_seconds,
      max(occurred_at) as last_idle_at
    from status_ordered
    where to_status = 'idle'
      and greatest(occurred_at, v_start) < least(coalesce(next_at, v_end), v_end)
    group by operator_id
  ),
  block_agg as (
    select
      b.operator_id,
      count(*)::int as block_count,
      coalesce(sum(extract(epoch from (
        least(coalesce(b.finished_at, b.revoked_at, b.blocked_until, v_end), v_end)
        - greatest(b.started_at, v_start)
      )))::bigint, 0) as blocked_seconds,
      max(b.started_at) as last_block_at
    from public.operator_blocks b
    join scoped_operators o on o.id = b.operator_id
    where b.started_at < v_end
      and coalesce(b.finished_at, b.revoked_at, b.blocked_until, v_end) > v_start
    group by b.operator_id
  ),
  operator_metrics as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_id,
      o.unit_name,
      o.unit_city,
      o.unit_state,
      o.unit_code,
      coalesce(i.idle_events, 0) as idle_events,
      coalesce(i.idle_seconds, 0) as idle_seconds,
      i.last_idle_at,
      coalesce(b.block_count, 0) as block_count,
      coalesce(b.blocked_seconds, 0) as blocked_seconds,
      b.last_block_at
    from scoped_operators o
    left join idle_agg i on i.operator_id = o.id
    left join block_agg b on b.operator_id = o.id
  ),
  idle_top as (
    select * from operator_metrics
    where idle_seconds > 0
    order by idle_seconds desc, idle_events desc, operator_name
    limit v_limit
  ),
  blocked_top as (
    select * from operator_metrics
    where block_count > 0
    order by block_count desc, blocked_seconds desc, operator_name
    limit v_limit
  )
  select jsonb_build_object(
    'idle', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'idle_events', idle_events,
        'idle_seconds', idle_seconds,
        'last_idle_at', last_idle_at,
        'block_count', block_count,
        'blocked_seconds', blocked_seconds,
        'last_block_at', last_block_at
      ) order by idle_seconds desc, idle_events desc, operator_name)
      from idle_top
    ), '[]'::jsonb),
    'blocked', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'idle_events', idle_events,
        'idle_seconds', idle_seconds,
        'last_idle_at', last_idle_at,
        'block_count', block_count,
        'blocked_seconds', blocked_seconds,
        'last_block_at', last_block_at
      ) order by block_count desc, blocked_seconds desc, operator_name)
      from blocked_top
    ), '[]'::jsonb)
  ) into v_payload;

  return v_payload;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_operator_email"("p_operator" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_op record; v_email text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_op from public.operators where id = p_operator;
  if not found then return null; end if;
  select email into v_email from auth.users where id = v_op.auth_user_id;
  return v_email;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_queue_orphaned_music_deletions"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_queued integer := 0;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  with candidates as (
    select t.id, t.storage_object_key
    from public.tracks t
    where t.status = 'available'
      and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    for update
  ), disabled as (
    update public.tracks t
    set status = 'disabled', revision = revision + 1, updated_at = now()
    from candidates c
    where t.id = c.id
    returning t.id, t.storage_object_key
  ), queued as (
    insert into public.storage_deletion_jobs(track_id, storage_object_key, status, next_attempt_at, last_error)
    select id, storage_object_key, 'queued', now(), null from disabled
    on conflict (track_id) do update
      set status = 'queued', next_attempt_at = now(), last_error = null, locked_at = null, updated_at = now()
    returning id
  )
  select count(*) into v_queued from queued;

  return jsonb_build_object('queued', v_queued);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_reimport_playlist_request"("p_request" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_job_id uuid;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid() and active is true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_request
  from public.playlist_requests
  where id = p_request
  for update;

  if v_request.id is null then
    raise exception 'playlist_request_not_found';
  end if;

  select * into v_playlist
  from public.playlists
  where id = v_request.playlist_id
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  if v_request.status <> 'approved' then
    raise exception 'playlist_request_not_approved';
  end if;

  if public.playlist_source_platform(v_request.source_url) <> 'youtube' then
    raise exception 'unsupported_platform';
  end if;

  if exists (
    select 1 from public.download_jobs
    where playlist_id = v_playlist.id and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
  set source_url = v_request.source_url,
      approval_status = 'approved',
      import_status = 'processing',
      error_code = null,
      error_message = null,
      error_details = null,
      last_error_at = null,
      import_started_at = now(),
      import_finished_at = null,
      updated_at = now(),
      revision = revision + 1
  where id = v_playlist.id;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, source_url, status, attempts,
    mode, created_at, updated_at
  ) values (
    v_playlist.id, v_request.id, v_request.source_url, 'queued', 0,
    'playlist', now(), now()
  ) returning id into v_job_id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id,
    before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'playlist_request_reimported',
    'playlist_requests',
    v_request.id,
    to_jsonb(v_playlist),
    jsonb_build_object(
      'playlist_id', v_playlist.id,
      'playlist_request_id', v_request.id,
      'source_url', v_request.source_url,
      'download_job_id', v_job_id
    ),
    now()
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_remove_playlist_track"("p_playlist_track" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_link record;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select
    pt.id,
    pt.playlist_id,
    pt.track_id,
    pt.position,
    p.unit_id,
    p.name as playlist_name,
    t.title as track_title
  into v_link
  from public.playlist_tracks pt
  join public.playlists p on p.id = pt.playlist_id
  join public.tracks t on t.id = pt.track_id
  where pt.id = p_playlist_track
  for update of pt;

  if v_link.id is null then
    raise exception 'playlist_track_not_found';
  end if;

  if v_link.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_link.unit_id) then
    raise exception 'forbidden';
  end if;

  delete from public.playlist_tracks
  where id = p_playlist_track;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, occurred_at
  )
  values (
    v_admin.id,
    'music_playlist_track_removed',
    'playlist_track',
    p_playlist_track,
    jsonb_build_object(
      'playlist_id', v_link.playlist_id,
      'track_id', v_link.track_id,
      'position', v_link.position,
      'playlist_name', v_link.playlist_name,
      'track_title', v_link.track_title
    ),
    now()
  );

  return jsonb_build_object('ok', true, 'playlist_id', v_link.playlist_id, 'track_id', v_link.track_id);
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_rename_music_playlist"("p_playlist" "uuid", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_before public.playlists%rowtype;
  v_name text := nullif(btrim(p_name), '');
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_name is null then
    raise exception 'name_required';
  end if;

  if char_length(v_name) > 80 then
    raise exception 'name_too_long';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  if v_playlist.name is distinct from v_name then
    v_before := v_playlist;

    update public.playlists
    set name = v_name,
        updated_at = now(),
        revision = revision + 1
    where id = p_playlist
    returning * into v_playlist;

    insert into public.admin_audit_logs (
      admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
    )
    values (
      v_admin.id,
      'music_playlist_renamed',
      'playlist',
      p_playlist,
      jsonb_build_object('name', v_before.name),
      jsonb_build_object('name', v_name),
      now()
    );
  end if;

  return jsonb_build_object('ok', true, 'playlist_id', v_playlist.id, 'name', v_playlist.name, 'revision', v_playlist.revision);
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_reset_statistics"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_now timestamptz := clock_timestamp();
  v_before jsonb;
  v_revision bigint;
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select value, revision
  into v_before, v_revision
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
  for update;

  update public.system_settings
  set active = false,
      updated_at = v_now
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true;

  insert into public.system_settings (
    scope_type, scope_id, key, value, revision, active, created_at, updated_at
  ) values (
    'global', null, 'statistics_reset', jsonb_build_object('reset_at', v_now),
    coalesce(v_revision, 0) + 1, true, v_now, v_now
  );

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'statistics_reset',
    'analytics',
    v_before,
    jsonb_build_object('reset_at', v_now),
    v_now
  );

  return jsonb_build_object('reset_at', v_now);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_retry_playlist_import"("p_playlist" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_platform text;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.approval_status <> 'approved' then
    raise exception 'playlist_not_approved';
  end if;

  v_platform := public.playlist_source_platform(v_playlist.source_url);
  if v_platform <> 'youtube' then
    update public.playlists
    set
      import_status = 'failed',
      error_code = case when v_platform = 'spotify' then 'SPOTIFY_UNSUPPORTED' else 'UNSUPPORTED_PLATFORM' end,
      error_message = public.playlist_import_error_message(
        case when v_platform = 'spotify' then 'SPOTIFY_UNSUPPORTED' else 'UNSUPPORTED_PLATFORM' end,
        null
      ),
      error_details = jsonb_build_object('platform', v_platform, 'source_url', v_playlist.source_url),
      last_error_at = now()
    where id = p_playlist;
    return;
  end if;

  if exists (
    select 1
    from public.download_jobs
    where playlist_id = p_playlist
      and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
  set
    import_status = 'processing',
    error_code = null,
    error_message = null,
    error_details = null,
    last_error_at = null,
    import_started_at = now(),
    import_finished_at = null
  where id = p_playlist;

  insert into public.download_jobs (playlist_id, source_url, status, attempts, created_at, updated_at)
  values (p_playlist, v_playlist.source_url, 'queued', 0, now(), now());
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_review_operator_display_name_request"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_request_id uuid := nullif(p_request->>'request_id', '')::uuid;
  v_decision text := nullif(p_request->>'decision', '');
  v_reason text := btrim(regexp_replace(coalesce(p_request->>'reason', ''), '[[:space:]]+', ' ', 'g'));
  v_request public.operator_display_name_requests%rowtype;
  v_operator public.operators%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if v_request_id is null then raise exception 'display_name_request_required'; end if;
  if v_decision is null or v_decision not in ('approve', 'reject') then raise exception 'display_name_review_decision_invalid'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'display_name_review_reason_invalid'; end if;

  select * into v_request
  from public.operator_display_name_requests
  where id = v_request_id
  for update;

  if v_request.id is null then raise exception 'display_name_request_not_found'; end if;
  v_admin := private.require_admin_for_backend(null, v_request.unit_id);

  if v_request.moderation_result <> 'blocked' or v_request.review_status <> 'pending' then
    return jsonb_build_object(
      'success', false, 'server_now', v_now, 'data', null,
      'error', jsonb_build_object('code', 'DISPLAY_NAME_REQUEST_ALREADY_REVIEWED', 'message', 'Essa solicitacao nao esta mais pendente.', 'retryable', false)
    );
  end if;

  select * into v_operator
  from public.operators
  where id = v_request.operator_id
  for update;

  if v_decision = 'approve' then
    if v_operator.display_name is distinct from v_request.previous_name then
      return jsonb_build_object(
        'success', false, 'server_now', v_now, 'data', null,
        'error', jsonb_build_object('code', 'DISPLAY_NAME_REVIEW_CONFLICT', 'message', 'O nome atual mudou depois dessa solicitacao. Atualize a lista antes de revisar.', 'retryable', false)
      );
    end if;

    perform set_config('app.audit_source', 'admin_approval', true);
    update public.operators
    set display_name = v_request.requested_name,
        updated_at = v_now
    where id = v_operator.id;

    update public.operator_display_name_requests
    set applied_name = requested_name,
        applied_at = v_now,
        review_status = 'approved',
        reviewed_by_admin_id = v_admin.id,
        reviewed_at = v_now,
        review_reason = v_reason
    where id = v_request.id;
  else
    update public.operator_display_name_requests
    set review_status = 'rejected',
        reviewed_by_admin_id = v_admin.id,
        reviewed_at = v_now,
        review_reason = v_reason
    where id = v_request.id;
  end if;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason
  )
  select
    v_admin.id,
    case when v_decision = 'approve' then 'display_name_request_approved' else 'display_name_request_rejected' end,
    'operator_display_name_request',
    v_request.id,
    to_jsonb(v_request),
    to_jsonb(r),
    v_reason
  from public.operator_display_name_requests r
  where r.id = v_request.id;

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object(
      'request_id', v_request.id,
      'decision', v_decision,
      'display_name', case when v_decision = 'approve' then v_request.requested_name else v_operator.display_name end,
      'next_change_at', case when v_decision = 'approve' then v_now + interval '15 days' else null end
    ),
    'error', null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_review_playlist"("p_playlist" "uuid", "p_action" "text", "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_response jsonb;
  v_status text;
  v_admin_id uuid;
  v_playlist_request_id uuid;
  v_request_source_url text;
  v_download_job_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_audit_request_id uuid := gen_random_uuid();
begin
  if not public.is_admin() then
    raise exception 'forbidden';
  end if;

  select admin_row.id
    into v_admin_id
    from public.admin_users as admin_row
   where admin_row.auth_user_id = auth.uid()
     and admin_row.active is true;

  select request_row.id, request_row.source_url
    into v_playlist_request_id, v_request_source_url
    from public.playlist_requests as request_row
   where request_row.playlist_id = p_playlist
     and request_row.status = 'pending'
   order by request_row.created_at desc, request_row.id desc
   limit 1
   for update;

  select pg_catalog.to_jsonb(playlist_row)
    into v_before
    from public.playlists as playlist_row
   where playlist_row.id = p_playlist;

  v_response := public.admin_review_playlist_impl(p_playlist, p_action, p_reason);
  v_status := case
    when p_action = 'approve' then 'approved'
    when p_action = 'reject' then 'rejected'
    else null
  end;

  if v_status is null then
    return v_response;
  end if;

  if v_status = 'approved' and v_playlist_request_id is not null then
    select job.id
      into v_download_job_id
      from public.download_jobs as job
     where job.playlist_id = p_playlist
       and job.source_url is not distinct from v_request_source_url
     order by job.created_at desc, job.id desc
     limit 1;
  end if;

  update public.playlist_requests as request_row
     set status = v_status,
         download_job_id = case
           when v_status = 'approved' then v_download_job_id
           else null
         end,
         updated_at = pg_catalog.now(),
         decided_at = pg_catalog.now(),
         decided_by = v_admin_id,
         rejection_reason = case
           when v_status = 'rejected' then nullif(
             pg_catalog.left(
               pg_catalog.btrim(
                 pg_catalog.regexp_replace(coalesce(p_reason, ''), '[[:cntrl:]]+', ' ', 'g')
               ),
               500
             ),
             ''
           )
           else null
         end
   where request_row.id = v_playlist_request_id;

  select pg_catalog.to_jsonb(playlist_row)
    into v_after
    from public.playlists as playlist_row
   where playlist_row.id = p_playlist;

  insert into public.admin_audit_logs (
    admin_user_id,
    action,
    entity_type,
    entity_id,
    request_id,
    before_data,
    after_data,
    reason,
    occurred_at
  ) values (
    v_admin_id,
    case when v_status = 'approved' then 'playlist_approved' else 'playlist_rejected' end,
    'playlists',
    p_playlist,
    v_audit_request_id,
    v_before,
    v_after,
    case when v_status = 'rejected' then nullif(pg_catalog.btrim(p_reason), '') else null end,
    pg_catalog.now()
  );

  return v_response;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_review_playlist_impl"("p_playlist" "uuid", "p_action" "text", "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_pl record; v_admin uuid;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_pl from public.playlists where id = p_playlist;
  if not found then raise exception 'playlist_not_found'; end if;

  -- DecisÃ£o Ã© definitiva: uma playlist jÃ¡ aprovada ou rejeitada nÃ£o pode ser revista.
  if v_pl.approval_status in ('approved','rejected') then
    raise exception 'already_reviewed';
  end if;

  if v_pl.unit_id is not null and not public.admin_can_manage_operator_unit(v_pl.unit_id) then
    if not public.is_superadmin() then raise exception 'forbidden'; end if;
  end if;
  select id into v_admin from public.admin_users where auth_user_id = auth.uid();

  if p_action = 'approve' then
    update public.playlists
       set approval_status = 'approved', status = 'active', reviewed_at = now(),
           reviewed_by = v_admin, rejection_reason = null, updated_at = now(), revision = revision + 1
     where id = p_playlist;

    -- Enfileira download automÃ¡tico para playlists do YouTube.
    if v_pl.source_url is not null
       and (v_pl.source_url ilike '%youtube.com%' or v_pl.source_url ilike '%youtu.be%')
       and not exists (
         select 1 from public.download_jobs
          where playlist_id = p_playlist and status in ('queued','running')
       )
    then
      insert into public.download_jobs (playlist_id, source_url, status)
      values (p_playlist, v_pl.source_url, 'queued');
    end if;

  elsif p_action = 'reject' then
    update public.playlists
       set approval_status = 'rejected', status = 'inactive', reviewed_at = now(),
           reviewed_by = v_admin, rejection_reason = nullif(btrim(p_reason),''), updated_at = now(), revision = revision + 1
     where id = p_playlist;
  else
    raise exception 'invalid_action';
  end if;

  return jsonb_build_object('ok', true, 'approval_status', case when p_action='approve' then 'approved' else 'rejected' end);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_save_challenge_rules"("p_unit_id" "uuid", "p_rules" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
  v_start_text text := coalesce(nullif(p_rules->>'active_window_start', ''), '00:00');
  v_end_text text := coalesce(nullif(p_rules->>'active_window_end', ''), '00:00');
  v_timezone text := coalesce(nullif(p_rules->>'timezone', ''), 'America/Sao_Paulo');
  v_start time;
  v_end time;
  v_window_seconds integer;
  v_rules jsonb;
  v_existing_id uuid;
  v_existing_revision bigint;
  v_expected_revision bigint := nullif(p_rules->>'revision', '')::bigint;
  v_min_interval integer;
  v_max_interval integer;
  v_response_seconds integer;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    p_unit_id
  );

  v_min_interval := coalesce((p_rules->>'min_interval_seconds')::integer, 0);
  v_max_interval := coalesce((p_rules->>'max_interval_seconds')::integer, 0);
  v_response_seconds := coalesce((p_rules->>'response_seconds')::integer, 0);

  if v_min_interval < 1 or v_max_interval < v_min_interval then
    raise exception 'janela_intervalo_invalida';
  end if;

  if v_response_seconds < 1 then
    raise exception 'tempo_resposta_invalido';
  end if;

  if coalesce((p_rules->>'abandon_block_seconds')::integer, -1) < 0 then
    raise exception 'tempo_abandono_invalido';
  end if;

  if v_start_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or v_end_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'janela_horario_invalida';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_timezone_names
    where name = v_timezone
  ) then
    raise exception 'fuso_horario_invalido';
  end if;

  v_start := v_start_text::time;
  v_end := v_end_text::time;

  if v_start <> v_end then
    v_window_seconds := case
      when v_start < v_end then extract(epoch from (v_end - v_start))::integer
      else 86400 - extract(epoch from (v_start - v_end))::integer
    end;

    if v_max_interval >= v_window_seconds then
      raise exception 'intervalo_maior_que_janela_horaria';
    end if;
  end if;

  -- revision is transport metadata used for optimistic concurrency and must
  -- not become part of the effective challenge rules.
  v_rules := (p_rules - 'revision') || jsonb_build_object(
    'active_window_start', v_start_text,
    'active_window_end', v_end_text,
    'timezone', v_timezone
  );

  select id, revision
  into v_existing_id, v_existing_revision
  from public.system_settings
  where key = 'challenge_rules'
    and scope_type = case when p_unit_id is null then 'global' else 'unit' end
    and scope_id is not distinct from p_unit_id
  order by revision desc, updated_at desc, id desc
  limit 1
  for update;

  if v_existing_id is null then
    if coalesce(v_expected_revision, 0) <> 0 then
      raise exception 'challenge_rules_conflict';
    end if;

    insert into public.system_settings(
      scope_type,
      scope_id,
      key,
      value,
      active,
      revision,
      updated_by,
      updated_at
    )
    values (
      case when p_unit_id is null then 'global' else 'unit' end,
      p_unit_id,
      'challenge_rules',
      v_rules,
      true,
      1,
      v_admin.auth_user_id,
      now()
    );
  else
    if v_expected_revision is not null
       and v_expected_revision <> v_existing_revision then
      raise exception 'challenge_rules_conflict';
    end if;

    update public.system_settings
    set value = v_rules,
        active = true,
        revision = revision + 1,
        updated_by = v_admin.auth_user_id,
        updated_at = now()
    where id = v_existing_id;

    update public.system_settings
    set active = false,
        updated_at = now()
    where key = 'challenge_rules'
      and scope_type = case when p_unit_id is null then 'global' else 'unit' end
      and scope_id is not distinct from p_unit_id
      and id <> v_existing_id
      and active;
  end if;

  -- Existing scheduled rows were created from the previous rules. Recalculate
  -- only those rows; challenges already pending/displayed/idle remain intact.
  with reschedule_targets as (
    select
      cl.id,
      private.challenge_schedule_at(
        v_rules,
        floor(
          random() * (v_max_interval - v_min_interval + 1)
        )::integer + v_min_interval,
        now()
      ) as next_scheduled_for
    from public.challenge_logs cl
    join public.operators o on o.id = cl.operator_id
    where cl.status = 'scheduled'
      and (
        (p_unit_id is not null and o.unit_id = p_unit_id)
        or (
          p_unit_id is null
          and not exists (
            select 1
            from public.system_settings unit_rules
            where unit_rules.key = 'challenge_rules'
              and unit_rules.scope_type = 'unit'
              and unit_rules.scope_id = o.unit_id
              and unit_rules.active
          )
        )
      )
  )
  update public.challenge_logs cl
  set scheduled_for = targets.next_scheduled_for,
      pending_at = now(),
      expires_at = targets.next_scheduled_for
        + make_interval(secs => v_response_seconds),
      metadata = coalesce(cl.metadata, '{}'::jsonb) || jsonb_build_object(
        'rescheduled_reason', 'challenge_rules_changed',
        'rescheduled_at', now(),
        'rules_scope', case when p_unit_id is null then 'global' else 'unit' end,
        'rules_scope_id', p_unit_id
      )
  from reschedule_targets targets
  where cl.id = targets.id
    and cl.status = 'scheduled';
end
$_$;




COMMENT ON FUNCTION "public"."admin_save_challenge_rules"("p_unit_id" "uuid", "p_rules" "jsonb") IS 'Saves challenge rules with optional revision concurrency control and reschedules affected scheduled challenges.';



CREATE OR REPLACE FUNCTION "public"."admin_set_challenge_status"("p_challenge_id" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_unit uuid;
begin
  select unit_id
    into v_unit
  from public.challenges
  where id = p_challenge_id;

  if not found then
    raise exception 'desafio_nao_encontrado';
  end if;

  perform private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    v_unit
  );

  if p_status not in ('draft', 'active', 'inactive', 'archived') then
    raise exception 'status_invalido';
  end if;

  update public.challenges
  set status = p_status,
      revision = revision + 1,
      updated_at = now()
  where id = p_challenge_id;
end
$$;




COMMENT ON FUNCTION "public"."admin_set_challenge_status"("p_challenge_id" "uuid", "p_status" "text") IS 'Atualiza o status do desafio. A tabela usa status como fonte unica de verdade.';



CREATE OR REPLACE FUNCTION "public"."admin_set_operator_shift"("p_operator" "uuid", "p_kind" "text", "p_start" time without time zone DEFAULT NULL::time without time zone, "p_end" time without time zone DEFAULT NULL::time without time zone) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_op record; v_name text; v_s time; v_e time; v_shift uuid; v_tz text;
begin
  select * into v_op from public.operators where id = p_operator;
  if not found then raise exception 'operator_not_found'; end if;
  if not public.admin_can_manage_operator_unit(v_op.unit_id) then raise exception 'forbidden'; end if;

  if p_kind is null or p_kind in ('', 'none') then
    update public.operators set default_shift_id = null, updated_at = now(), revision = revision + 1 where id = p_operator;
    return jsonb_build_object('shift_id', null);
  end if;

  if p_kind = '12x36_dia' then v_name := '12x36 Diurno'; v_s := time '06:00'; v_e := time '18:00';
  elsif p_kind = '12x36_noite' then v_name := '12x36 Noturno'; v_s := time '18:00'; v_e := time '06:00';
  elsif p_kind = '6x1' then v_name := '6x1'; v_s := coalesce(p_start, time '07:00'); v_e := coalesce(p_end, time '19:00');
  else raise exception 'invalid_kind'; end if;

  select coalesce(nullif(timezone,''),'America/Sao_Paulo') into v_tz from public.units where id = v_op.unit_id;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');

  if v_op.default_shift_id is not null and exists(select 1 from public.shifts where id = v_op.default_shift_id) then
    update public.shifts
      set name = v_name, starts_at = v_s, ends_at = v_e,
          days_of_week = array[0,1,2,3,4,5,6]::smallint[],
          timezone = v_tz, active = true, updated_at = now(), revision = revision + 1
      where id = v_op.default_shift_id
      returning id into v_shift;
  else
    insert into public.shifts(unit_id, name, starts_at, ends_at, days_of_week, timezone, active)
      values(v_op.unit_id, v_name, v_s, v_e, array[0,1,2,3,4,5,6]::smallint[], v_tz, true)
      returning id into v_shift;
    update public.operators set default_shift_id = v_shift, updated_at = now(), revision = revision + 1 where id = p_operator;
  end if;

  return jsonb_build_object('shift_id', v_shift, 'name', v_name, 'starts_at', v_s::text, 'ends_at', v_e::text);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_statistics_reset_info"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform private.require_admin_for_backend(null, null);
  return jsonb_build_object('reset_at', private.statistics_reset_at());
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_update_admin_user"("p_admin_user" "uuid", "p_display_name" "text", "p_role" "text", "p_active" boolean, "p_mfa_required" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.admin_users%rowtype;
  v_after public.admin_users%rowtype;
  v_display_name text := nullif(btrim(coalesce(p_display_name, '')), '');
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  if v_display_name is null then
    raise exception 'display_name_required';
  end if;

  if p_role not in (
    'superadmin',
    'unit_manager',
    'operations_manager',
    'content_manager',
    'challenge_manager',
    'release_manager',
    'auditor',
    'support_readonly'
  ) then
    raise exception 'admin_role_invalid';
  end if;

  select * into v_before
  from public.admin_users
  where id = p_admin_user
  for update;

  if v_before.id is null then
    raise exception 'admin_user_not_found';
  end if;

  if v_before.id = v_admin.id and coalesce(p_active, true) = false then
    raise exception 'cannot_deactivate_own_admin';
  end if;

  update public.admin_users
  set display_name = v_display_name,
      role = p_role,
      active = coalesce(p_active, active),
      mfa_required = coalesce(p_mfa_required, mfa_required)
  where id = p_admin_user
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'admin_user_status_changed'
      else 'admin_user_updated'
    end,
    'admin_user',
    p_admin_user,
    jsonb_build_object(
      'display_name', v_before.display_name,
      'role', v_before.role,
      'active', v_before.active,
      'mfa_required', v_before.mfa_required
    ),
    jsonb_build_object(
      'display_name', v_after.display_name,
      'role', v_after.role,
      'active', v_after.active,
      'mfa_required', v_after.mfa_required
    ),
    now()
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_update_feedback_status"("p_feedback" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.feedback%rowtype;
  v_after public.feedback%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager','content_manager'],
    null
  );

  if p_status not in ('new', 'read', 'resolved') then
    raise exception 'feedback_status_invalid';
  end if;

  select * into v_before
  from public.feedback
  where id = p_feedback
  for update;

  if v_before.id is null then
    raise exception 'feedback_not_found';
  end if;

  update public.feedback
  set status = p_status,
      resolved_at = case when p_status = 'resolved' then now() else null end,
      updated_at = now()
  where id = p_feedback
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'feedback_status_changed',
    'feedback',
    p_feedback,
    jsonb_build_object('status', v_before.status, 'resolved_at', v_before.resolved_at),
    jsonb_build_object('status', v_after.status, 'resolved_at', v_after.resolved_at),
    now()
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_update_operator"("p_operator" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_admin public.admin_users%rowtype;
  v_before public.operators%rowtype;
  v_after public.operators%rowtype;
  v_display_name text := nullif(btrim(coalesce(p_display_name, '')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select * into v_before
  from public.operators
  where id = p_operator
  for update;

  if v_before.id is null then
    raise exception 'operator_not_found';
  end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_before.unit_id
  );

  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if v_display_name is null then
    raise exception 'display_name_required';
  end if;

  if v_username is not null and v_username !~ '^[a-z0-9._-]{3,60}$' then
    raise exception 'username_invalid';
  end if;

  if p_role not in ('operador', 'supervisor') then
    raise exception 'operator_role_invalid';
  end if;

  if p_session_policy not in ('single', 'multi') then
    raise exception 'session_policy_invalid';
  end if;

  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  update public.operators
  set display_name = v_display_name,
      username = v_username,
      unit_id = p_unit_id,
      role = p_role,
      session_policy = p_session_policy,
      active = coalesce(p_active, active),
      updated_at = now()
  where id = p_operator
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'operator_status_changed'
      else 'operator_updated'
    end,
    'operator',
    p_operator,
    jsonb_build_object(
      'display_name', v_before.display_name,
      'username', v_before.username,
      'unit_id', v_before.unit_id,
      'role', v_before.role,
      'session_policy', v_before.session_policy,
      'active', v_before.active
    ),
    jsonb_build_object(
      'display_name', v_after.display_name,
      'username', v_after.username,
      'unit_id', v_after.unit_id,
      'role', v_after.role,
      'session_policy', v_after.session_policy,
      'active', v_after.active
    ),
    now()
  );
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_update_operator_display_name"("p_operator" "uuid", "p_display_name" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_display_name text := nullif(btrim(regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_reason text := btrim(regexp_replace(coalesce(p_reason, ''), '[[:space:]]+', ' ', 'g'));
  v_now timestamptz := clock_timestamp();
begin
  select * into v_operator
  from public.operators
  where id = p_operator
  for update;

  if v_operator.id is null then raise exception 'operator_not_found'; end if;
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_operator.unit_id
  );

  if v_display_name is null or char_length(v_display_name) < 3 or char_length(v_display_name) > 50 then
    raise exception 'display_name_length_invalid';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then
    raise exception 'display_name_admin_reason_invalid';
  end if;

  if v_display_name = v_operator.display_name then
    return jsonb_build_object(
      'success', true,
      'server_now', v_now,
      'data', jsonb_build_object('display_name', v_operator.display_name, 'changed', false),
      'error', null
    );
  end if;

  perform set_config('app.audit_source', 'admin_explicit', true);
  update public.operators
  set display_name = v_display_name,
      updated_at = v_now
  where id = v_operator.id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    v_admin.id,
    'operator_display_name_corrected',
    'operator',
    v_operator.id,
    jsonb_build_object('display_name', v_operator.display_name),
    jsonb_build_object('display_name', v_display_name),
    v_reason,
    v_now
  );

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object('display_name', v_display_name, 'changed', true),
    'error', null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_update_operator_profile_v2"("p_operator" "uuid", "p_registered_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_before public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_registered_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select * into v_before
  from public.operators
  where id = p_operator
  for update;

  if v_before.id is null then raise exception 'operator_not_found'; end if;

  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_before.unit_id
  );
  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if v_registered_name is null then raise exception 'registered_name_required'; end if;
  if v_registered_name is distinct from v_before.registered_name then
    raise exception 'registered_name_use_dedicated_rpc';
  end if;
  if v_username is not null and v_username !~ '^[a-z0-9._-]{3,60}$' then raise exception 'username_invalid'; end if;
  if p_role not in ('operador', 'supervisor') then raise exception 'operator_role_invalid'; end if;
  if p_session_policy not in ('single', 'multi') then raise exception 'session_policy_invalid'; end if;
  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  perform set_config('app.audit_source', 'admin_profile', true);
  update public.operators
  set username = v_username,
      unit_id = p_unit_id,
      role = p_role,
      session_policy = p_session_policy,
      active = coalesce(p_active, active),
      updated_at = clock_timestamp()
  where id = p_operator;
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."admin_update_unit"("p_unit" "uuid", "p_code" "text", "p_name" "text", "p_address" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_timezone" "text" DEFAULT 'America/Sao_Paulo'::"text", "p_active" boolean DEFAULT true) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.units%rowtype;
  v_after public.units%rowtype;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_timezone text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'America/Sao_Paulo');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit
  );

  if v_code is null then
    raise exception 'unit_code_required';
  end if;

  if v_name is null then
    raise exception 'unit_name_required';
  end if;

  select * into v_before
  from public.units
  where id = p_unit
  for update;

  if v_before.id is null then
    raise exception 'unit_not_found';
  end if;

  update public.units
  set code = v_code,
      name = v_name,
      address = nullif(btrim(coalesce(p_address, '')), ''),
      city = nullif(btrim(coalesce(p_city, '')), ''),
      state = nullif(upper(btrim(coalesce(p_state, ''))), ''),
      timezone = v_timezone,
      active = coalesce(p_active, active),
      updated_at = now()
  where id = p_unit
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'unit_status_changed'
      else 'unit_updated'
    end,
    'unit',
    p_unit,
    jsonb_build_object(
      'code', v_before.code,
      'name', v_before.name,
      'address', v_before.address,
      'city', v_before.city,
      'state', v_before.state,
      'timezone', v_before.timezone,
      'active', v_before.active
    ),
    jsonb_build_object(
      'code', v_after.code,
      'name', v_after.name,
      'address', v_after.address,
      'city', v_after.city,
      'state', v_after.state,
      'timezone', v_after.timezone,
      'active', v_after.active
    ),
    now()
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."admin_upsert_challenge"("p_challenge" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid := nullif(p_challenge->>'id', '')::uuid;
  v_unit_id uuid := nullif(p_challenge->>'unit_id', '')::uuid;
  v_admin public.admin_users%rowtype;
  v_title text := nullif(btrim(p_challenge->>'title'), '');
  v_prompt text := nullif(btrim(p_challenge->>'prompt'), '');
  v_answer_definition jsonb := p_challenge->'answer_definition';
  v_options jsonb;
  v_correct text;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    v_unit_id
  );

  if v_title is null then raise exception 'titulo_obrigatorio'; end if;
  if v_prompt is null then raise exception 'enunciado_obrigatorio'; end if;
  if jsonb_typeof(v_answer_definition->'alternatives') <> 'array'
     or jsonb_array_length(v_answer_definition->'alternatives') <> 4 then
    raise exception 'respostas_invalidas';
  end if;

  -- The current Admin still posts alternatives plus the A-D correct letter.
  -- Generate fixed ids in that semantic order, so editing text never changes
  -- the saved correct choice and no frontend contract needs to change now.
  v_correct := upper(coalesce(v_answer_definition->>'correct', ''));
  v_options := jsonb_build_array(
    jsonb_build_object('id', 'option_a', 'text', v_answer_definition->'alternatives'->>0),
    jsonb_build_object('id', 'option_b', 'text', v_answer_definition->'alternatives'->>1),
    jsonb_build_object('id', 'option_c', 'text', v_answer_definition->'alternatives'->>2),
    jsonb_build_object('id', 'option_d', 'text', v_answer_definition->'alternatives'->>3)
  );
  v_answer_definition := jsonb_build_object(
    'alternatives', v_answer_definition->'alternatives',
    'correct', v_correct,
    'options', v_options,
    'correct_option_id', 'option_' || lower(v_correct)
  );

  if not private.challenge_answer_definition_is_valid(v_answer_definition) then
    raise exception 'respostas_invalidas';
  end if;

  if v_id is null then
    insert into public.challenges(title, prompt, kind, answer_definition, status, unit_id, created_by)
    values(v_title, v_prompt, 'multiple_choice', v_answer_definition,
      coalesce(p_challenge->>'status', 'draft'), v_unit_id, v_admin.id)
    returning id into v_id;
  else
    update public.challenges
    set title = v_title,
        prompt = v_prompt,
        answer_definition = v_answer_definition,
        status = coalesce(p_challenge->>'status', status),
        unit_id = v_unit_id,
        block_seconds = null,
        revision = revision + 1,
        updated_at = now()
    where id = v_id;
  end if;

  return v_id;
end
$$;




CREATE OR REPLACE FUNCTION "public"."admin_upsert_operator_display_name_term"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin public.admin_users%rowtype;
  v_id uuid := nullif(p_request->>'id', '')::uuid;
  v_term text := btrim(regexp_replace(coalesce(p_request->>'term', ''), '[[:space:]]+', ' ', 'g'));
  v_match_type text := coalesce(nullif(p_request->>'match_type', ''), 'whole_word');
  v_reason text := btrim(regexp_replace(coalesce(p_request->>'reason', ''), '[[:space:]]+', ' ', 'g'));
  v_active boolean := coalesce((p_request->>'active')::boolean, true);
  v_normalized text;
  v_compact text;
  v_before jsonb;
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  if char_length(v_term) < 2 or char_length(v_term) > 80 then raise exception 'moderation_term_length_invalid'; end if;
  if v_match_type not in ('exact_name', 'whole_word', 'obfuscated') then raise exception 'moderation_match_type_invalid'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'moderation_reason_length_invalid'; end if;

  v_normalized := private.normalize_operator_display_name(v_term, false);
  v_compact := private.normalize_operator_display_name(v_term, true);
  if v_match_type = 'obfuscated' and char_length(v_compact) < 3 then
    raise exception 'moderation_obfuscated_term_too_short';
  end if;

  if v_id is null then
    insert into public.operator_display_name_moderation_terms (
      term, normalized_term, compact_term, match_type, active, reason,
      created_by_admin_id, updated_by_admin_id
    ) values (
      v_term, v_normalized, v_compact, v_match_type, v_active, v_reason,
      v_admin.id, v_admin.id
    ) returning id into v_id;
  else
    select to_jsonb(t) into v_before
    from public.operator_display_name_moderation_terms t
    where t.id = v_id
    for update;
    if v_before is null then raise exception 'moderation_term_not_found'; end if;

    update public.operator_display_name_moderation_terms
    set term = v_term,
        normalized_term = v_normalized,
        compact_term = v_compact,
        match_type = v_match_type,
        active = v_active,
        reason = v_reason,
        updated_by_admin_id = v_admin.id,
        updated_at = clock_timestamp()
    where id = v_id;
  end if;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason
  )
  select
    v_admin.id,
    case when v_before is null then 'display_name_term_created' else 'display_name_term_updated' end,
    'operator_display_name_moderation_term',
    v_id,
    v_before,
    to_jsonb(t),
    v_reason
  from public.operator_display_name_moderation_terms t
  where t.id = v_id;

  return jsonb_build_object('success', true, 'server_now', clock_timestamp(), 'data', jsonb_build_object('id', v_id), 'error', null);
exception
  when unique_violation then
    return jsonb_build_object(
      'success', false, 'server_now', clock_timestamp(), 'data', null,
      'error', jsonb_build_object('code', 'MODERATION_TERM_ALREADY_EXISTS', 'message', 'Esse termo e tipo de correspondencia ja existem.', 'retryable', false)
    );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."approve_app_release"("p_release_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
begin
  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status not in ('draft', 'testing') then
    raise exception 'invalid_release_status';
  end if;
  if not private.app_release_required_ready(v_release) then
    raise exception 'release_required_fields_missing';
  end if;

  update public.app_releases
  set status = 'approved',
      approved_by = v_admin_id,
      approved_at = now(),
      updated_at = now()
  where id = p_release_id;

  perform private.log_app_release_audit(
    p_release_id,
    'approved',
    v_release.status,
    'approved',
    v_admin_id,
    jsonb_build_object('version', v_release.version, 'channel', v_release.channel)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."audit_admin_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_admin uuid;
  v_entity uuid;
  v_source text := nullif(current_setting('app.audit_source', true), '');
begin
  if v_source in ('operator_app', 'admin_approval', 'admin_explicit') then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  select admin_row.id
    into v_admin
    from public.admin_users as admin_row
   where admin_row.auth_user_id = auth.uid();

  if tg_op = 'DELETE' then
    v_entity := old.id;
  else
    v_entity := new.id;
  end if;

  insert into public.admin_audit_logs(
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    reason
  ) values (
    v_admin,
    lower(tg_op),
    tg_table_name,
    v_entity,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end,
    v_source
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."block_app_release"("p_release_id" "uuid", "p_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'block_reason_required';
  end if;

  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status in ('blocked', 'superseded') then
    raise exception 'invalid_release_status';
  end if;

  update public.app_releases
  set status = 'blocked',
      is_current = false,
      blocked_by = v_admin_id,
      blocked_at = now(),
      block_reason = v_reason,
      updated_at = now()
  where id = p_release_id;

  perform private.log_app_release_audit(
    p_release_id,
    'blocked',
    v_release.status,
    'blocked',
    v_admin_id,
    jsonb_build_object('reason', v_reason, 'was_current', v_release.is_current)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."capture_playlist_request_track"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_request_id uuid;
begin
  select j.playlist_request_id into v_request_id
  from public.download_jobs j
  where j.playlist_id = new.playlist_id
    and j.playlist_request_id is not null
    and j.status in ('queued', 'running')
  order by j.created_at desc
  limit 1;

  if v_request_id is null then
    select r.id into v_request_id
    from public.playlist_requests r
    join public.playlists p on p.id = r.playlist_id
    where r.playlist_id = new.playlist_id
      and r.status = 'approved'
      and r.source_url = p.source_url
    order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc
    limit 1;
  end if;

  if v_request_id is not null then
    insert into public.playlist_request_tracks (
      playlist_request_id, track_id, position, captured_at
    ) values (
      v_request_id, new.track_id, greatest(new.position, 0), now()
    )
    on conflict (playlist_request_id, track_id) do update
      set position = excluded.position;
  end if;

  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."claim_storage_deletion_job"() RETURNS TABLE("job_id" "uuid", "track_id" "uuid", "storage_object_key" "text", "attempts" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with candidate as (
    select j.id
    from public.storage_deletion_jobs j
    join public.tracks t on t.id=j.track_id and t.status='disabled'
    where (
      (
        (j.status in ('queued','error') and j.next_attempt_at<=now())
        or (j.status='running' and j.locked_at<now()-interval '10 minutes')
      )
      and not exists(select 1 from public.playlist_tracks pt where pt.track_id=j.track_id)
    )
    order by j.created_at
    for update of j skip locked
    limit 1
  ), claimed as (
    update public.storage_deletion_jobs j
       set status='running',attempts=j.attempts+1,locked_at=now(),updated_at=now()
      from candidate c
     where j.id=c.id
     returning j.id,j.track_id,j.storage_object_key,j.attempts
  )
  select id,track_id,storage_object_key,attempts from claimed;
$$;




CREATE OR REPLACE FUNCTION "public"."complete_storage_deletion_job"("p_job_id" "uuid", "p_success" boolean, "p_error" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_job public.storage_deletion_jobs%rowtype;
  v_refs integer;
begin
  select * into v_job from public.storage_deletion_jobs where id=p_job_id for update;
  if not found then return jsonb_build_object('success',false,'code','JOB_NOT_FOUND'); end if;

  if not p_success then
    update public.storage_deletion_jobs
       set status='error', last_error=left(coalesce(p_error,'Falha ao excluir objeto.'),2000),
           next_attempt_at=now()+make_interval(secs=>least(3600,30*(2^least(attempts,6))::int)),
           locked_at=null, updated_at=now()
     where id=v_job.id;
    return jsonb_build_object('success',false,'code','STORAGE_DELETE_RETRY_QUEUED');
  end if;

  select count(*) into v_refs from public.playlist_tracks where track_id=v_job.track_id;
  if v_refs > 0 then
    update public.storage_deletion_jobs set status='cancelled',locked_at=null,updated_at=now() where id=v_job.id;
    update public.tracks set status='available',revision=revision+1 where id=v_job.track_id;
    return jsonb_build_object('success',false,'code','TRACK_STILL_REFERENCED','reference_count',v_refs);
  end if;

  delete from public.storage_deletion_jobs where id=v_job.id;
  delete from public.tracks where id=v_job.track_id
    and not exists(select 1 from public.playlist_tracks where track_id=v_job.track_id);
  return jsonb_build_object('success',true,'code','TRACK_AND_OBJECT_DELETED');
end;
$$;




CREATE OR REPLACE FUNCTION "public"."create_app_release"("p_version" "text", "p_title" "text" DEFAULT NULL::"text", "p_release_notes" "text" DEFAULT NULL::"text", "p_channel" "text" DEFAULT 'stable'::"text", "p_mandatory" boolean DEFAULT true, "p_minimum_version" "text" DEFAULT NULL::"text", "p_manifest_key" "text" DEFAULT NULL::"text", "p_installer_key" "text" DEFAULT NULL::"text", "p_blockmap_key" "text" DEFAULT NULL::"text", "p_sha512" "text" DEFAULT NULL::"text", "p_size_bytes" bigint DEFAULT NULL::bigint, "p_status" "text" DEFAULT 'draft'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $_$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release_id uuid;
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
  v_version text := nullif(btrim(coalesce(p_version, '')), '');
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_channel text := coalesce(nullif(btrim(coalesce(p_channel, '')), ''), 'stable');
begin
  if v_status not in ('draft', 'testing') then
    raise exception 'invalid_initial_status';
  end if;
  if v_version is null or v_version !~ '^[0-9]+\.[0-9]+\.[0-9]+$' then
    raise exception 'invalid_version';
  end if;
  if v_title is null then
    raise exception 'title_required';
  end if;

  insert into public.app_releases (
    version, channel, status, mandatory, minimum_version, title, release_notes,
    manifest_key, installer_key, blockmap_key, sha512, size_bytes, created_by
  ) values (
    v_version,
    v_channel,
    v_status,
    coalesce(p_mandatory, true),
    nullif(btrim(coalesce(p_minimum_version, '')), ''),
    v_title,
    nullif(btrim(coalesce(p_release_notes, '')), ''),
    nullif(btrim(coalesce(p_manifest_key, '')), ''),
    nullif(btrim(coalesce(p_installer_key, '')), ''),
    nullif(btrim(coalesce(p_blockmap_key, '')), ''),
    nullif(btrim(coalesce(p_sha512, '')), ''),
    p_size_bytes,
    v_admin_id
  )
  returning id into v_release_id;

  perform private.log_app_release_audit(
    v_release_id,
    'created',
    null,
    v_status,
    v_admin_id,
    jsonb_build_object('version', v_version, 'channel', v_channel)
  );

  return v_release_id;
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."current_admin_user_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select a.id
  from public.admin_users a
  where a.auth_user_id = auth.uid()
    and a.active = true
  limit 1;
$$;




CREATE OR REPLACE FUNCTION "public"."current_operator_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select o.id
  from public.operators o
  where o.auth_user_id = (select auth.uid())
    and o.active = true
  limit 1;
$$;




CREATE OR REPLACE FUNCTION "public"."end_operator_session"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_idem uuid := nullif(p_request->>'idempotency_key','')::uuid;
  v_session_id uuid := nullif(p_request->>'session_id','')::uuid;
  v_reason text := coalesce(nullif(p_request->>'reason',''),'operator_logout');
  v_op record; v_sess record; v_cached jsonb; v_result jsonb;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;
  select * into v_op from public.operators where auth_user_id=v_uid;
  if not found then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado.'),null);
  end if;
  if v_idem is not null then
    select response into v_cached from public.app_request_idempotency where idempotency_key=v_idem and rpc_name='end_operator_session';
    if v_cached is not null then return v_cached; end if;
  end if;
  select * into v_sess from public.operator_sessions where id=v_session_id and operator_id=v_op.id;
  if found and v_sess.status='active' then
    update public.operator_sessions set status='ended', ended_at=now(), end_reason=v_reason, updated_at=now() where id=v_sess.id;
    update public.operator_states set status='offline', effective_at=now(), revision=revision+1, updated_at=now() where operator_id=v_op.id and session_id=v_sess.id;
    insert into public.operator_status_history(operator_id,session_id,from_status,to_status,reason_code,source)
      values(v_op.id,v_sess.id,null,'offline',v_reason,'backend');
  end if;
  v_result := public._app_envelope(v_req_id,true,jsonb_build_object('session',jsonb_build_object('id',coalesce(v_session_id,v_sess.id),'status','ended')),null,null);
  if v_idem is not null then
    insert into public.app_request_idempotency(idempotency_key,rpc_name,operator_id,request_hash,response)
    values(v_idem,'end_operator_session',v_op.id,md5(coalesce(v_session_id::text,'')||'|'||v_reason),v_result) on conflict do nothing;
  end if;
  return v_result;
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."get_current_app_release_note"() RETURNS TABLE("id" "uuid", "app_release_id" "uuid", "version_number" "text", "title" "text", "summary" "text", "content" "text", "published_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with current_note as (
    select n.id, n.app_release_id, n.version_number, n.title, n.summary, n.content, n.published_at
    from public.app_release_notes n
    join public.app_releases r on r.id = n.app_release_id
    where n.status = 'published'
      and r.status = 'released'
      and r.is_current = true
    order by r.released_at desc nulls last, n.published_at desc nulls last
    limit 1
  )
  select cn.id, cn.app_release_id, cn.version_number, cn.title, cn.summary, cn.content, cn.published_at
  from current_note cn
  where public.current_operator_id() is not null
    and not exists (
      select 1
      from public.app_release_note_acknowledgements a
      where a.note_id = cn.id
        and a.operator_id = public.current_operator_id()
        and a.acknowledged_at is not null
    );
$$;




CREATE OR REPLACE FUNCTION "public"."get_my_operator_display_name_status"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator public.operators%rowtype;
  v_last_applied_at timestamptz;
  v_next_change_at timestamptz;
  v_review public.operator_display_name_requests%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false,
      'server_now', v_now,
      'data', null,
      'error', jsonb_build_object(
        'code', 'NOT_AUTHENTICATED',
        'message', 'Sessao autenticada obrigatoria.',
        'retryable', false
      )
    );
  end if;

  select * into v_operator
  from public.operators
  where auth_user_id = v_auth_user_id;

  if v_operator.id is null then
    return jsonb_build_object(
      'success', false,
      'server_now', v_now,
      'data', null,
      'error', jsonb_build_object(
        'code', 'OPERATOR_NOT_FOUND',
        'message', 'Operador nao encontrado para esta sessao.',
        'retryable', false
      )
    );
  end if;

  select max(request_row.applied_at) into v_last_applied_at
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.applied_at is not null;

  v_next_change_at := case
    when v_last_applied_at is null then null
    else v_last_applied_at + interval '15 days'
  end;

  -- A decisao pendente ou mais recente e a unica informacao de moderacao
  -- devolvida ao App. O termo que causou o bloqueio nunca sai do servidor.
  select * into v_review
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.review_status in ('pending', 'approved', 'rejected')
  order by coalesce(request_row.reviewed_at, request_row.occurred_at) desc, request_row.id desc
  limit 1;

  return jsonb_build_object(
    'success', true,
    'server_now', v_now,
    'data', jsonb_build_object(
      'display_name', v_operator.display_name,
      'next_change_at', v_next_change_at,
      'can_change_now', coalesce(v_next_change_at <= v_now, true),
      'review', case
        when v_review.id is null then null
        else jsonb_build_object(
          'request_id', v_review.id,
          'requested_name', v_review.requested_name,
          'status', v_review.review_status,
          'reviewed_at', v_review.reviewed_at,
          'message', case v_review.review_status
            when 'pending' then 'Sua solicitacao de nome esta em analise.'
            when 'approved' then 'Sua solicitacao de nome foi aprovada.'
            else 'Sua solicitacao de nome foi negada pelo Administrador.'
          end,
          'reason', case
            when v_review.review_status in ('approved', 'rejected') then v_review.review_reason
            else null
          end
        )
      end
    ),
    'error', null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."get_my_playlist_requests"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_uid uuid := auth.uid();
  v_operator_id uuid;
  v_request_id uuid := gen_random_uuid();
  v_request_id_text text;
  v_limit integer := 20;
  v_rows jsonb := '[]'::jsonb;
  v_submission jsonb;
  v_principal_playlist_id uuid;
  v_principal_revision bigint;
  v_blocking_request_id uuid;
  v_blocked_reason text;
begin
  if p_request is null or pg_catalog.jsonb_typeof(p_request) <> 'object' then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'request_id', v_request_id,
      'server_now', pg_catalog.now(),
      'data', null,
      'error', pg_catalog.jsonb_build_object('code', 'INVALID_REQUEST')
    );
  end if;

  v_request_id_text := nullif(p_request->>'request_id', '');
  if v_request_id_text is not null then
    v_request_id := private.try_uuid(v_request_id_text);
    if v_request_id is null then
      return pg_catalog.jsonb_build_object(
        'success', false,
        'request_id', null,
        'server_now', pg_catalog.now(),
        'data', null,
        'error', pg_catalog.jsonb_build_object('code', 'INVALID_UUID', 'field', 'request_id')
      );
    end if;
  end if;

  if p_request ? 'limit' then
    if coalesce(p_request->>'limit', '') !~ '^[0-9]+$' then
      return pg_catalog.jsonb_build_object(
        'success', false,
        'request_id', v_request_id,
        'server_now', pg_catalog.now(),
        'data', null,
        'error', pg_catalog.jsonb_build_object('code', 'INVALID_LIMIT')
      );
    end if;
    v_limit := least(greatest((p_request->>'limit')::integer, 1), 100);
  end if;

  if v_uid is null then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'request_id', v_request_id,
      'server_now', pg_catalog.now(),
      'data', null,
      'error', pg_catalog.jsonb_build_object('code', 'FORBIDDEN')
    );
  end if;

  select operator_row.id
    into v_operator_id
    from public.operators as operator_row
   where operator_row.auth_user_id = v_uid
     and operator_row.active is true;

  if v_operator_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'request_id', v_request_id,
      'server_now', pg_catalog.now(),
      'data', null,
      'error', pg_catalog.jsonb_build_object('code', 'FORBIDDEN')
    );
  end if;

  select playlist_row.id, playlist_row.revision
    into v_principal_playlist_id, v_principal_revision
    from public.playlists as playlist_row
   where playlist_row.created_by_operator_id = v_operator_id
     and playlist_row.type = 'principal'
   limit 1;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', request_row.id,
        'playlist_id', request_row.playlist_id,
        'source_url', request_row.source_url,
        'status', request_row.status,
        'lifecycle_status', request_row.lifecycle_status,
        'created_at', request_row.created_at,
        'updated_at', request_row.updated_at,
        'rejection_reason', case when request_row.lifecycle_status = 'rejected'
          then request_row.rejection_reason else null end,
        'failure_message', case when request_row.lifecycle_status = 'failed'
          then 'Nao foi possivel concluir o processamento. Voce pode enviar novamente.' else null end
      ) order by request_row.created_at desc, request_row.id desc
    ),
    '[]'::jsonb
  )
    into v_rows
    from (
      select
        history_row.*,
        case
          when history_row.status = 'pending' then 'awaiting_approval'
          when history_row.status = 'rejected' then 'rejected'
          when history_row.status = 'approved' and job.status in ('queued', 'running') then 'in_progress'
          when history_row.status = 'approved' and job.status = 'done' then 'completed'
          when history_row.status = 'approved' and job.status in ('partial', 'error') then 'failed'
          when history_row.status = 'approved' and job.id is null and playlist_row.import_status = 'success' then 'completed'
          when history_row.status = 'approved' and job.id is null and playlist_row.import_status = 'failed' then 'failed'
          when history_row.status = 'approved' then 'in_progress'
          else 'awaiting_approval'
        end as lifecycle_status
      from public.playlist_requests as history_row
      join public.playlists as playlist_row on playlist_row.id = history_row.playlist_id
      left join public.download_jobs as job on job.id = history_row.download_job_id
      where history_row.operator_id = v_operator_id
      order by history_row.created_at desc, history_row.id desc
      limit v_limit
    ) as request_row;

  select blocking.id, blocking.lifecycle_status
    into v_blocking_request_id, v_blocked_reason
    from (
      select
        request_row.id,
        request_row.created_at,
        case
          when request_row.status = 'pending' then 'awaiting_approval'
          when request_row.status = 'approved' and job.status in ('queued', 'running') then 'in_progress'
          when request_row.status = 'approved' and job.id is null
            and playlist_row.import_status in ('not_started', 'processing') then 'in_progress'
          else null
        end as lifecycle_status
      from public.playlist_requests as request_row
      join public.playlists as playlist_row on playlist_row.id = request_row.playlist_id
      left join public.download_jobs as job on job.id = request_row.download_job_id
      where request_row.operator_id = v_operator_id
        and playlist_row.type = 'principal'
    ) as blocking
   where blocking.lifecycle_status is not null
   order by blocking.created_at desc, blocking.id desc
   limit 1;

  v_submission := pg_catalog.jsonb_build_object(
    'allowed', v_blocking_request_id is null,
    'blocked_reason', v_blocked_reason,
    'blocking_request_id', v_blocking_request_id,
    'playlist_id', v_principal_playlist_id,
    'expected_revision', v_principal_revision
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'request_id', v_request_id,
    'server_now', pg_catalog.now(),
    'data', pg_catalog.jsonb_build_object(
      'requests', v_rows,
      'submission', v_submission
    ),
    'error', null
  );
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."get_my_playlists"("p_request" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid:=auth.uid(); v_req text:=p_request->>'request_id';
  v_op public.operators%rowtype; v_rows jsonb; v_sec integer;
begin
  select * into v_op from public.operators where auth_user_id=v_uid and active is true;
  if v_uid is null or not found then return public._app_envelope(v_req,false,null,jsonb_build_object('code','FORBIDDEN'),null); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'type',p.type,'name',p.name,'status',p.status,'approval_status',p.approval_status,'revision',p.revision,
    'capabilities',private.operator_playlist_capabilities(p.type,p.status)) order by p.type,p.created_at),'[]'::jsonb)
    into v_rows from public.playlists p where p.created_by_operator_id=v_op.id;
  select count(*) into v_sec from public.playlists where created_by_operator_id=v_op.id and type='secondary' and status<>'archived' and approval_status<>'rejected';
  return public._app_envelope(v_req,true,jsonb_build_object(
    'playlists',v_rows,
    'capabilities',jsonb_build_object('can_create_secondary',v_sec<2,'can_submit_principal',true),
    'secondary_count',v_sec,'secondary_limit',2,'principal_track_limit',170,'track_duration_limit_seconds',960
  ),null,jsonb_build_object('secondary_count',v_sec,'secondary_limit',2,'principal_track_limit',170,'track_duration_limit_seconds',960));
end;
$$;




CREATE OR REPLACE FUNCTION "public"."get_playlist_tracks"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req text := p_request->>'request_id';
  v_pid uuid := private.try_uuid(nullif(p_request->>'playlist_id', ''));
  v_op public.operators%rowtype;
  v_pl public.playlists%rowtype;
  v_rows jsonb;
begin
  select *
    into v_op
    from public.operators
   where auth_user_id = v_uid
     and active is true;

  if v_uid is null or not found then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'FORBIDDEN'),
      null
    );
  end if;

  if v_pid is null then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'INVALID_UUID', 'field', 'playlist_id'),
      null
    );
  end if;

  select *
    into v_pl
    from public.playlists
   where id = v_pid
     and created_by_operator_id = v_op.id;

  if not found then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'PLAYLIST_NOT_ALLOWED'),
      null
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', pt.id,
        'playlist_track_id', pt.id,
        'title', t.title,
        'artist', t.artist,
        'duration_ms', t.duration_ms,
        'position', pt.position,
        'public_url', t.metadata->>'public_url',
        'status', t.status,
        'updated_at', t.updated_at
      )
      order by pt.position
    ),
    '[]'::jsonb
  )
    into v_rows
    from public.playlist_tracks pt
    join public.tracks t on t.id = pt.track_id
   where pt.playlist_id = v_pl.id
     and t.status = 'available';

  return public._app_envelope(
    v_req,
    true,
    jsonb_build_object(
      'playlist_id', v_pl.id,
      'playlist_revision', v_pl.revision,
      'tracks', v_rows
    ),
    null,
    null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.admin_users a
    where a.auth_user_id = auth.uid() and a.active = true
  );
$$;




CREATE OR REPLACE FUNCTION "public"."is_release_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.admin_users a
    where a.auth_user_id = auth.uid()
      and a.active = true
      and a.role in ('superadmin', 'release_manager')
  );
$$;




CREATE OR REPLACE FUNCTION "public"."is_superadmin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from public.admin_users a
    where a.auth_user_id = auth.uid() and a.active and a.role = 'superadmin'
  );
$$;




CREATE OR REPLACE FUNCTION "public"."keep_principal_tracks_during_import"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1
    from public.playlists p
    join public.download_jobs j on j.playlist_id = p.id
    where p.id = old.playlist_id
      and p.type = 'principal'
      and j.status in ('queued', 'running')
  ) then
    return null;
  end if;

  return old;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."manage_operator_playlist"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_response jsonb;
  v_uid uuid := auth.uid();
  v_operator_id uuid;
  v_playlist_id uuid;
  v_type text := pg_catalog.lower(coalesce(nullif(p_request->>'type', ''), 'principal'));
  v_url text := nullif(pg_catalog.btrim(p_request->>'url'), '');
  v_key uuid := private.try_uuid(nullif(p_request->>'idempotency_key', ''));
  v_request_id_raw text := nullif(p_request->>'request_id', '');
  v_request_id uuid := private.try_uuid(v_request_id_raw);
  v_request_id_text text := coalesce(v_request_id::text, gen_random_uuid()::text);
begin
  if pg_catalog.lower(coalesce(p_request->>'operation', '')) = 'submit'
     and v_uid is not null
     and v_key is not null
     and v_url is not null
     and v_type in ('principal', 'secondary')
     and (v_request_id_raw is null or v_request_id is not null)
  then
    select operator_row.id
      into v_operator_id
      from public.operators as operator_row
     where operator_row.auth_user_id = v_uid
       and operator_row.active is true;

    if v_operator_id is not null then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('operator-playlists:' || v_operator_id::text)
      );

      if exists (
        select 1
          from public.playlist_requests as request_row
         where request_row.operator_id = v_operator_id
           and request_row.idempotency_key = v_key
      ) then
        return public.manage_operator_playlist_impl(p_request);
      end if;

      if exists (
        select 1
          from public.playlists as playlist_row
          join public.download_jobs as job on job.playlist_id = playlist_row.id
         where playlist_row.created_by_operator_id = v_operator_id
           and playlist_row.type = v_type
           and job.status in ('queued', 'running')
      ) then
        return public._app_envelope(
          v_request_id_text,
          false,
          null,
          pg_catalog.jsonb_build_object('code', 'PLAYLIST_IMPORT_IN_PROGRESS'),
          null
        );
      end if;

      if exists (
        select 1
          from public.playlist_requests as request_row
          join public.playlists as playlist_row on playlist_row.id = request_row.playlist_id
         where request_row.operator_id = v_operator_id
           and playlist_row.type = v_type
           and request_row.status = 'pending'
      ) then
        return public._app_envelope(
          v_request_id_text,
          false,
          null,
          pg_catalog.jsonb_build_object('code', 'PLAYLIST_REQUEST_ALREADY_PENDING'),
          null
        );
      end if;
    end if;
  end if;

  v_response := public.manage_operator_playlist_impl(p_request);

  if pg_catalog.lower(coalesce(p_request->>'operation', '')) <> 'submit'
     or coalesce((v_response->>'success')::boolean, false) is not true
     or v_uid is null
     or v_key is null
     or v_url is null
  then
    return v_response;
  end if;

  if v_operator_id is null then
    select operator_row.id
      into v_operator_id
      from public.operators as operator_row
     where operator_row.auth_user_id = v_uid
       and operator_row.active is true;
  end if;

  if v_operator_id is null
     or exists (
       select 1
         from public.playlist_requests as request_row
        where request_row.idempotency_key = v_key
     )
  then
    return v_response;
  end if;

  select playlist_row.id
    into v_playlist_id
    from public.playlists as playlist_row
   where playlist_row.created_by_operator_id = v_operator_id
     and playlist_row.type = v_type
     and playlist_row.source_url = v_url
   order by playlist_row.submitted_at desc nulls last, playlist_row.created_at desc
   limit 1;

  if v_playlist_id is null then
    raise exception 'playlist_request_link_not_found';
  end if;

  insert into public.playlist_requests (
    operator_id,
    playlist_id,
    source_url,
    status,
    request_id,
    idempotency_key
  ) values (
    v_operator_id,
    v_playlist_id,
    v_url,
    'pending',
    v_request_id,
    v_key
  );

  return v_response;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."manage_operator_playlist_impl"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_uid uuid := auth.uid();
  v_request_id text := p_request->>'request_id';
  v_key_text text := nullif(p_request->>'idempotency_key','');
  v_key uuid;
  v_operation text := lower(coalesce(nullif(p_request->>'operation',''),''));
  v_hash text;
  v_op public.operators%rowtype;
  v_playlist public.playlists%rowtype;
  v_principal public.playlists%rowtype;
  v_cached public.app_request_idempotency%rowtype;
  v_playlist_text text := nullif(p_request->>'playlist_id','');
  v_playlist_id uuid;
  v_expected_text text := nullif(p_request->>'expected_revision','');
  v_expected bigint;
  v_name text := regexp_replace(btrim(coalesce(p_request->>'name','')), '\s+', ' ', 'g');
  v_url text := nullif(btrim(p_request->>'url'),'');
  v_type text;
  v_ids uuid[];
  v_track_ids uuid[];
  v_affected_uuid_ids uuid[];
  v_new_source_ids uuid[] := '{}'::uuid[];
  v_already_source_ids uuid[] := '{}'::uuid[];
  v_count integer := 0;
  v_secondary_count integer := 0;
  v_max_position integer := 0;
  v_storage_queued integer := 0;
  v_track_id uuid;
  v_changed boolean := false;
  v_response jsonb;
  v_event_payload jsonb;
  v_created jsonb := null;
  v_affected_ids jsonb := '[]'::jsonb;
  v_affected_revisions jsonb := '{}'::jsonb;
  v_removed_ids jsonb := '[]'::jsonb;
  v_added_ids jsonb := '[]'::jsonb;
  v_already_ids jsonb := '[]'::jsonb;
begin
  if v_uid is null then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','FORBIDDEN'),null);
  end if;
  select * into v_op from public.operators where auth_user_id=v_uid and active is true;
  if not found then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','FORBIDDEN'),null);
  end if;

  v_key := private.try_uuid(v_key_text);
  if v_key_text is null then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','IDEMPOTENCY_KEY_REQUIRED'),null);
  elsif v_key is null then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_UUID','field','idempotency_key'),null);
  end if;
  v_hash := md5((p_request - 'request_id')::text);

  select * into v_cached from public.app_request_idempotency
   where idempotency_key=v_key order by created_at limit 1;
  if found then
    if v_cached.rpc_name='manage_operator_playlist' and v_cached.operator_id=v_op.id and v_cached.request_hash=v_hash then
      return v_cached.response;
    end if;
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','IDEMPOTENCY_KEY_REUSED'),null);
  end if;

  if v_operation not in ('submit','create_secondary','rename','archive_secondary','add_tracks','remove_tracks','reorder_tracks') then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_OPERATION'),null);
  end if;
  if v_expected_text is not null then
    if v_expected_text !~ '^[0-9]+$' then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_REVISION'),null);
    end if;
    v_expected := v_expected_text::bigint;
  end if;

  perform pg_advisory_xact_lock(hashtext('operator-playlists:'||v_op.id::text));

  if v_operation='create_secondary' then
    if v_name='' then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_REQUIRED'),null); end if;
    if char_length(v_name)>80 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_TOO_LONG','max_length',80),null); end if;
    select count(*) into v_secondary_count from public.playlists
     where created_by_operator_id=v_op.id and type='secondary' and status<>'archived' and approval_status<>'rejected';
    if v_secondary_count>=2 then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','SECONDARY_LIMIT_REACHED','secondary_count',v_secondary_count,'secondary_limit',2),null);
    end if;
    insert into public.playlists(unit_id,name,type,status,approval_status,import_status,created_by_operator_id)
      values(v_op.unit_id,v_name,'secondary','active','draft','not_started',v_op.id)
      returning * into v_playlist;
    v_created := jsonb_build_object('id',v_playlist.id,'type',v_playlist.type,'name',v_playlist.name,'status',v_playlist.status,
      'approval_status',v_playlist.approval_status,'revision',v_playlist.revision,
      'capabilities',private.operator_playlist_capabilities(v_playlist.type,v_playlist.status));
    v_changed := true;

  elsif v_operation='submit' then
    v_type := lower(coalesce(nullif(p_request->>'type',''),'principal'));
    if v_type not in ('principal','secondary') then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_TYPE'),null); end if;
    if v_url is null or v_url !~* '^https?://' or length(v_url)>2048 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_URL'),null); end if;
    if v_url ~* '(youtube\.com|youtu\.be)'
       and (v_url !~* '[?&]list=[A-Za-z0-9_-]+' or v_url ~* '[?&]list=(RD|UL|LL|WL)') then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','URL_NOT_A_PLAYLIST'),null);
    end if;
    if v_name<>'' and char_length(v_name)>80 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_TOO_LONG','max_length',80),null); end if;
    if v_type='principal' then
      select * into v_playlist from public.playlists where created_by_operator_id=v_op.id and type='principal' for update;
      if found then
        if v_expected is null or v_expected<>v_playlist.revision then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_REVISION_CONFLICT','playlist_id',v_playlist.id,'expected_revision',v_expected,'current_revision',v_playlist.revision,'reload_required',true),null);
        end if;
        update public.playlists set source_url=v_url,name=case when v_name='' then name else v_name end,
          approval_status='pending',status='draft',submitted_at=now(),rejection_reason=null,revision=revision+1,updated_at=now()
          where id=v_playlist.id returning * into v_playlist;
      else
        insert into public.playlists(unit_id,name,type,status,approval_status,created_by_operator_id,source_url,submitted_at)
          values(v_op.unit_id,case when v_name='' then 'Playlist principal' else v_name end,'principal','draft','pending',v_op.id,v_url,now())
          returning * into v_playlist;
      end if;
    else
      select count(*) into v_secondary_count from public.playlists
       where created_by_operator_id=v_op.id and type='secondary' and status<>'archived' and approval_status<>'rejected';
      if v_secondary_count>=2 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','SECONDARY_LIMIT_REACHED','secondary_count',v_secondary_count,'secondary_limit',2),null); end if;
      insert into public.playlists(unit_id,name,type,status,approval_status,created_by_operator_id,source_url,submitted_at)
        values(v_op.unit_id,case when v_name='' then 'Playlist secundaria' else v_name end,'secondary','draft','pending',v_op.id,v_url,now())
        returning * into v_playlist;
      v_created := jsonb_build_object('id',v_playlist.id,'type',v_playlist.type,'name',v_playlist.name,'status',v_playlist.status,'approval_status',v_playlist.approval_status,'revision',v_playlist.revision,'capabilities',private.operator_playlist_capabilities(v_playlist.type,v_playlist.status));
    end if;
    v_changed := true;

  else
    v_playlist_id := private.try_uuid(v_playlist_text);
    if v_playlist_text is null then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;
    if v_playlist_id is null then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_UUID','field','playlist_id'),null); end if;
    select * into v_playlist from public.playlists where id=v_playlist_id and created_by_operator_id=v_op.id for update;
    if not found then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;
    if v_expected is null or v_expected<>v_playlist.revision then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_REVISION_CONFLICT','playlist_id',v_playlist.id,'expected_revision',v_expected,'current_revision',v_playlist.revision,'reload_required',true),null);
    end if;
    if v_playlist.status='archived' then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;

    if v_operation='rename' then
      if v_name='' then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_REQUIRED'),null); end if;
      if char_length(v_name)>80 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_TOO_LONG','max_length',80),null); end if;
      if v_playlist.name is distinct from v_name then
        update public.playlists set name=v_name,revision=revision+1,updated_at=now() where id=v_playlist.id returning * into v_playlist;
        v_changed := true;
      end if;

    elsif v_operation='archive_secondary' then
      if v_playlist.type<>'secondary' then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;
      update public.playlists set status='archived',revision=revision+1,updated_at=now() where id=v_playlist.id returning * into v_playlist;
      v_changed := true;

    else
      if v_operation='add_tracks' then
        if jsonb_typeof(p_request->'source_playlist_track_ids') is distinct from 'array' then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_REQUEST','field','source_playlist_track_ids'),null);
        end if;
        if exists(select 1 from jsonb_array_elements_text(p_request->'source_playlist_track_ids') x(value) where private.try_uuid(value) is null) then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_UUID','field','source_playlist_track_ids'),null);
        end if;
        select array_agg(value::uuid order by ord) into v_ids from jsonb_array_elements_text(p_request->'source_playlist_track_ids') with ordinality x(value,ord);
      else
        if jsonb_typeof(p_request->'playlist_track_ids') is distinct from 'array' then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_REQUEST','field','playlist_track_ids'),null);
        end if;
        if exists(select 1 from jsonb_array_elements_text(p_request->'playlist_track_ids') x(value) where private.try_uuid(value) is null) then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_UUID','field','playlist_track_ids'),null);
        end if;
        select array_agg(value::uuid order by ord) into v_ids from jsonb_array_elements_text(p_request->'playlist_track_ids') with ordinality x(value,ord);
      end if;
      if coalesce(cardinality(v_ids),0)=0 then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE'),null); end if;
      if cardinality(v_ids)<>(select count(distinct x) from unnest(v_ids) x) then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','DUPLICATE_TRACK_REFERENCE'),null); end if;

      if v_operation='add_tracks' then
        if v_playlist.type<>'secondary' then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;
        select * into v_principal from public.playlists where created_by_operator_id=v_op.id and type='principal' for update;
        if not found then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PRINCIPAL_NOT_FOUND'),null); end if;
        select count(*),array_agg(src.track_id order by src.track_id) into v_count,v_track_ids
          from public.playlist_tracks src join public.tracks t on t.id=src.track_id
         where src.playlist_id=v_principal.id and src.id=any(v_ids) and t.status='available';
        if v_count<>cardinality(v_ids) then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE'),null); end if;
        perform 1 from public.tracks where id=any(v_track_ids) order by id for share;
        select coalesce(array_agg(src.id order by a.ord),'{}'::uuid[]) into v_already_source_ids
          from unnest(v_ids) with ordinality a(id,ord)
          join public.playlist_tracks src on src.id=a.id
         where exists(select 1 from public.playlist_tracks d where d.playlist_id=v_playlist.id and d.track_id=src.track_id);
        select coalesce(array_agg(a.id order by a.ord),'{}'::uuid[]) into v_new_source_ids
          from unnest(v_ids) with ordinality a(id,ord) where not a.id=any(v_already_source_ids);
        select coalesce(max(position),-1) into v_max_position from public.playlist_tracks where playlist_id=v_playlist.id;
        if cardinality(v_new_source_ids)>0 then
          with source_rows as (
            select src.track_id,row_number() over(order by a.ord) rn
              from unnest(v_new_source_ids) with ordinality a(id,ord)
              join public.playlist_tracks src on src.id=a.id
          ), inserted as (
            insert into public.playlist_tracks(playlist_id,track_id,position,added_by_type,added_by_id)
              select v_playlist.id,s.track_id,v_max_position+s.rn,'operator',v_op.id from source_rows s
              returning id
          ) select coalesce(jsonb_agg(id),'[]'::jsonb) into v_added_ids from inserted;
          update public.playlists set revision=revision+1,updated_at=now() where id=v_playlist.id returning * into v_playlist;
          v_changed := true;
        end if;
        select coalesce(to_jsonb(v_already_source_ids),'[]'::jsonb) into v_already_ids;

      elsif v_operation='remove_tracks' then
        select count(*),array_agg(pt.track_id order by pt.track_id) into v_count,v_track_ids
          from public.playlist_tracks pt where pt.playlist_id=v_playlist.id and pt.id=any(v_ids);
        if v_count<>cardinality(v_ids) then return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE'),null); end if;
        perform 1 from public.tracks where id=any(v_track_ids) order by id for update;
        if v_playlist.type='principal' then
          select array_agg(distinct p.id order by p.id) into v_affected_uuid_ids
            from public.playlists p join public.playlist_tracks pt on pt.playlist_id=p.id
           where p.created_by_operator_id=v_op.id and pt.track_id=any(v_track_ids);
          perform 1 from public.playlists where id=any(v_affected_uuid_ids) order by id for update;
          with deleted as (
            delete from public.playlist_tracks pt using public.playlists p
             where p.id=pt.playlist_id and p.created_by_operator_id=v_op.id and pt.track_id=any(v_track_ids)
             returning pt.id
          ) select coalesce(jsonb_agg(id),'[]'::jsonb) into v_removed_ids from deleted;
          with updated as (
            update public.playlists set revision=revision+1,updated_at=now() where id=any(v_affected_uuid_ids) returning id,revision
          ) select coalesce(jsonb_agg(id),'[]'::jsonb),coalesce(jsonb_object_agg(id::text,revision),'{}'::jsonb)
              into v_affected_ids,v_affected_revisions from updated;
          select * into v_playlist from public.playlists where id=v_playlist.id;
          foreach v_track_id in array v_track_ids loop
            if not exists(select 1 from public.playlist_tracks where track_id=v_track_id) then
              update public.tracks set status='disabled',revision=revision+1,updated_at=now() where id=v_track_id;
              insert into public.storage_deletion_jobs(track_id,storage_object_key,status,next_attempt_at,last_error)
                select id,storage_object_key,'queued',now(),null from public.tracks where id=v_track_id
                on conflict(track_id) do update set status='queued',next_attempt_at=now(),last_error=null,locked_at=null,updated_at=now();
              v_storage_queued := v_storage_queued+1;
            end if;
          end loop;
        else
          with deleted as (
            delete from public.playlist_tracks where playlist_id=v_playlist.id and id=any(v_ids) returning id
          ) select coalesce(jsonb_agg(id),'[]'::jsonb) into v_removed_ids from deleted;
          update public.playlists set revision=revision+1,updated_at=now() where id=v_playlist.id returning * into v_playlist;
        end if;
        v_changed := true;

      else
        select count(*) into v_count from public.playlist_tracks pt join public.tracks t on t.id=pt.track_id
         where pt.playlist_id=v_playlist.id and pt.id=any(v_ids) and t.status='available';
        if v_count<>cardinality(v_ids) or v_count<>(select count(*) from public.playlist_tracks where playlist_id=v_playlist.id) then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE'),null);
        end if;
        update public.playlist_tracks set position=position+1000000 where playlist_id=v_playlist.id;
        update public.playlist_tracks pt set position=a.ord-1 from unnest(v_ids) with ordinality a(id,ord)
         where pt.id=a.id and pt.playlist_id=v_playlist.id;
        update public.playlists set revision=revision+1,updated_at=now() where id=v_playlist.id returning * into v_playlist;
        v_changed := true;
      end if;
    end if;
  end if;

  if v_affected_ids='[]'::jsonb then
    v_affected_ids:=jsonb_build_array(v_playlist.id);
    v_affected_revisions:=jsonb_build_object(v_playlist.id::text,v_playlist.revision);
  end if;
  select count(*) into v_secondary_count from public.playlists
   where created_by_operator_id=v_op.id and type='secondary' and status<>'archived' and approval_status<>'rejected';

  v_event_payload:=jsonb_build_object('operation',v_operation,'playlist_id',v_playlist.id,'revision',v_playlist.revision,
    'affected_playlist_ids',v_affected_ids,'changed',v_changed,'storage_cleanup_queued_count',v_storage_queued);
  insert into public.operational_events(event_type,operator_id,unit_id,related_entity_type,related_entity_id,idempotency_key,payload)
    values('playlist_changed',v_op.id,v_op.unit_id,'playlist',v_playlist.id,v_key,v_event_payload);

  v_response:=public._app_envelope(v_request_id,true,jsonb_build_object(
    'operation',v_operation,'playlist_id',v_playlist.id,'revision',v_playlist.revision,
    'affected_playlist_ids',v_affected_ids,'affected_playlist_revisions',v_affected_revisions,
    'created_playlist',v_created,'removed_playlist_track_ids',v_removed_ids,
    'added_playlist_track_ids',v_added_ids,'already_present_source_ids',v_already_ids,
    'secondary_count',v_secondary_count,'secondary_limit',2,
    'storage_cleanup_queued_count',v_storage_queued
  ),null,jsonb_build_object('code','PLAYLIST_CHANGED'));
  insert into public.app_request_idempotency(idempotency_key,rpc_name,operator_id,request_hash,response)
    values(v_key,'manage_operator_playlist',v_op.id,v_hash,v_response);
  return v_response;
exception
  when unique_violation then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','IDEMPOTENCY_KEY_REUSED'),null);
  when check_violation then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE'),null);
  when others then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$_$;




CREATE OR REPLACE FUNCTION "public"."operator_challenge_answer"("p_log_id" "uuid", "p_answer" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_rules jsonb;
  v_errors integer;
  v_seconds integer;
  v_correct boolean;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null
     or v_log.status not in ('pending', 'displayed')
     or v_log.expires_at <= now() then
    raise exception 'desafio_indisponivel';
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  v_correct := lower(coalesce(p_answer->>'value', ''))
    = lower(coalesce(v_challenge.answer_definition->>'correct', ''));

  update public.challenge_logs
  set status = case when v_correct then 'answered' else 'failed' end,
      answer = p_answer,
      answer_result = case when v_correct then 'correct' else 'incorrect' end,
      answered_at = now(),
      closed_at = now()
  where id = v_log.id;

  if not v_correct then
    select count(*) into v_errors
    from public.challenge_logs
    where operator_id = v_op.id
      and session_id = v_log.session_id
      and status = 'failed';

    v_rules := private.challenge_rules(v_op.unit_id);
    v_seconds := coalesce(
      (
        v_rules->'error_block_seconds'->>
        greatest(
          least(v_errors, jsonb_array_length(v_rules->'error_block_seconds')) - 1,
          0
        )
      )::integer,
      300
    );

    insert into public.operator_blocks(
      operator_id,
      session_id,
      challenge_log_id,
      status,
      reason_code,
      blocked_until
    )
    values (
      v_op.id,
      v_log.session_id,
      v_log.id,
      'active',
      'challenge_incorrect',
      now() + make_interval(secs => v_seconds)
    );
  end if;

  return private.challenge_payload(v_op.id, v_log.session_id);
end
$$;




COMMENT ON FUNCTION "public"."operator_challenge_answer"("p_log_id" "uuid", "p_answer" "jsonb") IS 'Validates a challenge answer and creates a progressive block for an incorrect response.';



CREATE OR REPLACE FUNCTION "public"."operator_challenge_answer_v2"("p_log_id" "uuid", "p_answer" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_selected_option_id text;
  v_selected_option_text text;
  v_correct_option_id text;
  v_correct_option_text text;
  v_feedback jsonb;
  v_next_snapshot jsonb;
  v_response jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;
  if v_op.id is null then raise exception 'operador_invalido'; end if;

  if coalesce(jsonb_typeof(p_answer), '') <> 'object'
     or not (p_answer ? 'option_id')
     or coalesce(jsonb_typeof(p_answer->'option_id'), '') <> 'string'
     or nullif(btrim(p_answer->>'option_id'), '') is null
     or (select count(*) from jsonb_object_keys(p_answer)) <> 1 then
    raise exception 'resposta_invalida';
  end if;
  v_selected_option_id := p_answer->>'option_id';

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null then raise exception 'desafio_indisponivel'; end if;

  -- A v2 retry returns the exact response persisted by its first accepted call.
  if v_log.status in ('answered', 'failed') then
    v_response := v_log.answer_feedback;
    if jsonb_typeof(v_response) = 'object'
       and v_response->'answer_feedback'->>'selected_option_id' = v_selected_option_id then
      return v_response;
    end if;
    raise exception 'desafio_ja_finalizado';
  end if;

  if v_log.status not in ('pending', 'displayed') or v_log.expires_at <= now() then
    raise exception 'desafio_indisponivel';
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;
  if v_challenge.id is null
     or not private.challenge_answer_definition_is_valid(v_challenge.answer_definition) then
    raise exception 'desafio_configuracao_invalida';
  end if;

  select option.value->>'text' into v_selected_option_text
  from jsonb_array_elements(v_challenge.answer_definition->'options') as option(value)
  where option.value->>'id' = v_selected_option_id;
  if v_selected_option_text is null then raise exception 'resposta_invalida'; end if;

  v_correct_option_id := v_challenge.answer_definition->>'correct_option_id';
  select option.value->>'text' into v_correct_option_text
  from jsonb_array_elements(v_challenge.answer_definition->'options') as option(value)
  where option.value->>'id' = v_correct_option_id;

  -- Delegate the write, penalty and next-state rules to the existing RPC.
  -- This is deliberately the legacy A-D value it already consumes.
  v_next_snapshot := public.operator_challenge_answer(
    p_log_id,
    jsonb_build_object('value', upper(right(v_selected_option_id, 1)))
  );

  select * into v_log
  from public.challenge_logs
  where id = p_log_id;

  v_feedback := jsonb_build_object(
    'result', case when v_log.answer_result = 'correct' then 'correct' else 'incorrect' end,
    'is_correct', v_log.answer_result = 'correct',
    'selected_option_id', v_selected_option_id,
    'correct_option_id', v_correct_option_id,
    'correct_option_text', v_correct_option_text,
    'answered_at', v_log.answered_at
  );
  v_response := jsonb_build_object(
    'schema_version', 2,
    'answer_feedback', v_feedback,
    'next_snapshot', v_next_snapshot
  );

  update public.challenge_logs
  set answer_feedback = v_response
  where id = p_log_id;

  return v_response;
end
$$;




COMMENT ON FUNCTION "public"."operator_challenge_answer_v2"("p_log_id" "uuid", "p_answer" "jsonb") IS 'Version 2 challenge answer contract. Accepts only {option_id}; returns official post-answer feedback and the unchanged legacy next snapshot.';



CREATE OR REPLACE FUNCTION "public"."operator_challenge_displayed"("p_log_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_rules jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null then
    raise exception 'desafio_indisponivel';
  end if;

  if v_log.status = 'pending' and v_log.expires_at > now() then
    v_rules := private.challenge_rules(v_op.unit_id);

    update public.challenge_logs
    set status = 'displayed',
        displayed_at = now(),
        expires_at = now() + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
    where id = v_log.id
    returning * into v_log;
  end if;

  return private.challenge_payload(v_op.id, v_log.session_id);
end
$$;




COMMENT ON FUNCTION "public"."operator_challenge_displayed"("p_log_id" "uuid") IS 'Confirms first display and starts the full configured response window exactly once.';



CREATE OR REPLACE FUNCTION "public"."operator_challenge_resume_idle"("p_session_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
  v_idle_log public.challenge_logs%rowtype;
  v_previous public.operator_states%rowtype;
  v_current public.operator_states%rowtype;
  v_shift_info jsonb;
  v_target_status text;
  v_status_operacional text;
  v_payload jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select * into v_session
  from public.operator_sessions
  where id = p_session_id
    and operator_id = v_op.id
    and status = 'active'
    and expires_at > now();

  if v_session.id is null then
    raise exception 'sessao_invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  select * into v_idle_log
  from public.challenge_logs
  where operator_id = v_op.id
    and session_id = v_session.id
    and status = 'idle'
  order by created_at desc
  limit 1
  for update;

  -- Repeated clicks/calls are read-only after the first successful acknowledgement.
  if v_idle_log.id is null then
    v_payload := public.operator_challenge_state(
      jsonb_build_object('session_id', v_session.id)
    );

    select * into v_current
    from public.operator_states
    where operator_id = v_op.id;

    v_status_operacional := case v_current.status
      when 'active' then 'ativo'
      when 'idle' then 'ocioso'
      when 'in_call' then 'em_atendimento'
      when 'blocked' then 'bloqueado'
      when 'outside_shift' then 'fora_do_turno'
      else 'offline'
    end;

    return v_payload || jsonb_build_object(
      'status_operacional', v_status_operacional,
      'operator_state', jsonb_build_object(
        'status', v_current.status,
        'revision', v_current.revision,
        'effective_at', v_current.effective_at,
        'call_active', coalesce(v_current.call_active, false)
      )
    );
  end if;

  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where id = v_idle_log.id;

  select * into v_previous
  from public.operator_states
  where operator_id = v_op.id;

  v_shift_info := public._app_shift_info(
    coalesce(v_session.shift_id, v_op.default_shift_id)
  );

  v_target_status := case
    when coalesce(v_previous.call_active, false) then 'in_call'
    when exists (
      select 1
      from public.operator_blocks b
      where b.operator_id = v_op.id
        and b.status = 'active'
        and (b.blocked_until is null or b.blocked_until > now())
    ) then 'blocked'
    when not coalesce((v_shift_info->>'in_shift')::boolean, true) then 'outside_shift'
    else 'active'
  end;

  v_current := private.set_challenge_operator_state(
    v_op.id,
    v_session.id,
    v_target_status,
    'challenge_idle_return'
  );

  v_payload := public.operator_challenge_state(
    jsonb_build_object('session_id', v_session.id)
  );

  v_status_operacional := case v_current.status
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else 'offline'
  end;

  return v_payload || jsonb_build_object(
    'status_operacional', v_status_operacional,
    'operator_state', jsonb_build_object(
      'status', v_current.status,
      'revision', v_current.revision,
      'effective_at', v_current.effective_at,
      'call_active', coalesce(v_current.call_active, false)
    )
  );
end
$$;




COMMENT ON FUNCTION "public"."operator_challenge_resume_idle"("p_session_id" "uuid") IS 'Acknowledges one idle challenge once; repeated calls are idempotent and cannot toggle state.';



CREATE OR REPLACE FUNCTION "public"."operator_challenge_session_ended"("p_session_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op uuid;
begin
  select id into v_op
  from public.operators
  where auth_user_id = auth.uid();

  if v_op is null or not exists (
    select 1
    from public.operator_sessions
    where id = p_session_id and operator_id = v_op
  ) then
    raise exception 'sessao_invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op::text));

  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where operator_id = v_op
    and session_id = p_session_id
    and status in ('scheduled', 'idle');

  update public.challenge_logs
  set status = 'abandoned',
      abandoned_at = coalesce(abandoned_at, now()),
      closed_at = null
  where operator_id = v_op
    and session_id = p_session_id
    and status in ('pending', 'displayed', 'paused');
end
$$;




CREATE OR REPLACE FUNCTION "public"."operator_challenge_state"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_op public.operators%rowtype;
  v_session uuid := nullif(p_request->>'session_id', '')::uuid;
  v_rules jsonb;
  v_log public.challenge_logs%rowtype;
  v_expired_log public.challenge_logs%rowtype;
  v_state public.operator_states%rowtype;
  v_shift_info jsonb;
  v_target_status text;
  v_delay integer;
  v_candidate uuid;
  v_scheduled_for timestamptz;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  if not exists (
    select 1
    from public.operator_sessions
    where id = v_session
      and operator_id = v_op.id
      and status = 'active'
      and expires_at > now()
  ) then
    raise exception 'sessao_invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  -- A challenge from another login must never contaminate this session.
  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where operator_id = v_op.id
    and session_id is distinct from v_session
    and status in ('scheduled', 'idle');

  update public.challenge_logs
  set status = 'abandoned',
      abandoned_at = coalesce(abandoned_at, now()),
      closed_at = null
  where operator_id = v_op.id
    and session_id is distinct from v_session
    and status in ('pending', 'displayed', 'paused');

  select * into v_log
  from public.challenge_logs
  where operator_id = v_op.id
    and status = 'abandoned'
    and closed_at is null
  order by abandoned_at desc
  limit 1;

  if v_log.id is not null then
    v_rules := private.challenge_rules(v_op.unit_id);

    insert into public.operator_blocks(
      operator_id,
      session_id,
      challenge_log_id,
      status,
      reason_code,
      blocked_until
    )
    values (
      v_op.id,
      v_session,
      v_log.id,
      'active',
      'challenge_abandoned',
      now() + make_interval(
        secs => coalesce((v_rules->>'abandon_block_seconds')::integer, 300)
      )
    );

    update public.challenge_logs
    set closed_at = now()
    where id = v_log.id;

    perform private.set_challenge_operator_state(
      v_op.id,
      v_session,
      'blocked',
      'challenge_abandoned'
    );

    return private.challenge_payload(v_op.id, v_session);
  end if;

  select * into v_log
  from private.current_operator_challenge(v_op.id, v_session);

  -- Repair only a stale idle state. Other operational states stay authoritative.
  if v_log.id is null then
    select * into v_state
    from public.operator_states
    where operator_id = v_op.id;

    if v_state.status = 'idle' then
      v_shift_info := public._app_shift_info(
        coalesce(
          (select shift_id from public.operator_sessions where id = v_session),
          v_op.default_shift_id
        )
      );

      v_target_status := case
        when coalesce(v_state.call_active, false) then 'in_call'
        when exists (
          select 1
          from public.operator_blocks b
          where b.operator_id = v_op.id
            and b.status = 'active'
            and (b.blocked_until is null or b.blocked_until > now())
        ) then 'blocked'
        when not coalesce((v_shift_info->>'in_shift')::boolean, true) then 'outside_shift'
        else 'active'
      end;

      perform private.set_challenge_operator_state(
        v_op.id,
        v_session,
        v_target_status,
        'challenge_stale_idle_repaired'
      );
    end if;

    v_rules := private.challenge_rules(v_op.unit_id);
    v_delay := floor(
      random() * (
        greatest(
          (v_rules->>'max_interval_seconds')::integer,
          (v_rules->>'min_interval_seconds')::integer
        ) - (v_rules->>'min_interval_seconds')::integer + 1
      )
    )::integer + (v_rules->>'min_interval_seconds')::integer;

    select id into v_candidate
    from public.challenges c
    where c.status = 'active'
      and (c.unit_id = v_op.unit_id or c.unit_id is null)
      and not exists (
        select 1
        from public.challenge_logs l
        where l.operator_id = v_op.id
          and l.session_id = v_session
          and l.challenge_id = c.id
      )
    order by random()
    limit 1;

    if v_candidate is null then
      select id into v_candidate
      from public.challenges
      where status = 'active'
        and (unit_id = v_op.unit_id or unit_id is null)
      order by random()
      limit 1;
    end if;

    if v_candidate is not null then
      v_scheduled_for := private.challenge_schedule_at(v_rules, v_delay, now());

      insert into public.challenge_logs(
        challenge_id,
        operator_id,
        session_id,
        status,
        scheduled_for,
        pending_at,
        expires_at
      )
      values (
        v_candidate,
        v_op.id,
        v_session,
        'scheduled',
        v_scheduled_for,
        now(),
        v_scheduled_for + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
      );
    end if;
  elsif v_log.status = 'idle' then
    perform private.set_challenge_operator_state(
      v_op.id,
      v_session,
      'idle',
      'challenge_expired'
    );
  else
    v_rules := private.challenge_rules(v_op.unit_id);

    update public.challenge_logs
    set status = 'pending',
        displayed_at = null,
        expires_at = now() + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
    where id = v_log.id
      and status = 'scheduled'
      and scheduled_for <= now();

    update public.challenge_logs
    set status = 'idle',
        closed_at = now()
    where id = v_log.id
      and status in ('pending', 'displayed')
      and expires_at <= now()
    returning * into v_expired_log;

    if v_expired_log.id is not null then
      perform private.set_challenge_operator_state(
        v_op.id,
        v_session,
        'idle',
        'challenge_expired'
      );
    end if;
  end if;

  return private.challenge_payload(v_op.id, v_session);
end
$$;




COMMENT ON FUNCTION "public"."operator_challenge_state"("p_request" "jsonb") IS 'Returns and mutates challenge state only for the authenticated active operator session.';



CREATE OR REPLACE FUNCTION "public"."operator_operational_event"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_event text := p_request->>'event';
  v_event_id uuid := nullif(p_request->>'event_id', '')::uuid;
  v_source text := coalesce(nullif(p_request->>'source', ''), 'local');
  v_occurred_at timestamptz := coalesce(nullif(p_request->>'occurred_at', '')::timestamptz, now());
  v_metadata jsonb := coalesce(p_request->'metadata', '{}'::jsonb);
  v_session_id uuid := nullif(p_request->>'session_id', '')::uuid;
  v_device_id uuid := nullif(p_request->>'device_id', '')::uuid;
  v_op public.operators%rowtype;
  v_sess public.operator_sessions%rowtype;
  v_state public.operator_states%rowtype;
  v_previous_status text;
  v_target_status text;
  v_shift_info jsonb;
  v_blocked boolean;
  v_in_shift boolean;
  v_result text := 'applied';
  v_payload jsonb;
  v_response jsonb;
  v_changed boolean := false;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;

  if v_event not in ('call_started', 'call_finished') then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_EVENT','message','Evento operacional invalido.'),null);
  end if;

  if v_event_id is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','EVENT_ID_REQUIRED','message','event_id e obrigatorio.'),null);
  end if;

  select * into v_op
  from public.operators
  where auth_user_id = v_uid;

  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;

  if exists (
    select 1
    from public.app_request_idempotency
    where idempotency_key = v_event_id
      and rpc_name = 'operator_operational_event'
  ) then
    select * into v_sess
    from public.operator_sessions
    where operator_id = v_op.id
      and status = 'active'
    order by started_at desc
    limit 1;

    v_payload := private.operator_runtime_payload(v_op.id, coalesce(v_session_id, v_sess.id), 'duplicate');
    return public._app_envelope(v_req_id,true,v_payload,null,jsonb_build_object('duplicate',true));
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  if v_session_id is not null then
    select * into v_sess
    from public.operator_sessions
    where id = v_session_id
      and operator_id = v_op.id;
  else
    select * into v_sess
    from public.operator_sessions
    where operator_id = v_op.id
      and status = 'active'
      and expires_at > now()
    order by started_at desc
    limit 1;
  end if;

  if v_sess.id is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_NOT_FOUND','message','Sessao ativa nao encontrada.'),null);
  end if;

  if v_sess.status <> 'active' or v_sess.expires_at <= now() then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_NOT_ACTIVE','message','Sessao nao esta ativa.'),null);
  end if;

  select * into v_state
  from public.operator_states
  where operator_id = v_op.id
  for update;

  if v_state.operator_id is null then
    insert into public.operator_states(
      operator_id, session_id, status, call_active, effective_at, revision, updated_at
    )
    values (
      v_op.id, v_sess.id, 'active', false, now(), 1, now()
    )
    returning * into v_state;
  end if;

  if v_event = 'call_started' then
    if coalesce(v_state.call_active, false) or v_state.status = 'in_call' then
      v_result := 'no_change';
    else
      v_previous_status := v_state.status;

      update public.operator_states
      set status = 'in_call',
          activity = 'call',
          reason_code = 'call_active',
          session_id = v_sess.id,
          call_active = true,
          call_source = v_source,
          call_started_at = v_occurred_at,
          call_event_id = v_event_id,
          call_previous_status = v_previous_status,
          effective_at = v_occurred_at,
          revision = revision + 1,
          updated_at = now()
      where operator_id = v_op.id
      returning * into v_state;

      insert into public.operator_status_history(
        operator_id, session_id, from_status, to_status, reason_code, source, occurred_at, state_revision, metadata
      )
      values (
        v_op.id, v_sess.id, v_previous_status, 'in_call', 'call_started', v_source, v_occurred_at, v_state.revision,
        jsonb_build_object('event_id', v_event_id, 'metadata', v_metadata)
      );

      update public.challenge_logs
      set status = 'paused',
          paused_at = coalesce(paused_at, v_occurred_at),
          pause_reason = 'call_active',
          revision = revision + 1
      where operator_id = v_op.id
        and status in ('pending', 'displayed')
        and (session_id is null or session_id = v_sess.id);

      insert into public.operational_events(
        event_type, operator_id, session_id, device_id, unit_id, idempotency_key,
        client_sent_at, occurred_at, payload
      )
      values (
        'call.started', v_op.id, v_sess.id, v_device_id, v_op.unit_id, v_event_id,
        v_occurred_at, v_occurred_at,
        jsonb_build_object('event', v_event, 'source', v_source, 'metadata', v_metadata)
      )
      on conflict do nothing;

      v_changed := true;
    end if;
  else
    if not coalesce(v_state.call_active, false) and v_state.status <> 'in_call' then
      v_result := 'no_change';
    else
      v_previous_status := v_state.status;
      v_blocked := exists (
        select 1
        from public.operator_blocks b
        where b.operator_id = v_op.id
          and b.status = 'active'
          and (b.blocked_until is null or b.blocked_until > now())
      );
      v_shift_info := public._app_shift_info(coalesce(v_sess.shift_id, v_op.default_shift_id));
      v_in_shift := coalesce((v_shift_info->>'in_shift')::boolean, true);
      v_target_status := case
        when v_blocked then 'blocked'
        when not v_in_shift then 'outside_shift'
        when v_state.call_previous_status = 'idle' then 'idle'
        else 'active'
      end;

      update public.challenge_logs cl
      set status = 'pending',
          resumed_at = v_occurred_at,
          expires_at = v_occurred_at + make_interval(secs => greatest(coalesce(c.duration_seconds, 60), 15)),
          revision = cl.revision + 1
      from public.challenges c
      where c.id = cl.challenge_id
        and cl.operator_id = v_op.id
        and cl.status = 'paused'
        and cl.pause_reason = 'call_active'
        and (cl.session_id is null or cl.session_id = v_sess.id);

      update public.operator_states
      set status = v_target_status,
          activity = null,
          reason_code = 'call_finished',
          session_id = v_sess.id,
          call_active = false,
          call_source = null,
          call_event_id = v_event_id,
          call_previous_status = null,
          effective_at = v_occurred_at,
          revision = revision + 1,
          updated_at = now()
      where operator_id = v_op.id
      returning * into v_state;

      insert into public.operator_status_history(
        operator_id, session_id, from_status, to_status, reason_code, source, occurred_at, state_revision, metadata
      )
      values (
        v_op.id, v_sess.id, v_previous_status, v_target_status, 'call_finished', v_source, v_occurred_at, v_state.revision,
        jsonb_build_object('event_id', v_event_id, 'metadata', v_metadata)
      );

      insert into public.operational_events(
        event_type, operator_id, session_id, device_id, unit_id, idempotency_key,
        client_sent_at, occurred_at, payload
      )
      values (
        'call.ended', v_op.id, v_sess.id, v_device_id, v_op.unit_id, v_event_id,
        v_occurred_at, v_occurred_at,
        jsonb_build_object('event', v_event, 'source', v_source, 'metadata', v_metadata)
      )
      on conflict do nothing;

      v_changed := true;
    end if;
  end if;

  v_payload := private.operator_runtime_payload(v_op.id, v_sess.id, v_result);
  v_response := public._app_envelope(
    v_req_id,
    true,
    v_payload,
    null,
    jsonb_build_object('changed', v_changed, 'event_id', v_event_id)
  );

  insert into public.app_request_idempotency(
    idempotency_key, rpc_name, operator_id, request_hash, response
  )
  values (
    v_event_id,
    'operator_operational_event',
    v_op.id,
    md5(v_event || '|' || v_source || '|' || coalesce(v_session_id::text, '') || '|' || v_metadata::text),
    v_response
  )
  on conflict do nothing;

  return v_response;
exception
  when unique_violation then
    v_payload := private.operator_runtime_payload(v_op.id, coalesce(v_session_id, v_sess.id), 'duplicate');
    return public._app_envelope(v_req_id,true,v_payload,null,jsonb_build_object('duplicate',true));
  when others then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."playlist_import_error_message"("p_error_code" "text", "p_raw_message" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case p_error_code
    when 'INVALID_URL' then 'Link invÃ¡lido ou plataforma nÃ£o suportada.'
    when 'UNSUPPORTED_PLATFORM' then 'Plataforma nÃ£o suportada pelo importador.'
    when 'PLAYLIST_PRIVATE_OR_UNAVAILABLE' then 'Playlist privada ou indisponÃ­vel.'
    when 'PLAYLIST_EMPTY' then 'Playlist vazia ou sem mÃºsicas disponÃ­veis.'
    when 'YOUTUBE_ERROR' then 'Falha no YouTube ao ler ou baixar a playlist.'
    when 'YOUTUBE_COOKIES_MISSING' then 'Falha ao importar: YouTube exigiu autenticaÃ§Ã£o e a variÃ¡vel YOUTUBE_COOKIES nÃ£o estÃ¡ configurada.'
    when 'YOUTUBE_FORMAT_UNAVAILABLE' then 'Falha no YouTube: nenhum formato de Ã¡udio disponÃ­vel para download no ambiente do importador.'
    when 'SPOTIFY_UNSUPPORTED' then 'ImportaÃ§Ã£o automÃ¡tica de Spotify ainda nÃ£o estÃ¡ disponÃ­vel.'
    when 'R2_ACCESS_DENIED' then 'Falha ao salvar no R2: acesso negado.'
    when 'R2_ERROR' then 'Falha ao salvar no R2.'
    when 'SUPABASE_PERMISSION_DENIED' then 'Falha no Supabase: permissÃ£o negada.'
    when 'SUPABASE_ERROR' then 'Falha no Supabase ao gravar a importaÃ§Ã£o.'
    when 'IMPORT_TIMEOUT' then 'Falha no importador: tempo limite excedido.'
    when 'WORKER_ENV_MISSING' then 'Falha no importador: variÃ¡vel de ambiente obrigatÃ³ria ausente.'
    when 'NO_TRACKS_DOWNLOADED' then 'Nenhuma mÃºsica foi baixada da playlist.'
    else coalesce(nullif(p_raw_message, ''), 'Falha ao importar playlist.')
  end
$$;




CREATE OR REPLACE FUNCTION "public"."playlist_source_platform"("p_url" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select case
    when p_url is null or btrim(p_url) = '' then 'none'
    when p_url !~* '^https?://' then 'invalid'
    when p_url ~* '(^https?://)?([^/]+\.)?(youtube\.com|youtu\.be)(/|$)' then 'youtube'
    when p_url ~* '(^https?://)?([^/]+\.)?spotify\.com(/|$)' then 'spotify'
    else 'unsupported'
  end
$_$;




CREATE OR REPLACE FUNCTION "public"."preserve_playlist_request_on_approval"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_previous_request uuid;
begin
  if new.status <> 'approved' or old.status = 'approved' then
    return new;
  end if;

  select r.id into v_previous_request
  from public.playlist_requests r
  where r.playlist_id = new.playlist_id
    and r.id <> new.id
    and r.status = 'approved'
  order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc
  limit 1;

  if v_previous_request is not null then
    insert into public.playlist_request_tracks (
      playlist_request_id, track_id, position, captured_at
    )
    select v_previous_request, pt.track_id, greatest(pt.position, 0), now()
    from public.playlist_tracks pt
    where pt.playlist_id = new.playlist_id
    on conflict (playlist_request_id, track_id) do update
      set position = excluded.position;
  end if;

  update public.download_jobs j
  set playlist_request_id = new.id
  where j.id = (
    select candidate.id
    from public.download_jobs candidate
    where candidate.playlist_id = new.playlist_id
      and candidate.source_url = new.source_url
      and candidate.playlist_request_id is null
      and candidate.status in ('queued', 'running')
    order by candidate.created_at desc
    limit 1
  );

  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."prevent_released_app_release_file_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if old.status = 'released' and (
    old.version is distinct from new.version
    or old.manifest_key is distinct from new.manifest_key
    or old.installer_key is distinct from new.installer_key
    or old.blockmap_key is distinct from new.blockmap_key
    or old.sha512 is distinct from new.sha512
    or old.size_bytes is distinct from new.size_bytes
  ) then
    raise exception 'released_release_files_are_immutable';
  end if;
  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."reconcile_operator_state"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_session_id uuid := nullif(p_request->>'session_id','')::uuid;
  v_app_version text := coalesce(p_request->>'app_version','');
  v_op record;
  v_sess record;
  v_shift_info jsonb;
  v_ver jsonb;
  v_blocked boolean;
  v_idle boolean;
  v_in_shift boolean;
  v_state text;
  v_prev record;
  v_config_rev bigint;
  v_playback boolean;
  v_shift_json jsonb;
  v_shift uuid;
  v_unit record;
  v_unit_json jsonb;
  v_call_active boolean := false;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;

  select * into v_op from public.operators where auth_user_id=v_uid;
  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;

  select * into v_unit from public.units where id=v_op.unit_id;
  v_unit_json := case when v_unit.id is null then null
    else jsonb_build_object('id',v_unit.id,'code',v_unit.code,'name',v_unit.name,'timezone',v_unit.timezone,'active',v_unit.active) end;

  select * into v_sess from public.operator_sessions where id=v_session_id;
  if not found or v_sess.operator_id <> v_op.id then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao nao encontrada.'),null);
  end if;
  if v_sess.status='revoked' then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao revogada.'),null);
  end if;
  if v_sess.status='ended' then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao encerrada.'),null);
  end if;
  if v_sess.status='expired' or v_sess.expires_at<=now() then
    update public.operator_sessions set status='expired', updated_at=now() where id=v_sess.id and status='active';
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_EXPIRED','message','Sessao expirada.'),null);
  end if;

  update public.operator_sessions
  set last_heartbeat_at=now(),
      app_version=coalesce(nullif(v_app_version,''),app_version),
      updated_at=now()
  where id=v_sess.id;

  v_shift := coalesce(v_sess.shift_id, v_op.default_shift_id);
  if v_sess.shift_id is null and v_shift is not null then
    update public.operator_sessions set shift_id=v_shift, updated_at=now() where id=v_sess.id;
  end if;

  v_blocked := exists(
    select 1 from public.operator_blocks b
    where b.operator_id=v_op.id
      and b.status='active'
      and (b.blocked_until is null or b.blocked_until>now())
  );
  v_idle := exists(
    select 1 from public.challenge_logs cl
    where cl.operator_id=v_op.id
      and cl.session_id=v_sess.id
      and cl.status='idle'
  );
  v_shift_info := public._app_shift_info(v_shift);
  v_in_shift := coalesce((v_shift_info->>'in_shift')::boolean, true);
  v_ver := public._app_version_check(v_op.unit_id, v_app_version, null, null);

  select * into v_prev from public.operator_states where operator_id=v_op.id;
  v_call_active := coalesce(v_prev.call_active, false);
  v_state := case
    when v_call_active then 'in_call'
    when v_blocked then 'blocked'
    when not v_in_shift then 'outside_shift'
    when v_idle then 'idle'
    else 'active'
  end;

  if not found then
    insert into public.operator_states(operator_id,session_id,status,call_active,effective_at,revision,updated_at)
      values(v_op.id,v_sess.id,v_state,false,now(),1,now());
    select * into v_prev from public.operator_states where operator_id=v_op.id;
  elsif v_prev.status is distinct from v_state or v_prev.session_id is distinct from v_sess.id then
    update public.operator_states
       set status=v_state,
           session_id=v_sess.id,
           activity=case when v_state='idle' then 'challenge_idle' else null end,
           reason_code=case when v_state='idle' then 'challenge_expired' else 'reconcile' end,
           effective_at=case when call_active then effective_at else now() end,
           revision=revision+1,
           updated_at=now()
     where operator_id=v_op.id
     returning * into v_prev;
    insert into public.operator_status_history(operator_id,session_id,from_status,to_status,reason_code,source,state_revision)
      values(v_op.id,v_sess.id,null,v_state,case when v_state='idle' then 'challenge_expired' else 'reconcile' end,'backend',v_prev.revision);
  end if;

  select coalesce(max(revision),0) into v_config_rev
  from public.system_settings
  where active=true and (scope_type='global' or (scope_type='unit' and scope_id=v_op.unit_id));

  v_playback := v_state='active'
    and v_in_shift
    and not v_blocked
    and not coalesce(v_prev.call_active,false)
    and (v_ver->>'allowed')::boolean;
  v_shift_json := v_shift_info;

  return public._app_envelope(v_req_id,true,
    jsonb_build_object(
      'session',jsonb_build_object('id',v_sess.id,'status',v_sess.status,'expires_at',v_sess.expires_at),
      'unit',v_unit_json,
      'operator',jsonb_build_object('id',v_op.id,'display_name',v_op.display_name),
      'operator_state',jsonb_build_object('status',v_state,'revision',v_prev.revision,'call_active',coalesce(v_prev.call_active,false)),
      'shift',v_shift_json,
      'version',jsonb_build_object('allowed',(v_ver->>'allowed')::boolean,'update_policy',v_ver->>'update_policy'),
      'playback_allowed',v_playback,
      'configuration',jsonb_build_object('revision',v_config_rev),
      'challenge',null,
      'block',null,
      'call',jsonb_build_object('active',coalesce(v_prev.call_active,false),'source',v_prev.call_source,'started_at',v_prev.call_started_at)
    ),
    null,
    jsonb_build_object('revision',v_prev.revision)
  );
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end
$$;




CREATE OR REPLACE FUNCTION "public"."record_app_notice_acknowledgement"("p_notice_id" "uuid", "p_acknowledge" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_operator_id uuid := public.current_operator_id();
  v_ack_id uuid;
begin
  if v_operator_id is null then
    raise exception 'operator_not_found';
  end if;

  if not exists (
    select 1
    from public.app_notices n
    where n.id = p_notice_id
      and n.status = 'active'
      and n.is_active = true
      and (n.starts_at is null or n.starts_at <= now())
      and (n.ends_at is null or n.ends_at > now())
      and (
        n.audience_type = 'all'
        or (n.audience_type = 'condominium' and n.condominium_id = (
          select o.unit_id from public.operators o where o.id = v_operator_id
        ))
        or (n.audience_type = 'user' and n.operator_id = v_operator_id)
        or (
          n.audience_type = 'shift'
          and n.shift = (
            select case
              when lower(coalesce(s.name, '')) like '%diurno%' then 'day'
              when lower(coalesce(s.name, '')) like '%noturno%' then 'night'
              else 'other'
            end
            from public.operators o
            left join public.shifts s on s.id = o.default_shift_id
            where o.id = v_operator_id
            limit 1
          )
        )
      )
  ) then
    raise exception 'notice_not_found';
  end if;

  insert into public.app_notice_acknowledgements (
    notice_id, operator_id, read_at, acknowledged_at
  ) values (
    p_notice_id,
    v_operator_id,
    now(),
    case when coalesce(p_acknowledge, false) then now() else null end
  )
  on conflict (notice_id, operator_id) do update
    set read_at = coalesce(public.app_notice_acknowledgements.read_at, excluded.read_at),
        acknowledged_at = case
          when coalesce(p_acknowledge, false) then coalesce(public.app_notice_acknowledgements.acknowledged_at, now())
          else public.app_notice_acknowledgements.acknowledged_at
        end,
        updated_at = now()
  returning id into v_ack_id;

  return v_ack_id;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."record_app_release_note_acknowledgement"("p_note_id" "uuid", "p_acknowledge" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_operator_id uuid := public.current_operator_id();
  v_ack_id uuid;
begin
  if v_operator_id is null then
    raise exception 'operator_not_found';
  end if;

  if not exists (
    select 1
    from public.app_release_notes n
    join public.app_releases r on r.id = n.app_release_id
    where n.id = p_note_id
      and n.status = 'published'
      and r.status = 'released'
  ) then
    raise exception 'release_note_not_found';
  end if;

  insert into public.app_release_note_acknowledgements (
    note_id, operator_id, read_at, acknowledged_at
  ) values (
    p_note_id,
    v_operator_id,
    now(),
    case when coalesce(p_acknowledge, false) then now() else null end
  )
  on conflict (note_id, operator_id) do update
    set read_at = coalesce(public.app_release_note_acknowledgements.read_at, excluded.read_at),
        acknowledged_at = case
          when coalesce(p_acknowledge, false) then coalesce(public.app_release_note_acknowledgements.acknowledged_at, now())
          else public.app_release_note_acknowledgements.acknowledged_at
        end,
        updated_at = now()
  returning id into v_ack_id;

  return v_ack_id;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."register_device"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_device uuid := nullif(p_request->>'device_id','')::uuid;
  v_label text := nullif(p_request->>'label','');
  v_platform text := coalesce(nullif(p_request->>'platform',''),'unknown');
  v_app_version text := nullif(p_request->>'app_version','');
  v_channel text := coalesce(nullif(p_request->>'channel',''),'stable');
  v_contract int := coalesce(nullif(p_request->>'contract_version','')::int,1);
  v_op record; v_fp text; v_meta jsonb; v_dev record;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;
  -- operador (e unidade) derivados do token; NUNCA do app
  select * into v_op from public.operators where auth_user_id=v_uid;
  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;
  if v_device is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','DEVICE_ID_REQUIRED','message','device_id ausente ou invalido.'),null);
  end if;
  -- fingerprint gerado internamente (placeholder deterministico; algoritmo final PENDENTE)
  v_fp := md5(v_device::text || '|' || v_platform);
  v_meta := jsonb_build_object('platform',v_platform,'app_version',v_app_version,'channel',v_channel,'contract_version',v_contract);

  -- Auto-aprovacao: dispositivo novo ja entra 'allowed'.
  -- Em reconexao, promove 'pending' -> 'allowed', mas respeita 'blocked'/'retired'
  -- (admin pode bloquear e a decisao e mantida).
  insert into public.devices(id, unit_id, label, fingerprint_hash, status, first_seen_at, last_seen_at, approved_at, metadata)
    values(v_device, v_op.unit_id, v_label, v_fp, 'allowed', now(), now(), now(), v_meta)
  on conflict (id) do update
    set last_seen_at = now(),
        unit_id      = excluded.unit_id,
        label        = coalesce(excluded.label, public.devices.label),
        metadata     = excluded.metadata,
        status       = case when public.devices.status in ('blocked','retired')
                            then public.devices.status else 'allowed' end,
        approved_at  = case when public.devices.status in ('blocked','retired')
                            then public.devices.approved_at else now() end,
        revision     = public.devices.revision + 1,
        updated_at   = now()
  returning * into v_dev;

  return public._app_envelope(
    v_req_id, true,
    jsonb_build_object('device', jsonb_build_object('id', v_dev.id, 'status', v_dev.status)),
    null,
    jsonb_build_object('registered', true)
  );
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."release_app_release"("p_release_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
  v_previous public.app_releases%rowtype;
begin
  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status <> 'approved' then
    raise exception 'only_approved_release_can_be_released';
  end if;
  if not private.app_release_required_ready(v_release) then
    raise exception 'release_required_fields_missing';
  end if;

  perform pg_advisory_xact_lock(hashtext('app_release:' || v_release.channel));

  for v_previous in
    select *
    from public.app_releases
    where channel = v_release.channel
      and is_current = true
      and id <> p_release_id
    for update
  loop
    update public.app_releases
    set is_current = false,
        status = 'superseded',
        updated_at = now()
    where id = v_previous.id;

    perform private.log_app_release_audit(
      v_previous.id,
      'superseded',
      v_previous.status,
      'superseded',
      v_admin_id,
      jsonb_build_object('superseded_by', p_release_id, 'channel', v_release.channel)
    );
  end loop;

  update public.app_releases
  set status = 'released',
      is_current = true,
      released_by = v_admin_id,
      released_at = now(),
      updated_at = now()
  where id = p_release_id;

  update public.app_release_rules
  set latest_version = v_release.version,
      minimum_version = coalesce(v_release.minimum_version, minimum_version, v_release.version),
      update_policy = case when v_release.mandatory then 'required' else 'optional' end,
      active = true,
      updated_at = now()
  where scope_type = 'global'
    and scope_id is null
    and platform = v_release.platform
    and channel = v_release.channel;

  if not found then
    insert into public.app_release_rules (
      scope_type, scope_id, platform, channel, minimum_version, latest_version, update_policy, active, priority
    ) values (
      'global',
      null,
      v_release.platform,
      v_release.channel,
      coalesce(v_release.minimum_version, v_release.version),
      v_release.version,
      case when v_release.mandatory then 'required' else 'optional' end,
      true,
      10
    );
  end if;

  perform private.log_app_release_audit(
    p_release_id,
    'released',
    'approved',
    'released',
    v_admin_id,
    jsonb_build_object('version', v_release.version, 'channel', v_release.channel)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."rename_principal_playlist"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid:=auth.uid();
  v_req text:=p_request->>'request_id';
  v_op public.operators%rowtype;
  v_pid uuid;
begin
  select * into v_op from public.operators where auth_user_id=v_uid and active is true;
  if v_uid is null or not found then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','FORBIDDEN'),null);
  end if;
  if nullif(p_request->>'playlist_id','') is null then
    select id into v_pid from public.playlists where created_by_operator_id=v_op.id and type='principal';
  else
    v_pid:=private.try_uuid(p_request->>'playlist_id');
  end if;
  if v_pid is null then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','PRINCIPAL_NOT_FOUND'),null);
  end if;
  if not exists(select 1 from public.playlists where id=v_pid and created_by_operator_id=v_op.id and type='principal') then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null);
  end if;
  return public.manage_operator_playlist(
    jsonb_set(jsonb_set(p_request,'{operation}',to_jsonb('rename'::text),true),'{playlist_id}',to_jsonb(v_pid::text),true)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."rollback_app_release"("p_target_release_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_target public.app_releases%rowtype;
  v_previous public.app_releases%rowtype;
begin
  select * into v_target
  from public.app_releases
  where id = p_target_release_id
  for update;

  if v_target.id is null then
    raise exception 'release_not_found';
  end if;
  if v_target.status not in ('released', 'superseded') then
    raise exception 'rollback_target_not_released';
  end if;
  if not private.app_release_required_ready(v_target) then
    raise exception 'rollback_target_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtext('app_release:' || v_target.channel));

  for v_previous in
    select *
    from public.app_releases
    where channel = v_target.channel
      and is_current = true
      and id <> p_target_release_id
    for update
  loop
    update public.app_releases
    set is_current = false,
        status = 'superseded',
        updated_at = now()
    where id = v_previous.id;

    perform private.log_app_release_audit(
      v_previous.id,
      'superseded',
      v_previous.status,
      'superseded',
      v_admin_id,
      jsonb_build_object('rollback_to', p_target_release_id, 'channel', v_target.channel)
    );
  end loop;

  update public.app_releases
  set status = 'released',
      is_current = true,
      released_by = v_admin_id,
      released_at = now(),
      updated_at = now()
  where id = p_target_release_id;

  update public.app_release_rules
  set latest_version = v_target.version,
      minimum_version = coalesce(v_target.minimum_version, minimum_version, v_target.version),
      update_policy = case when v_target.mandatory then 'required' else 'optional' end,
      active = true,
      updated_at = now()
  where scope_type = 'global'
    and scope_id is null
    and platform = v_target.platform
    and channel = v_target.channel;

  perform private.log_app_release_audit(
    p_target_release_id,
    'rollback',
    v_target.status,
    'released',
    v_admin_id,
    jsonb_build_object('version', v_target.version, 'channel', v_target.channel)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at = now();
  if tg_op = 'UPDATE' and new.revision = old.revision then
    new.revision = old.revision + 1;
  end if;
  return new;
end;$$;




CREATE OR REPLACE FUNCTION "public"."start_operator_session"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_idem uuid := nullif(p_request->>'idempotency_key','')::uuid;
  v_device uuid := nullif(p_request->>'device_id','')::uuid;
  v_app_version text := coalesce(p_request->>'app_version','');
  v_contract int := coalesce(nullif(p_request->>'contract_version','')::int,1);
  v_shift_req uuid := nullif(p_request->>'shift_id','')::uuid;
  v_op record; v_dev record; v_hash text; v_cached jsonb;
  v_shift uuid; v_shift_info jsonb; v_shift_json jsonb; v_ver jsonb; v_state text;
  v_existing record; v_session record; v_result jsonb;
  v_unit record; v_unit_json jsonb;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;
  select * into v_op from public.operators where auth_user_id = v_uid;
  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;
  select * into v_unit from public.units where id = v_op.unit_id;
  if not found or v_unit.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','UNIT_NOT_ACTIVE','message','Condominio inativo ou nao encontrado.'),null);
  end if;
  v_unit_json := jsonb_build_object('id',v_unit.id,'code',v_unit.code,'name',v_unit.name,'timezone',v_unit.timezone,'active',v_unit.active);
  v_hash := md5(coalesce(v_device::text,'')||'|'||v_app_version||'|'||coalesce(v_shift_req::text,'')||'|'||v_contract::text);
  if v_idem is not null then
    select response into v_cached from public.app_request_idempotency where idempotency_key=v_idem and rpc_name='start_operator_session';
    if v_cached is not null then return v_cached; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext(v_op.id::text));
  if exists(select 1 from public.operator_blocks b where b.operator_id=v_op.id and b.status='active' and (b.blocked_until is null or b.blocked_until>now())) then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','OPERATOR_BLOCKED','message','Operador esta bloqueado.'),null);
  end if;
  if v_device is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','DEVICE_NOT_ALLOWED','message','Dispositivo nao informado.'),null);
  end if;
  select * into v_dev from public.devices where id=v_device;
  if not found or v_dev.status <> 'allowed' then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','DEVICE_NOT_ALLOWED','message','Dispositivo nao autorizado.'),null);
  end if;
  if v_dev.unit_id is not null and v_op.unit_id is not null and v_dev.unit_id <> v_op.unit_id then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','DEVICE_NOT_ALLOWED','message','Dispositivo pertence a outra unidade.'),null);
  end if;
  v_ver := public._app_version_check(v_op.unit_id, v_app_version, v_dev.metadata->>'platform', null);
  if (v_ver->>'allowed')::boolean is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','APP_VERSION_NOT_ALLOWED','message','Versao do aplicativo nao permitida.'),jsonb_build_object('version',v_ver));
  end if;
  v_shift := coalesce(v_shift_req, v_op.default_shift_id);
  v_shift_info := public._app_shift_info(v_shift);
  v_shift_json := v_shift_info;
  if coalesce(v_op.session_policy,'single')='single' then
    select * into v_existing from public.operator_sessions
      where operator_id=v_op.id and status='active' and expires_at>now()
        and device_id is not distinct from v_device
      order by started_at desc limit 1;
    if found then
      update public.operator_sessions
         set status='revoked', ended_at=now(), end_reason='superseded_by_new_login', updated_at=now(), revision=revision+1
       where operator_id=v_op.id and status='active' and id <> v_existing.id;
      v_result := public._app_envelope(v_req_id,true,jsonb_build_object('session',jsonb_build_object('id',v_existing.id,'status',v_existing.status),'unit',v_unit_json,'shift',v_shift_json),null,jsonb_build_object('reused',true));
      if v_idem is not null then
        insert into public.app_request_idempotency(idempotency_key,rpc_name,operator_id,request_hash,response)
        values(v_idem,'start_operator_session',v_op.id,v_hash,v_result) on conflict do nothing;
      end if;
      return v_result;
    else
      update public.operator_sessions
         set status='revoked', ended_at=now(), end_reason='superseded_by_new_login', updated_at=now(), revision=revision+1
       where operator_id=v_op.id and status='active';
    end if;
  end if;
  insert into public.operator_sessions(operator_id,device_id,unit_id,shift_id,status,app_version,contract_version)
    values(v_op.id,v_device,v_op.unit_id,v_shift,'active',nullif(v_app_version,''),v_contract)
    returning * into v_session;
  v_state := case when (v_shift_info is not null and (v_shift_info->>'in_shift')::boolean is not true) then 'outside_shift' else 'active' end;
  insert into public.operator_states(operator_id,session_id,status,effective_at,revision,updated_at)
    values(v_op.id,v_session.id,v_state,now(),1,now())
  on conflict (operator_id) do update
    set session_id=excluded.session_id, status=excluded.status, effective_at=now(), revision=operator_states.revision+1, updated_at=now();
  insert into public.operator_status_history(operator_id,session_id,from_status,to_status,reason_code,source)
    values(v_op.id,v_session.id,null,v_state,'session_start','backend');
  v_result := public._app_envelope(v_req_id,true,jsonb_build_object('session',jsonb_build_object('id',v_session.id,'status',v_session.status),'unit',v_unit_json,'shift',v_shift_json),null,null);
  if v_idem is not null then
    insert into public.app_request_idempotency(idempotency_key,rpc_name,operator_id,request_hash,response)
    values(v_idem,'start_operator_session',v_op.id,v_hash,v_result) on conflict do nothing;
  end if;
  return v_result;
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."submit_feedback"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_type text := lower(coalesce(nullif(p_request->>'type',''),'suggestion'));
  v_message text := nullif(btrim(p_request->>'message'),'');
  v_app_version text := nullif(p_request->>'app_version','');
  v_op record; v_row record;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;

  select * into v_op from public.operators where auth_user_id = v_uid;
  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;

  -- aceita rotulos PT e normaliza
  v_type := case v_type
    when 'sugestao' then 'suggestion'
    when 'sugestÃ£o' then 'suggestion'
    when 'problema' then 'problem'
    when 'bug' then 'problem'
    when 'elogio' then 'praise'
    else v_type end;
  if v_type not in ('suggestion','problem','praise') then v_type := 'suggestion'; end if;

  if v_message is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','MESSAGE_REQUIRED','message','Escreva uma mensagem.'),null);
  end if;
  if length(v_message) > 2000 then v_message := left(v_message, 2000); end if;

  insert into public.feedback(operator_id, unit_id, type, message, status, app_version)
  values (v_op.id, v_op.unit_id, v_type, v_message, 'new', v_app_version)
  returning * into v_row;

  return public._app_envelope(
    v_req_id, true,
    jsonb_build_object('feedback', jsonb_build_object('id', v_row.id, 'status', v_row.status, 'type', v_row.type)),
    null,
    jsonb_build_object('submitted', true)
  );
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;




CREATE OR REPLACE FUNCTION "public"."submit_playlist"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.manage_operator_playlist(jsonb_set(p_request, '{operation}', to_jsonb('submit'::text), true));
$$;




CREATE OR REPLACE FUNCTION "public"."sync_app_notice_metadata"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid;
begin
  v_admin_id := public.current_admin_user_id();

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, v_admin_id);
  end if;

  new.updated_by := coalesce(v_admin_id, new.updated_by);
  new.updated_at := now();
  new.is_active := new.status = 'active';

  if new.status = 'active'
    and new.starts_at is not null
    and new.ends_at is not null
    and new.ends_at <= new.starts_at then
    raise exception 'notice_invalid_window';
  end if;

  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."sync_app_release_note_metadata"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_release public.app_releases%rowtype;
  v_admin_id uuid;
begin
  select * into v_release
  from public.app_releases
  where id = new.app_release_id;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;

  new.version_number := v_release.version;
  v_admin_id := public.current_admin_user_id();

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, v_admin_id);
  end if;

  new.updated_by := coalesce(v_admin_id, new.updated_by);
  new.updated_at := now();

  if new.status = 'published' and new.published_at is null then
    new.published_at := now();
  elsif new.status = 'draft' then
    new.published_at := null;
  end if;

  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."sync_playlist_import_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_import_status text;
  v_message text;
  v_code text;
begin
  if coalesce(new.mode, 'playlist') <> 'playlist' then
    return new;  -- single_track: nÃ£o mexe no import_status nem no relatÃ³rio da playlist
  end if;

  v_import_status := case new.status
    when 'queued' then 'processing'
    when 'running' then 'processing'
    when 'done' then 'success'
    when 'partial' then 'failed'
    when 'error' then 'failed'
    else 'not_started'
  end;

  v_code := coalesce(
    new.error_code,
    case
      when new.status in ('partial', 'error') and coalesce(new.completed, 0) = 0 then 'NO_TRACKS_DOWNLOADED'
      when new.status in ('partial', 'error') then 'PARTIAL_IMPORT_FAILED'
      else null
    end
  );
  v_message := public.playlist_import_error_message(v_code, coalesce(new.error_message, new.error));

  update public.playlists
  set
    import_status = v_import_status,
    import_started_at = case
      when new.status in ('queued', 'running') then coalesce(import_started_at, new.started_at, now())
      else import_started_at
    end,
    import_finished_at = case
      when new.status in ('done', 'partial', 'error') then coalesce(new.finished_at, now())
      else import_finished_at
    end,
    error_code = case when v_import_status = 'failed' then v_code else null end,
    error_message = case when v_import_status = 'failed' then v_message else null end,
    error_details = case
      when v_import_status = 'failed' then coalesce(
        new.error_details,
        jsonb_build_object(
          'download_job_id', new.id,
          'download_status', new.status,
          'raw_error', new.error,
          'completed', new.completed,
          'failed', new.failed,
          'total', new.total
        )
      )
      when new.error_details is not null then new.error_details
      else null
    end,
    last_error_at = case when v_import_status = 'failed' then coalesce(new.last_error_at, now()) else null end
  where id = new.playlist_id;

  return new;
end
$$;




CREATE OR REPLACE FUNCTION "public"."sync_playlist_review_import_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid;
  v_platform text;
begin
  if new.approval_status is distinct from old.approval_status then
    select id into v_admin_id
    from public.admin_users
    where auth_user_id = auth.uid()
    limit 1;

    if new.approval_status in ('approved', 'rejected') then
      new.reviewed_by_admin_id := coalesce(new.reviewed_by_admin_id, v_admin_id);
      new.reviewed_at := coalesce(new.reviewed_at, now());
    end if;

    if new.approval_status = 'rejected' then
      new.import_status := 'not_started';
      new.import_started_at := null;
      new.import_finished_at := null;
      new.error_code := null;
      new.error_message := null;
      new.error_details := null;
      new.last_error_at := null;
    elsif new.approval_status = 'approved' then
      v_platform := public.playlist_source_platform(new.source_url);

      if v_platform = 'youtube' then
        new.import_status := 'not_started';
        new.error_code := null;
        new.error_message := null;
        new.error_details := null;
        new.last_error_at := null;
      elsif v_platform = 'spotify' then
        new.import_status := 'failed';
        new.error_code := 'SPOTIFY_UNSUPPORTED';
        new.error_message := public.playlist_import_error_message('SPOTIFY_UNSUPPORTED', null);
        new.error_details := jsonb_build_object('platform', v_platform, 'source_url', new.source_url);
        new.last_error_at := now();
      else
        new.import_status := 'failed';
        new.error_code := case when v_platform = 'invalid' then 'INVALID_URL' else 'UNSUPPORTED_PLATFORM' end;
        new.error_message := public.playlist_import_error_message(new.error_code, null);
        new.error_details := jsonb_build_object('platform', v_platform, 'source_url', new.source_url);
        new.last_error_at := now();
      end if;
    end if;
  end if;

  return new;
end
$$;




CREATE OR REPLACE FUNCTION "public"."touch_app_release_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."touch_release_note_on_release"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.status = 'released' and coalesce(old.status, '') <> 'released' then
    update public.app_release_notes
      set updated_at = now()
      where app_release_id = new.id
        and status = 'published';
  end if;
  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."update_app_notice_status"("p_notice_id" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  if v_status not in ('draft', 'active', 'expired', 'disabled') then
    raise exception 'invalid_notice_status';
  end if;

  update public.app_notices
  set status = v_status,
      is_active = v_status = 'active',
      ends_at = case
        when v_status = 'expired' and (ends_at is null or ends_at > now()) then now()
        else ends_at
      end,
      updated_by = v_admin_id,
      updated_at = now()
  where id = p_notice_id;

  if not found then
    raise exception 'notice_not_found';
  end if;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."update_app_release"("p_release_id" "uuid", "p_title" "text" DEFAULT NULL::"text", "p_release_notes" "text" DEFAULT NULL::"text", "p_mandatory" boolean DEFAULT NULL::boolean, "p_minimum_version" "text" DEFAULT NULL::"text", "p_manifest_key" "text" DEFAULT NULL::"text", "p_installer_key" "text" DEFAULT NULL::"text", "p_blockmap_key" "text" DEFAULT NULL::"text", "p_sha512" "text" DEFAULT NULL::"text", "p_size_bytes" bigint DEFAULT NULL::bigint, "p_status" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_before public.app_releases%rowtype;
  v_after public.app_releases%rowtype;
  v_status text;
  v_title text;
begin
  select * into v_before
  from public.app_releases
  where id = p_release_id
  for update;

  if v_before.id is null then
    raise exception 'release_not_found';
  end if;
  if v_before.status not in ('draft', 'testing') then
    raise exception 'release_locked';
  end if;

  v_status := coalesce(nullif(btrim(coalesce(p_status, '')), ''), v_before.status);
  if v_status not in ('draft', 'testing') then
    raise exception 'invalid_edit_status';
  end if;

  v_title := nullif(btrim(coalesce(p_title, v_before.title, '')), '');
  if v_title is null then
    raise exception 'title_required';
  end if;

  update public.app_releases
  set title = v_title,
      release_notes = nullif(btrim(coalesce(p_release_notes, release_notes, '')), ''),
      mandatory = coalesce(p_mandatory, mandatory),
      minimum_version = nullif(btrim(coalesce(p_minimum_version, minimum_version, '')), ''),
      manifest_key = nullif(btrim(coalesce(p_manifest_key, manifest_key, '')), ''),
      installer_key = nullif(btrim(coalesce(p_installer_key, installer_key, '')), ''),
      blockmap_key = nullif(btrim(coalesce(p_blockmap_key, blockmap_key, '')), ''),
      sha512 = nullif(btrim(coalesce(p_sha512, sha512, '')), ''),
      size_bytes = coalesce(p_size_bytes, size_bytes),
      status = v_status,
      updated_at = now()
  where id = p_release_id
  returning * into v_after;

  perform private.log_app_release_audit(
    p_release_id,
    'edited',
    v_before.status,
    v_after.status,
    v_admin_id,
    jsonb_build_object('version', v_after.version, 'channel', v_after.channel)
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."update_my_operator_display_name"("p_display_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator public.operators%rowtype;
  v_display_name text;
  v_normalized_name text;
  v_compact_name text;
  v_normalized_current_name text;
  v_server_now timestamptz := clock_timestamp();
  v_last_applied_at timestamptz;
  v_next_change_at timestamptz;
  v_attempt_count integer;
  v_attempt_already_seen boolean;
  v_term public.operator_display_name_moderation_terms%rowtype;
begin
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'NOT_AUTHENTICATED',
        'message', 'Sessao autenticada obrigatoria.',
        'retryable', false
      )
    );
  end if;

  v_display_name := btrim(regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g'));

  if char_length(v_display_name) < 3 then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', case when v_display_name = '' then 'DISPLAY_NAME_REQUIRED' else 'DISPLAY_NAME_TOO_SHORT' end,
        'message', case when v_display_name = '' then 'Informe o nome de exibicao.' else 'O nome deve ter pelo menos 3 caracteres.' end,
        'retryable', false
      )
    );
  end if;

  if char_length(v_display_name) > 50 then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_TOO_LONG',
        'message', 'O nome deve ter no maximo 50 caracteres.',
        'retryable', false
      )
    );
  end if;

  v_normalized_name := private.normalize_operator_display_name(v_display_name, false);
  v_compact_name := private.normalize_operator_display_name(v_display_name, true);

  select * into v_operator
  from public.operators
  where auth_user_id = v_auth_user_id
  for update;

  if v_operator.id is null then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'OPERATOR_NOT_FOUND',
        'message', 'Operador autenticado nao encontrado.',
        'retryable', false
      )
    );
  end if;

  v_normalized_current_name := private.normalize_operator_display_name(v_operator.display_name, false);

  select max(applied_at) into v_last_applied_at
  from public.operator_display_name_requests
  where operator_id = v_operator.id
    and applied_at is not null;

  v_next_change_at := case
    when v_last_applied_at is null then null
    else v_last_applied_at + interval '15 days'
  end;

  if v_normalized_current_name = v_normalized_name then
    return jsonb_build_object(
      'success', true,
      'server_now', clock_timestamp(),
      'data', jsonb_build_object(
        'display_name', v_operator.display_name,
        'changed', false,
        'moderation_status', 'allowed',
        'next_change_at', v_next_change_at
      ),
      'error', null
    );
  end if;

  select
    count(distinct request_row.normalized_name)::integer,
    coalesce(bool_or(request_row.normalized_name = v_normalized_name), false)
  into v_attempt_count, v_attempt_already_seen
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.actor_type = 'operator'
    and request_row.occurred_at >= v_server_now - interval '10 minutes';

  if v_attempt_count >= 5 and not v_attempt_already_seen then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'rate_limited',
      'Limite de cinco nomes diferentes em dez minutos.', 'not_required', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_RATE_LIMITED',
        'message', 'Muitas tentativas. Aguarde alguns minutos para tentar novamente.',
        'retryable', true,
        'retry_at', (
          select min(request_row.occurred_at) + interval '10 minutes'
          from public.operator_display_name_requests request_row
          where request_row.operator_id = v_operator.id
            and request_row.actor_type = 'operator'
            and request_row.occurred_at >= v_server_now - interval '10 minutes'
        )
      )
    );
  end if;

  if v_next_change_at is not null and v_next_change_at > v_server_now then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'rate_limited',
      'Prazo de 15 dias ainda em andamento.', 'not_required', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_CHANGE_COOLDOWN',
        'message', 'O nome de exibicao so pode ser alterado uma vez a cada 15 dias.',
        'retryable', true,
        'retry_at', v_next_change_at
      )
    );
  end if;

  select * into v_term
  from public.operator_display_name_moderation_terms term_row
  where term_row.active = true
    and (
      (term_row.match_type = 'exact_name' and v_normalized_name = term_row.normalized_term)
      or (
        term_row.match_type = 'whole_word'
        and position(' ' || term_row.normalized_term || ' ' in ' ' || v_normalized_name || ' ') > 0
      )
      or (
        term_row.match_type = 'obfuscated'
        and char_length(term_row.compact_term) >= 3
        and position(term_row.compact_term in v_compact_name) > 0
      )
    )
  order by case term_row.match_type
    when 'exact_name' then 1
    when 'whole_word' then 2
    else 3
  end, char_length(term_row.normalized_term) desc
  limit 1;

  if v_term.id is not null then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_term_id, moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'blocked',
      v_term.id, v_term.reason, 'pending', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_NOT_ALLOWED',
        'message', 'Esse nome de exibicao nao pode ser utilizado.',
        'retryable', false
      )
    );
  end if;

  insert into public.operator_display_name_requests (
    operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
    requested_name, normalized_name, compact_name, applied_name,
    moderation_result, review_status, source, occurred_at, applied_at
  ) values (
    v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
    v_display_name, v_normalized_name, v_compact_name, v_display_name,
    'allowed', 'not_required', 'operator_app', v_server_now, v_server_now
  );

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators
  set display_name = v_display_name,
      updated_at = v_server_now
  where id = v_operator.id;

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object(
      'display_name', v_display_name,
      'changed', true,
      'moderation_status', 'allowed',
      'next_change_at', v_server_now + interval '15 days'
    ),
    'error', null
  );
end;
$$;




CREATE OR REPLACE FUNCTION "public"."upsert_app_notice"("p_notice_id" "uuid", "p_title" "text", "p_message" "text", "p_severity" "text", "p_status" "text", "p_starts_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_ends_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_audience_type" "text" DEFAULT 'all'::"text", "p_condominium_id" "uuid" DEFAULT NULL::"uuid", "p_operator_id" "uuid" DEFAULT NULL::"uuid", "p_shift" "text" DEFAULT NULL::"text", "p_requires_ack" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_notice_id uuid;
  v_severity text := coalesce(nullif(btrim(coalesce(p_severity, '')), ''), 'info');
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
  v_audience_type text := coalesce(nullif(btrim(coalesce(p_audience_type, '')), ''), 'all');
begin
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'notice_title_required';
  end if;
  if nullif(btrim(coalesce(p_message, '')), '') is null then
    raise exception 'notice_message_required';
  end if;
  if v_severity not in ('info', 'warning', 'critical', 'success') then
    raise exception 'invalid_notice_severity';
  end if;
  if v_status not in ('draft', 'active', 'expired', 'disabled') then
    raise exception 'invalid_notice_status';
  end if;
  if v_audience_type not in ('all', 'condominium', 'shift', 'user') then
    raise exception 'invalid_notice_audience';
  end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at <= p_starts_at then
    raise exception 'notice_invalid_window';
  end if;
  if v_status = 'active' and p_ends_at is not null and p_ends_at <= now() then
    raise exception 'notice_active_already_ended';
  end if;
  if v_audience_type = 'condominium' and p_condominium_id is null then
    raise exception 'notice_condominium_required';
  end if;
  if v_audience_type = 'shift' and nullif(btrim(coalesce(p_shift, '')), '') is null then
    raise exception 'notice_shift_required';
  end if;
  if v_audience_type = 'user' and p_operator_id is null then
    raise exception 'notice_operator_required';
  end if;

  if p_notice_id is null then
    insert into public.app_notices (
      title, message, severity, status, starts_at, ends_at, is_active,
      audience_type, condominium_id, operator_id, shift, requires_ack, created_by, updated_by
    ) values (
      btrim(p_title),
      btrim(p_message),
      v_severity,
      v_status,
      p_starts_at,
      p_ends_at,
      v_status = 'active',
      v_audience_type,
      case when v_audience_type = 'condominium' then p_condominium_id else null end,
      case when v_audience_type = 'user' then p_operator_id else null end,
      case when v_audience_type = 'shift' then nullif(btrim(coalesce(p_shift, '')), '') else null end,
      coalesce(p_requires_ack, false),
      v_admin_id,
      v_admin_id
    )
    returning id into v_notice_id;
  else
    update public.app_notices
    set title = btrim(p_title),
        message = btrim(p_message),
        severity = v_severity,
        status = v_status,
        starts_at = p_starts_at,
        ends_at = p_ends_at,
        is_active = v_status = 'active',
        audience_type = v_audience_type,
        condominium_id = case when v_audience_type = 'condominium' then p_condominium_id else null end,
        operator_id = case when v_audience_type = 'user' then p_operator_id else null end,
        shift = case when v_audience_type = 'shift' then nullif(btrim(coalesce(p_shift, '')), '') else null end,
        requires_ack = coalesce(p_requires_ack, false),
        updated_by = v_admin_id,
        updated_at = now()
    where id = p_notice_id
    returning id into v_notice_id;

    if v_notice_id is null then
      raise exception 'notice_not_found';
    end if;
  end if;

  return v_notice_id;
end;
$$;




CREATE OR REPLACE FUNCTION "public"."upsert_app_release_note"("p_app_release_id" "uuid", "p_title" "text", "p_summary" "text", "p_content" "text", "p_status" "text" DEFAULT 'draft'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_note_id uuid;
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
begin
  if v_status not in ('draft', 'published') then
    raise exception 'invalid_release_note_status';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'release_note_title_required';
  end if;
  if nullif(btrim(coalesce(p_summary, '')), '') is null then
    raise exception 'release_note_summary_required';
  end if;
  if nullif(btrim(coalesce(p_content, '')), '') is null then
    raise exception 'release_note_content_required';
  end if;
  if not exists (select 1 from public.app_releases where id = p_app_release_id) then
    raise exception 'release_not_found';
  end if;

  insert into public.app_release_notes (
    app_release_id, version_number, title, summary, content, status, published_at, created_by, updated_by
  )
  select
    r.id,
    r.version,
    btrim(p_title),
    btrim(p_summary),
    btrim(p_content),
    v_status,
    case when v_status = 'published' then now() else null end,
    v_admin_id,
    v_admin_id
  from public.app_releases r
  where r.id = p_app_release_id
  on conflict (app_release_id) do update
    set title = excluded.title,
        summary = excluded.summary,
        content = excluded.content,
        status = excluded.status,
        published_at = case
          when excluded.status = 'published' then coalesce(public.app_release_notes.published_at, now())
          else null
        end,
        updated_by = v_admin_id,
        updated_at = now()
  returning id into v_note_id;

  return v_note_id;
end;
$$;




CREATE TABLE IF NOT EXISTS "public"."admin_audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_user_id" "uuid",
    "action" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "request_id" "uuid",
    "before_data" "jsonb",
    "after_data" "jsonb",
    "reason" "text",
    "ip_hash" "text",
    "user_agent" "text",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."app_notice_acknowledgements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "notice_id" "uuid" NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "read_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "acknowledged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_notice_ack_ack_after_read_check" CHECK ((("acknowledged_at" IS NULL) OR ("acknowledged_at" >= "read_at")))
);




CREATE TABLE IF NOT EXISTS "public"."app_notices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "severity" "text" DEFAULT 'info'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "is_active" boolean DEFAULT false NOT NULL,
    "audience_type" "text" DEFAULT 'all'::"text" NOT NULL,
    "condominium_id" "uuid",
    "operator_id" "uuid",
    "shift" "text",
    "requires_ack" boolean DEFAULT false NOT NULL,
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_notices_active_status_check" CHECK (("is_active" = ("status" = 'active'::"text"))),
    CONSTRAINT "app_notices_audience_type_check" CHECK (("audience_type" = ANY (ARRAY['all'::"text", 'condominium'::"text", 'shift'::"text", 'user'::"text"]))),
    CONSTRAINT "app_notices_condominium_audience_check" CHECK ((("audience_type" <> 'condominium'::"text") OR ("condominium_id" IS NOT NULL))),
    CONSTRAINT "app_notices_message_not_blank" CHECK ((NULLIF("btrim"("message"), ''::"text") IS NOT NULL)),
    CONSTRAINT "app_notices_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text", 'success'::"text"]))),
    CONSTRAINT "app_notices_shift_audience_check" CHECK ((("audience_type" <> 'shift'::"text") OR (NULLIF("btrim"(COALESCE("shift", ''::"text")), ''::"text") IS NOT NULL))),
    CONSTRAINT "app_notices_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'expired'::"text", 'disabled'::"text"]))),
    CONSTRAINT "app_notices_title_not_blank" CHECK ((NULLIF("btrim"("title"), ''::"text") IS NOT NULL)),
    CONSTRAINT "app_notices_user_audience_check" CHECK ((("audience_type" <> 'user'::"text") OR ("operator_id" IS NOT NULL))),
    CONSTRAINT "app_notices_window_check" CHECK ((("ends_at" IS NULL) OR ("starts_at" IS NULL) OR ("ends_at" > "starts_at")))
);




CREATE TABLE IF NOT EXISTS "public"."app_release_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "release_id" "uuid",
    "action" "text" NOT NULL,
    "previous_status" "text",
    "new_status" "text",
    "actor_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_release_audit_action_check" CHECK (("action" = ANY (ARRAY['created'::"text", 'edited'::"text", 'approved'::"text", 'released'::"text", 'blocked'::"text", 'rollback'::"text", 'superseded'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."app_release_note_acknowledgements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "note_id" "uuid" NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "read_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "acknowledged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_release_note_ack_ack_after_read_check" CHECK ((("acknowledged_at" IS NULL) OR ("acknowledged_at" >= "read_at")))
);




CREATE TABLE IF NOT EXISTS "public"."app_release_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "app_release_id" "uuid" NOT NULL,
    "version_number" "text" NOT NULL,
    "title" "text" NOT NULL,
    "summary" "text" NOT NULL,
    "content" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "published_at" timestamp with time zone,
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_release_notes_content_not_blank" CHECK ((NULLIF("btrim"("content"), ''::"text") IS NOT NULL)),
    CONSTRAINT "app_release_notes_published_at_check" CHECK ((("status" <> 'published'::"text") OR ("published_at" IS NOT NULL))),
    CONSTRAINT "app_release_notes_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text"]))),
    CONSTRAINT "app_release_notes_summary_not_blank" CHECK ((NULLIF("btrim"("summary"), ''::"text") IS NOT NULL)),
    CONSTRAINT "app_release_notes_title_not_blank" CHECK ((NULLIF("btrim"("title"), ''::"text") IS NOT NULL))
);




CREATE TABLE IF NOT EXISTS "public"."app_release_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scope_type" "text" DEFAULT 'global'::"text" NOT NULL,
    "scope_id" "uuid",
    "platform" "text" DEFAULT 'win32-x64'::"text" NOT NULL,
    "channel" "text" DEFAULT 'stable'::"text" NOT NULL,
    "minimum_version" "text" NOT NULL,
    "latest_version" "text",
    "update_policy" "text" DEFAULT 'optional'::"text" NOT NULL,
    "grace_until" timestamp with time zone,
    "active" boolean DEFAULT true NOT NULL,
    "priority" integer DEFAULT 0 NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_release_rules_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['global'::"text", 'unit'::"text"]))),
    CONSTRAINT "app_release_rules_update_policy_check" CHECK (("update_policy" = ANY (ARRAY['none'::"text", 'optional'::"text", 'required'::"text", 'blocked'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."app_request_idempotency" (
    "idempotency_key" "uuid" NOT NULL,
    "rpc_name" "text" NOT NULL,
    "operator_id" "uuid",
    "request_hash" "text" NOT NULL,
    "response" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE OR REPLACE VIEW "public"."app_versions" WITH ("security_invoker"='true') AS
 SELECT "id",
    "version",
    "platform",
    "channel",
    "status",
        CASE
            WHEN (("release_notes" IS NULL) OR ("release_notes" = ''::"text")) THEN '{}'::"jsonb"
            ELSE "jsonb_build_object"('text', "release_notes")
        END AS "release_notes",
    "manifest_key" AS "artifact_uri",
    "sha512" AS "artifact_hash",
    NULL::"text" AS "signature",
    "released_at",
    "created_at"
   FROM "public"."app_releases";




CREATE TABLE IF NOT EXISTS "public"."call_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "session_id" "uuid",
    "device_id" "uuid",
    "external_call_id" "text",
    "status" "text" DEFAULT 'started'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "revision" bigint DEFAULT 1 NOT NULL,
    CONSTRAINT "call_sessions_status_check" CHECK (("status" = ANY (ARRAY['started'::"text", 'finished'::"text", 'abandoned'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."challenges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unit_id" "uuid",
    "title" "text" NOT NULL,
    "prompt" "text" NOT NULL,
    "kind" "text" DEFAULT 'multiple_choice'::"text" NOT NULL,
    "answer_definition" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "duration_seconds" integer DEFAULT 60 NOT NULL,
    "block_seconds" integer,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by" "uuid",
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "challenges_block_seconds_check" CHECK ((("block_seconds" IS NULL) OR ("block_seconds" > 0))),
    CONSTRAINT "challenges_duration_seconds_check" CHECK (("duration_seconds" > 0)),
    CONSTRAINT "challenges_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'inactive'::"text", 'archived'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unit_id" "uuid",
    "label" "text",
    "fingerprint_hash" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "first_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "blocked_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "devices_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'allowed'::"text", 'blocked'::"text", 'retired'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."download_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "playlist_id" "uuid" NOT NULL,
    "source_url" "text",
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "total" integer DEFAULT 0 NOT NULL,
    "completed" integer DEFAULT 0 NOT NULL,
    "failed" integer DEFAULT 0 NOT NULL,
    "error" "text",
    "attempts" integer DEFAULT 0 NOT NULL,
    "locked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_code" "text",
    "error_message" "text",
    "error_details" "jsonb",
    "last_error_at" timestamp with time zone,
    "mode" "text" DEFAULT 'playlist'::"text" NOT NULL,
    "replace_youtube_id" "text",
    "playlist_request_id" "uuid",
    CONSTRAINT "download_jobs_mode_check" CHECK (("mode" = ANY (ARRAY['playlist'::"text", 'single_track'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid",
    "unit_id" "uuid",
    "type" "text" DEFAULT 'suggestion'::"text" NOT NULL,
    "message" "text" NOT NULL,
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "app_version" "text",
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "feedback_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'read'::"text", 'resolved'::"text"]))),
    CONSTRAINT "feedback_type_check" CHECK (("type" = ANY (ARRAY['suggestion'::"text", 'problem'::"text", 'praise'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."operational_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "schema_version" integer DEFAULT 1 NOT NULL,
    "operator_id" "uuid",
    "session_id" "uuid",
    "device_id" "uuid",
    "unit_id" "uuid",
    "related_entity_type" "text",
    "related_entity_id" "uuid",
    "idempotency_key" "uuid",
    "client_sent_at" timestamp with time zone,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."operator_blocks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "session_id" "uuid",
    "challenge_log_id" "uuid",
    "reason_code" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "blocked_until" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_by" "uuid",
    "revision" bigint DEFAULT 1 NOT NULL,
    CONSTRAINT "operator_blocks_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'active'::"text", 'finished'::"text", 'revoked'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."operator_display_name_moderation_terms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "term" "text" NOT NULL,
    "normalized_term" "text" NOT NULL,
    "compact_term" "text" NOT NULL,
    "match_type" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "reason" "text" NOT NULL,
    "created_by_admin_id" "uuid",
    "updated_by_admin_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operator_display_name_terms_match_type_check" CHECK (("match_type" = ANY (ARRAY['exact_name'::"text", 'whole_word'::"text", 'obfuscated'::"text"]))),
    CONSTRAINT "operator_display_name_terms_reason_not_blank" CHECK (("btrim"("reason") <> ''::"text")),
    CONSTRAINT "operator_display_name_terms_term_not_blank" CHECK (("btrim"("term") <> ''::"text"))
);




CREATE TABLE IF NOT EXISTS "public"."operator_display_name_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "unit_id" "uuid" NOT NULL,
    "actor_auth_user_id" "uuid",
    "actor_type" "text" NOT NULL,
    "actor_admin_user_id" "uuid",
    "previous_name" "text" NOT NULL,
    "requested_name" "text" NOT NULL,
    "normalized_name" "text" NOT NULL,
    "compact_name" "text" NOT NULL,
    "applied_name" "text",
    "moderation_result" "text" NOT NULL,
    "moderation_term_id" "uuid",
    "moderation_reason" "text",
    "review_status" "text" DEFAULT 'not_required'::"text" NOT NULL,
    "reviewed_by_admin_id" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_reason" "text",
    "source" "text" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "applied_at" timestamp with time zone,
    CONSTRAINT "operator_display_name_requests_actor_type_check" CHECK (("actor_type" = ANY (ARRAY['operator'::"text", 'admin'::"text", 'system'::"text"]))),
    CONSTRAINT "operator_display_name_requests_result_check" CHECK (("moderation_result" = ANY (ARRAY['allowed'::"text", 'blocked'::"text", 'rate_limited'::"text"]))),
    CONSTRAINT "operator_display_name_requests_review_check" CHECK (("review_status" = ANY (ARRAY['not_required'::"text", 'pending'::"text", 'approved'::"text", 'rejected'::"text"]))),
    CONSTRAINT "operator_display_name_requests_source_check" CHECK (("source" = ANY (ARRAY['operator_app'::"text", 'admin_panel'::"text", 'admin_approval'::"text", 'system'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."operator_group_members" (
    "group_id" "uuid" NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."operator_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unit_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."operator_preferences" (
    "operator_id" "uuid" NOT NULL,
    "theme" "text" DEFAULT 'light'::"text" NOT NULL,
    "volume" smallint,
    "shuffle" boolean DEFAULT false,
    "repeat_mode" "text" DEFAULT 'off'::"text",
    "revision" bigint DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operator_preferences_theme_check" CHECK (("theme" = ANY (ARRAY['light'::"text", 'dark'::"text", 'system'::"text"]))),
    CONSTRAINT "operator_preferences_volume_check" CHECK ((("volume" IS NULL) OR (("volume" >= 0) AND ("volume" <= 100))))
);




CREATE TABLE IF NOT EXISTS "public"."operator_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "device_id" "uuid",
    "unit_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '12:00:00'::interval) NOT NULL,
    "last_heartbeat_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "end_reason" "text",
    "app_version" "text" DEFAULT '1.0.0'::"text" NOT NULL,
    "contract_version" integer DEFAULT 1 NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operator_sessions_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'expired'::"text", 'revoked'::"text", 'ended'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."operator_status_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "session_id" "uuid",
    "from_status" "text",
    "to_status" "text" NOT NULL,
    "reason_code" "text" NOT NULL,
    "source" "text" DEFAULT 'backend'::"text" NOT NULL,
    "actor_id" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "state_revision" bigint DEFAULT 1 NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);




CREATE TABLE IF NOT EXISTS "public"."operators" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid",
    "unit_id" "uuid" NOT NULL,
    "employee_code" "text",
    "display_name" "text" NOT NULL,
    "default_shift_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "session_policy" "text" DEFAULT 'single'::"text" NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "role" "text" DEFAULT 'operador'::"text" NOT NULL,
    "username" "text",
    "registered_name" "text" NOT NULL,
    CONSTRAINT "operators_registered_name_not_blank" CHECK (("btrim"("registered_name") <> ''::"text")),
    CONSTRAINT "operators_role_check" CHECK (("role" = ANY (ARRAY['operador'::"text", 'supervisor'::"text"]))),
    CONSTRAINT "operators_session_policy_check" CHECK (("session_policy" = ANY (ARRAY['single'::"text", 'multi'::"text"])))
);




COMMENT ON COLUMN "public"."operators"."display_name" IS 'Nome escolhido pelo operador para exibicao no App; nao substitui o nome cadastral.';



CREATE TABLE IF NOT EXISTS "public"."playlist_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "playlist_id" "uuid" NOT NULL,
    "scope_type" "text" NOT NULL,
    "scope_id" "uuid" NOT NULL,
    "can_view" boolean DEFAULT true NOT NULL,
    "can_play" boolean DEFAULT true NOT NULL,
    "can_add_tracks" boolean DEFAULT false NOT NULL,
    "can_remove_tracks" boolean DEFAULT false NOT NULL,
    "can_edit" boolean DEFAULT false NOT NULL,
    "valid_from" timestamp with time zone,
    "valid_until" timestamp with time zone,
    "priority" integer DEFAULT 0 NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "playlist_permissions_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['operator'::"text", 'group'::"text", 'shift'::"text", 'unit'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."playlist_request_tracks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "playlist_request_id" "uuid" NOT NULL,
    "track_id" "uuid" NOT NULL,
    "position" integer NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "playlist_request_tracks_position_check" CHECK (("position" >= 0))
);




CREATE TABLE IF NOT EXISTS "public"."playlist_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "playlist_id" "uuid" NOT NULL,
    "source_url" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "request_id" "uuid",
    "idempotency_key" "uuid" NOT NULL,
    "rejection_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "decided_at" timestamp with time zone,
    "decided_by" "uuid",
    "is_legacy" boolean DEFAULT false NOT NULL,
    "download_job_id" "uuid",
    CONSTRAINT "playlist_requests_decision_check" CHECK (((("status" = 'pending'::"text") AND ("decided_at" IS NULL) AND ("rejection_reason" IS NULL)) OR (("status" = 'approved'::"text") AND ("decided_at" IS NOT NULL) AND ("rejection_reason" IS NULL)) OR (("status" = 'rejected'::"text") AND ("decided_at" IS NOT NULL)))),
    CONSTRAINT "playlist_requests_source_url_check" CHECK (("btrim"("source_url") <> ''::"text")),
    CONSTRAINT "playlist_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."playlist_tracks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "playlist_id" "uuid" NOT NULL,
    "track_id" "uuid" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "added_by_type" "text",
    "added_by_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "playlist_tracks_position_check" CHECK (("position" >= 0))
);




CREATE TABLE IF NOT EXISTS "public"."playlists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unit_id" "uuid",
    "category_id" "uuid",
    "name" "text" NOT NULL,
    "type" "text" DEFAULT 'secondary'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by_operator_id" "uuid",
    "created_by_admin_id" "uuid",
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_url" "text",
    "approval_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "rejection_reason" "text",
    "submitted_at" timestamp with time zone,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "import_status" "text" DEFAULT 'not_started'::"text" NOT NULL,
    "error_message" "text",
    "error_code" "text",
    "error_details" "jsonb",
    "last_error_at" timestamp with time zone,
    "import_started_at" timestamp with time zone,
    "import_finished_at" timestamp with time zone,
    "reviewed_by_admin_id" "uuid",
    "import_error_acknowledged_at" timestamp with time zone,
    CONSTRAINT "playlists_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['draft'::"text", 'pending'::"text", 'approved'::"text", 'rejected'::"text"]))),
    CONSTRAINT "playlists_import_status_check" CHECK (("import_status" = ANY (ARRAY['not_started'::"text", 'processing'::"text", 'success'::"text", 'failed'::"text"]))),
    CONSTRAINT "playlists_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'inactive'::"text", 'archived'::"text"]))),
    CONSTRAINT "playlists_type_check" CHECK (("type" = ANY (ARRAY['principal'::"text", 'secondary'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."shifts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unit_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "days_of_week" smallint[] DEFAULT '{1,2,3,4,5}'::smallint[] NOT NULL,
    "timezone" "text" DEFAULT 'America/Sao_Paulo'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);




CREATE TABLE IF NOT EXISTS "public"."storage_deletion_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "track_id" "uuid" NOT NULL,
    "storage_object_key" "text" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "locked_at" timestamp with time zone,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "storage_deletion_jobs_attempts_check" CHECK (("attempts" >= 0)),
    CONSTRAINT "storage_deletion_jobs_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'running'::"text", 'error'::"text", 'cancelled'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."system_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "key" "text" NOT NULL,
    "scope_type" "text" DEFAULT 'global'::"text" NOT NULL,
    "scope_id" "uuid",
    "value" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "schema_version" integer DEFAULT 1 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "system_settings_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['global'::"text", 'unit'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."tracks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "artist" "text",
    "category_id" "uuid",
    "duration_ms" integer,
    "storage_object_key" "text" NOT NULL,
    "content_hash" "text",
    "mime_type" "text" DEFAULT 'audio/mpeg'::"text" NOT NULL,
    "status" "text" DEFAULT 'available'::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tracks_duration_ms_check" CHECK ((("duration_ms" IS NULL) OR ("duration_ms" > 0))),
    CONSTRAINT "tracks_status_check" CHECK (("status" = ANY (ARRAY['processing'::"text", 'available'::"text", 'unavailable'::"text", 'disabled'::"text", 'deleted'::"text"])))
);




CREATE TABLE IF NOT EXISTS "public"."units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "timezone" "text" DEFAULT 'America/Sao_Paulo'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "address" "text",
    "city" "text",
    "state" "text"
);




COMMENT ON COLUMN "public"."units"."address" IS 'EndereÃ§o do condomÃ­nio (logradouro)';



COMMENT ON COLUMN "public"."units"."city" IS 'Cidade';



COMMENT ON COLUMN "public"."units"."state" IS 'Estado/UF';



ALTER TABLE ONLY "public"."admin_audit_logs"
    ADD CONSTRAINT "admin_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_users"
    ADD CONSTRAINT "admin_users_auth_user_id_key" UNIQUE ("auth_user_id");



ALTER TABLE ONLY "public"."admin_users"
    ADD CONSTRAINT "admin_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_notice_acknowledgements"
    ADD CONSTRAINT "app_notice_ack_notice_operator_uidx" UNIQUE ("notice_id", "operator_id");



ALTER TABLE ONLY "public"."app_notice_acknowledgements"
    ADD CONSTRAINT "app_notice_acknowledgements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_notices"
    ADD CONSTRAINT "app_notices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_release_audit"
    ADD CONSTRAINT "app_release_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_release_note_acknowledgements"
    ADD CONSTRAINT "app_release_note_ack_note_operator_uidx" UNIQUE ("note_id", "operator_id");



ALTER TABLE ONLY "public"."app_release_note_acknowledgements"
    ADD CONSTRAINT "app_release_note_acknowledgements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_release_notes"
    ADD CONSTRAINT "app_release_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_release_notes"
    ADD CONSTRAINT "app_release_notes_release_uidx" UNIQUE ("app_release_id");



ALTER TABLE ONLY "public"."app_release_rules"
    ADD CONSTRAINT "app_release_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_releases_version_key" UNIQUE ("version");



ALTER TABLE ONLY "public"."app_request_idempotency"
    ADD CONSTRAINT "app_request_idempotency_pkey" PRIMARY KEY ("idempotency_key", "rpc_name");



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."call_sessions"
    ADD CONSTRAINT "call_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."challenge_logs"
    ADD CONSTRAINT "challenge_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."challenges"
    ADD CONSTRAINT "challenges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_fingerprint_hash_key" UNIQUE ("fingerprint_hash");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."download_jobs"
    ADD CONSTRAINT "download_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_blocks"
    ADD CONSTRAINT "operator_blocks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_display_name_moderation_terms"
    ADD CONSTRAINT "operator_display_name_moderation_terms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_display_name_moderation_terms"
    ADD CONSTRAINT "operator_display_name_terms_unique" UNIQUE ("normalized_term", "match_type");



ALTER TABLE ONLY "public"."operator_group_members"
    ADD CONSTRAINT "operator_group_members_pkey" PRIMARY KEY ("group_id", "operator_id");



ALTER TABLE ONLY "public"."operator_groups"
    ADD CONSTRAINT "operator_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_groups"
    ADD CONSTRAINT "operator_groups_unit_id_name_key" UNIQUE ("unit_id", "name");



ALTER TABLE ONLY "public"."operator_preferences"
    ADD CONSTRAINT "operator_preferences_pkey" PRIMARY KEY ("operator_id");



ALTER TABLE ONLY "public"."operator_sessions"
    ADD CONSTRAINT "operator_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operator_states"
    ADD CONSTRAINT "operator_states_pkey" PRIMARY KEY ("operator_id");



ALTER TABLE ONLY "public"."operator_status_history"
    ADD CONSTRAINT "operator_status_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operators"
    ADD CONSTRAINT "operators_auth_user_id_key" UNIQUE ("auth_user_id");



ALTER TABLE ONLY "public"."operators"
    ADD CONSTRAINT "operators_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operators"
    ADD CONSTRAINT "operators_unit_id_employee_code_key" UNIQUE ("unit_id", "employee_code");



ALTER TABLE ONLY "public"."playlist_permissions"
    ADD CONSTRAINT "playlist_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."playlist_permissions"
    ADD CONSTRAINT "playlist_permissions_playlist_id_scope_type_scope_id_key" UNIQUE ("playlist_id", "scope_type", "scope_id");



ALTER TABLE ONLY "public"."playlist_request_tracks"
    ADD CONSTRAINT "playlist_request_tracks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."playlist_request_tracks"
    ADD CONSTRAINT "playlist_request_tracks_request_track_key" UNIQUE ("playlist_request_id", "track_id");



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_idempotency_key_key" UNIQUE ("idempotency_key");



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."playlist_tracks"
    ADD CONSTRAINT "playlist_tracks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."playlist_tracks"
    ADD CONSTRAINT "playlist_tracks_playlist_id_track_id_key" UNIQUE ("playlist_id", "track_id");



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."storage_deletion_jobs"
    ADD CONSTRAINT "storage_deletion_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."storage_deletion_jobs"
    ADD CONSTRAINT "storage_deletion_jobs_track_id_key" UNIQUE ("track_id");



ALTER TABLE ONLY "public"."system_settings"
    ADD CONSTRAINT "system_settings_key_scope_type_scope_id_key" UNIQUE ("key", "scope_type", "scope_id");



ALTER TABLE ONLY "public"."system_settings"
    ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tracks"
    ADD CONSTRAINT "tracks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tracks"
    ADD CONSTRAINT "tracks_storage_object_key_key" UNIQUE ("storage_object_key");



ALTER TABLE ONLY "public"."units"
    ADD CONSTRAINT "units_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."units"
    ADD CONSTRAINT "units_pkey" PRIMARY KEY ("id");



CREATE INDEX "admin_audit_logs_admin_user_id_occurred_at_idx" ON "public"."admin_audit_logs" USING "btree" ("admin_user_id", "occurred_at" DESC);



CREATE INDEX "admin_audit_logs_entity_type_occurred_at_idx" ON "public"."admin_audit_logs" USING "btree" ("entity_type", "occurred_at" DESC);



CREATE INDEX "admin_users_active_role_idx" ON "public"."admin_users" USING "btree" ("active", "role");



CREATE INDEX "app_notice_ack_operator_idx" ON "public"."app_notice_acknowledgements" USING "btree" ("operator_id", "read_at" DESC);



CREATE INDEX "app_notices_audience_idx" ON "public"."app_notices" USING "btree" ("audience_type", "condominium_id", "operator_id", "shift");



CREATE INDEX "app_notices_severity_idx" ON "public"."app_notices" USING "btree" ("severity");



CREATE INDEX "app_notices_status_window_idx" ON "public"."app_notices" USING "btree" ("status", "starts_at", "ends_at");



CREATE INDEX "app_release_audit_release_created_idx" ON "public"."app_release_audit" USING "btree" ("release_id", "created_at" DESC);



CREATE INDEX "app_release_note_ack_operator_idx" ON "public"."app_release_note_acknowledgements" USING "btree" ("operator_id", "read_at" DESC);



CREATE INDEX "app_release_notes_status_published_idx" ON "public"."app_release_notes" USING "btree" ("status", "published_at" DESC);



CREATE INDEX "app_release_notes_version_number_idx" ON "public"."app_release_notes" USING "btree" ("version_number");



CREATE INDEX "app_releases_channel_status_idx" ON "public"."app_releases" USING "btree" ("channel", "status", "released_at" DESC);



CREATE INDEX "app_releases_created_at_idx" ON "public"."app_releases" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "app_releases_current_channel_uidx" ON "public"."app_releases" USING "btree" ("channel") WHERE ("is_current" = true);



CREATE INDEX "app_versions_channel_status_idx" ON "public"."app_releases" USING "btree" ("channel", "status");



CREATE INDEX "call_sessions_session_id_status_idx" ON "public"."call_sessions" USING "btree" ("session_id", "status");



CREATE INDEX "categories_active_sort_order_idx" ON "public"."categories" USING "btree" ("active", "sort_order");



CREATE INDEX "challenge_logs_operator_id_status_expires_at_idx" ON "public"."challenge_logs" USING "btree" ("operator_id", "status", "expires_at");



CREATE INDEX "challenge_logs_operator_session_idx" ON "public"."challenge_logs" USING "btree" ("operator_id", "session_id", "created_at" DESC);



CREATE INDEX "challenges_unit_id_status_idx" ON "public"."challenges" USING "btree" ("unit_id", "status");



CREATE INDEX "challenges_unit_status_idx" ON "public"."challenges" USING "btree" ("unit_id", "status");



CREATE INDEX "devices_unit_id_status_idx" ON "public"."devices" USING "btree" ("unit_id", "status");



CREATE INDEX "download_jobs_playlist_idx" ON "public"."download_jobs" USING "btree" ("playlist_id");



CREATE INDEX "download_jobs_playlist_request_created_idx" ON "public"."download_jobs" USING "btree" ("playlist_request_id", "created_at" DESC) WHERE ("playlist_request_id" IS NOT NULL);



CREATE INDEX "download_jobs_status_idx" ON "public"."download_jobs" USING "btree" ("status");



CREATE INDEX "feedback_created_idx" ON "public"."feedback" USING "btree" ("created_at" DESC);



CREATE INDEX "feedback_message_trgm_idx" ON "public"."feedback" USING "gin" ("message" "public"."gin_trgm_ops");



CREATE INDEX "feedback_status_idx" ON "public"."feedback" USING "btree" ("status");



CREATE INDEX "feedback_type_created_idx" ON "public"."feedback" USING "btree" ("type", "created_at" DESC);



CREATE INDEX "feedback_unit_idx" ON "public"."feedback" USING "btree" ("unit_id");



CREATE UNIQUE INDEX "one_open_challenge_per_operator_idx" ON "public"."challenge_logs" USING "btree" ("operator_id") WHERE ("status" = ANY (ARRAY['scheduled'::"text", 'pending'::"text", 'displayed'::"text", 'paused'::"text", 'idle'::"text"]));



CREATE INDEX "operational_events_event_type_received_at_idx" ON "public"."operational_events" USING "btree" ("event_type", "received_at" DESC);



CREATE INDEX "operational_events_operator_id_received_at_idx" ON "public"."operational_events" USING "btree" ("operator_id", "received_at" DESC);



CREATE UNIQUE INDEX "operational_events_session_id_idempotency_key_idx" ON "public"."operational_events" USING "btree" ("session_id", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "operator_blocks_operator_id_status_blocked_until_idx" ON "public"."operator_blocks" USING "btree" ("operator_id", "status", "blocked_until");



CREATE INDEX "operator_display_name_requests_operator_time_idx" ON "public"."operator_display_name_requests" USING "btree" ("operator_id", "occurred_at" DESC);



CREATE INDEX "operator_display_name_requests_result_time_idx" ON "public"."operator_display_name_requests" USING "btree" ("moderation_result", "occurred_at" DESC);



CREATE INDEX "operator_display_name_requests_review_time_idx" ON "public"."operator_display_name_requests" USING "btree" ("review_status", "occurred_at" DESC);



CREATE INDEX "operator_display_name_requests_unit_time_idx" ON "public"."operator_display_name_requests" USING "btree" ("unit_id", "occurred_at" DESC);



CREATE INDEX "operator_display_name_terms_active_idx" ON "public"."operator_display_name_moderation_terms" USING "btree" ("active", "updated_at" DESC);



CREATE INDEX "operator_group_members_operator_id_idx" ON "public"."operator_group_members" USING "btree" ("operator_id");



CREATE INDEX "operator_sessions_device_id_status_idx" ON "public"."operator_sessions" USING "btree" ("device_id", "status");



CREATE INDEX "operator_sessions_last_heartbeat_at_idx" ON "public"."operator_sessions" USING "btree" ("last_heartbeat_at");



CREATE INDEX "operator_sessions_operator_id_status_idx" ON "public"."operator_sessions" USING "btree" ("operator_id", "status");



CREATE INDEX "operator_states_call_active_idx" ON "public"."operator_states" USING "btree" ("call_active", "updated_at") WHERE ("call_active" = true);



CREATE INDEX "operator_states_status_updated_at_idx" ON "public"."operator_states" USING "btree" ("status", "updated_at");



CREATE INDEX "operator_status_history_operator_id_occurred_at_idx" ON "public"."operator_status_history" USING "btree" ("operator_id", "occurred_at" DESC);



CREATE INDEX "operators_active_idx" ON "public"."operators" USING "btree" ("active");



CREATE INDEX "operators_display_name_trgm_idx" ON "public"."operators" USING "gin" ("display_name" "public"."gin_trgm_ops");



CREATE INDEX "operators_role_idx" ON "public"."operators" USING "btree" ("role");



CREATE INDEX "operators_unit_id_active_idx" ON "public"."operators" USING "btree" ("unit_id", "active");



CREATE UNIQUE INDEX "operators_username_lower_uidx" ON "public"."operators" USING "btree" ("lower"("username")) WHERE ("username" IS NOT NULL);



CREATE INDEX "operators_username_trgm_idx" ON "public"."operators" USING "gin" ("username" "public"."gin_trgm_ops");



CREATE INDEX "playlist_permissions_scope_type_scope_id_idx" ON "public"."playlist_permissions" USING "btree" ("scope_type", "scope_id");



CREATE INDEX "playlist_request_tracks_request_position_idx" ON "public"."playlist_request_tracks" USING "btree" ("playlist_request_id", "position", "captured_at");



CREATE INDEX "playlist_request_tracks_track_idx" ON "public"."playlist_request_tracks" USING "btree" ("track_id");



CREATE INDEX "playlist_requests_download_job_idx" ON "public"."playlist_requests" USING "btree" ("download_job_id") WHERE ("download_job_id" IS NOT NULL);



CREATE UNIQUE INDEX "playlist_requests_one_legacy_per_playlist_idx" ON "public"."playlist_requests" USING "btree" ("playlist_id") WHERE "is_legacy";



CREATE INDEX "playlist_requests_operator_created_idx" ON "public"."playlist_requests" USING "btree" ("operator_id", "created_at" DESC);



CREATE INDEX "playlist_requests_playlist_pending_idx" ON "public"."playlist_requests" USING "btree" ("playlist_id", "created_at" DESC) WHERE ("status" = 'pending'::"text");



CREATE INDEX "playlist_tracks_playlist_id_position_idx" ON "public"."playlist_tracks" USING "btree" ("playlist_id", "position");



CREATE INDEX "playlists_approval_idx" ON "public"."playlists" USING "btree" ("approval_status");



CREATE INDEX "playlists_created_by_operator_idx" ON "public"."playlists" USING "btree" ("created_by_operator_id", "created_at" DESC);



CREATE INDEX "playlists_error_message_trgm_idx" ON "public"."playlists" USING "gin" ("error_message" "public"."gin_trgm_ops");



CREATE INDEX "playlists_import_status_created_idx" ON "public"."playlists" USING "btree" ("import_status", "created_at" DESC);



CREATE UNIQUE INDEX "playlists_principal_por_operador" ON "public"."playlists" USING "btree" ("created_by_operator_id") WHERE (("type" = 'principal'::"text") AND ("created_by_operator_id" IS NOT NULL));



CREATE INDEX "playlists_rejection_reason_trgm_idx" ON "public"."playlists" USING "gin" ("rejection_reason" "public"."gin_trgm_ops");



CREATE INDEX "playlists_source_url_trgm_idx" ON "public"."playlists" USING "gin" ("source_url" "public"."gin_trgm_ops");



CREATE INDEX "playlists_submitted_at_idx" ON "public"."playlists" USING "btree" ("submitted_at" DESC);



CREATE INDEX "playlists_type_created_idx" ON "public"."playlists" USING "btree" ("type", "created_at" DESC);



CREATE INDEX "playlists_unit_id_status_type_idx" ON "public"."playlists" USING "btree" ("unit_id", "status", "type");



CREATE INDEX "shifts_unit_id_active_idx" ON "public"."shifts" USING "btree" ("unit_id", "active");



CREATE INDEX "storage_deletion_jobs_claim_idx" ON "public"."storage_deletion_jobs" USING "btree" ("status", "next_attempt_at", "created_at");



CREATE INDEX "tracks_status_category_id_title_idx" ON "public"."tracks" USING "btree" ("status", "category_id", "title");



CREATE INDEX "units_active_idx" ON "public"."units" USING "btree" ("active");



CREATE INDEX "units_active_name_idx" ON "public"."units" USING "btree" ("active", "name");



CREATE INDEX "units_city_trgm_idx" ON "public"."units" USING "gin" ("city" "public"."gin_trgm_ops");



CREATE INDEX "units_code_trgm_idx" ON "public"."units" USING "gin" ("code" "public"."gin_trgm_ops");



CREATE INDEX "units_name_trgm_idx" ON "public"."units" USING "gin" ("name" "public"."gin_trgm_ops");




-- Private functions referenced by the authoritative public-schema snapshot.
-- Their final definitions are sourced from the deployed local migration history.
create or replace function private.app_release_required_ready(p_release public.app_releases)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_release.version is not null
     and p_release.version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'
     and nullif(btrim(coalesce(p_release.title, '')), '') is not null
     and nullif(btrim(coalesce(p_release.manifest_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.installer_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.blockmap_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.sha512, '')), '') is not null
     and p_release.size_bytes is not null
     and p_release.size_bytes > 0;
$$;

create or replace function private.capture_admin_display_name_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source text := nullif(current_setting('app.audit_source', true), '');
  v_admin public.admin_users%rowtype;
begin
  if old.display_name is not distinct from new.display_name
     or v_source in ('operator_app', 'admin_approval') then
    return new;
  end if;

  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
  limit 1;

  insert into public.operator_display_name_requests (
    operator_id,
    unit_id,
    actor_auth_user_id,
    actor_type,
    actor_admin_user_id,
    previous_name,
    requested_name,
    normalized_name,
    compact_name,
    applied_name,
    moderation_result,
    review_status,
    source,
    occurred_at,
    applied_at
  ) values (
    new.id,
    new.unit_id,
    auth.uid(),
    case when v_admin.id is null then 'system' else 'admin' end,
    v_admin.id,
    old.display_name,
    new.display_name,
    private.normalize_operator_display_name(new.display_name, false),
    private.normalize_operator_display_name(new.display_name, true),
    new.display_name,
    'allowed',
    'not_required',
    case when v_admin.id is null then 'system' else 'admin_panel' end,
    clock_timestamp(),
    clock_timestamp()
  );

  return new;
end;
$$;

create or replace function private.challenge_answer_definition_is_valid(
  p_answer_definition jsonb
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_position integer;
  v_option jsonb;
begin
  if coalesce(jsonb_typeof(p_answer_definition), '') <> 'object'
     or coalesce(jsonb_typeof(p_answer_definition->'alternatives'), '') <> 'array'
     or jsonb_array_length(p_answer_definition->'alternatives') <> 4
     or coalesce(jsonb_typeof(p_answer_definition->'options'), '') <> 'array'
     or jsonb_array_length(p_answer_definition->'options') <> 4
     or upper(coalesce(p_answer_definition->>'correct', '')) not in ('A', 'B', 'C', 'D')
     or p_answer_definition->>'correct_option_id'
        <> 'option_' || lower(p_answer_definition->>'correct') then
    return false;
  end if;

  for v_position in 0..3 loop
    v_option := p_answer_definition->'options'->v_position;
    if nullif(btrim(p_answer_definition->'alternatives'->>v_position), '') is null
       or jsonb_typeof(v_option) <> 'object'
       or v_option->>'id' <> 'option_' || chr(ascii('a') + v_position)
       or nullif(btrim(v_option->>'text'), '') is null
       or v_option->>'text' is distinct from p_answer_definition->'alternatives'->>v_position then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

create or replace function private.challenge_rules(p_unit_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select value from public.system_settings where active and key = 'challenge_rules' and scope_type = 'unit' and scope_id = p_unit_id order by revision desc limit 1),
    (select value from public.system_settings where active and key = 'challenge_rules' and scope_type = 'global' order by revision desc limit 1),
    '{"min_interval_seconds":180,"max_interval_seconds":300,"response_seconds":60,"abandon_block_seconds":300,"error_block_seconds":[300,900,3600]}'::jsonb
  )
$$;

create or replace function private.challenge_schedule_at(
  p_rules jsonb,
  p_delay_seconds integer,
  p_reference timestamptz default now()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_timezone text := coalesce(nullif(p_rules->>'timezone', ''), 'America/Sao_Paulo');
  v_start time := coalesce(nullif(p_rules->>'active_window_start', '')::time, '00:00'::time);
  v_end time := coalesce(nullif(p_rules->>'active_window_end', '')::time, '00:00'::time);
  v_local_reference timestamp;
  v_local_base timestamp;
  v_local_candidate timestamp;
  v_end_boundary timestamp;
begin
  v_local_reference := p_reference at time zone v_timezone;

  -- Equal times mean an unrestricted 24-hour window.
  if v_start = v_end then
    return p_reference + make_interval(secs => greatest(p_delay_seconds, 0));
  end if;

  if v_start < v_end then
    if v_local_reference::time < v_start then
      v_local_base := v_local_reference::date + v_start;
    elsif v_local_reference::time >= v_end then
      v_local_base := (v_local_reference::date + 1) + v_start;
    else
      v_local_base := v_local_reference;
    end if;

    v_local_candidate := v_local_base + make_interval(secs => greatest(p_delay_seconds, 0));
    v_end_boundary := v_local_base::date + v_end;

    if v_local_candidate >= v_end_boundary then
      v_local_candidate := (v_local_base::date + 1) + v_start
        + make_interval(secs => greatest(p_delay_seconds, 0));
    end if;
  else
    -- Overnight window, for example 18:00-06:00.
    if v_local_reference::time >= v_start or v_local_reference::time < v_end then
      v_local_base := v_local_reference;
    else
      v_local_base := v_local_reference::date + v_start;
    end if;

    v_local_candidate := v_local_base + make_interval(secs => greatest(p_delay_seconds, 0));
    if v_local_base::time >= v_start then
      v_end_boundary := (v_local_base::date + 1) + v_end;
    else
      v_end_boundary := v_local_base::date + v_end;
    end if;

    if v_local_candidate >= v_end_boundary then
      v_local_candidate := v_end_boundary::date + v_start
        + make_interval(secs => greatest(p_delay_seconds, 0));
    end if;
  end if;

  return v_local_candidate at time zone v_timezone;
end
$$;

create or replace function private.current_operator_challenge(
  p_operator_id uuid,
  p_session_id uuid
)
returns public.challenge_logs
language sql
stable
security definer
set search_path = ''
as $$
  select cl.*
  from public.challenge_logs cl
  where cl.operator_id = p_operator_id
    and cl.session_id = p_session_id
    and cl.status in ('scheduled', 'pending', 'displayed', 'paused', 'idle')
  order by cl.created_at desc
  limit 1
$$;

create or replace function private.current_operator_challenge(p_operator_id uuid)
returns public.challenge_logs
language sql
stable
security definer
set search_path = ''
as $$
  select cl.*
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.operator_id = p_operator_id
    and cl.status in ('scheduled', 'pending', 'displayed', 'paused', 'idle')
  order by s.started_at desc, cl.created_at desc
  limit 1
$$;

create or replace function private.defer_challenge_after_call()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response_seconds integer;
begin
  if old.status = 'paused'
     and new.status = 'pending'
     and old.pause_reason = 'call_active' then
    select coalesce((private.challenge_rules(o.unit_id)->>'response_seconds')::integer, 60)
    into v_response_seconds
    from public.operators o
    where o.id = new.operator_id;

    new.status := 'scheduled';
    new.scheduled_for := now() + interval '90 seconds';
    new.expires_at := new.scheduled_for + make_interval(secs => greatest(coalesce(v_response_seconds, 60), 15));
  end if;
  return new;
end;
$$;

create or replace function private.enforce_principal_track_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type text;
  v_count integer;
begin
  -- Serializa importacoes/mutacoes da mesma playlist; o lock tambem protege
  -- contagens contra duas transacoes concorrentes.
  select type into v_type from public.playlists where id = new.playlist_id for update;
  if not found then
    return new;
  end if;
  if v_type = 'principal' then
    select count(*) into v_count from public.playlist_tracks where playlist_id = new.playlist_id;
    if v_count >= 170 then
      raise exception 'PRINCIPAL_TRACK_LIMIT_REACHED'
        using errcode = 'check_violation', detail = 'A playlist Principal aceita no maximo 170 faixas.';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.enforce_track_duration_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.duration_ms is not null and new.duration_ms > 960000 then
    raise exception 'TRACK_DURATION_LIMIT_EXCEEDED'
      using errcode = 'check_violation', detail = 'A faixa excede 960 segundos.';
  end if;
  return new;
end;
$$;

create or replace function private.log_app_release_audit(
  p_release_id uuid,
  p_action text,
  p_previous_status text,
  p_new_status text,
  p_actor_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  insert into public.app_release_audit (
    release_id, action, previous_status, new_status, actor_id, metadata
  ) values (
    p_release_id,
    p_action,
    p_previous_status,
    p_new_status,
    p_actor_id,
    coalesce(p_metadata, '{}'::jsonb)
  );

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    p_actor_id,
    'app_release_' || p_action,
    'app_release',
    p_release_id,
    jsonb_build_object('status', p_previous_status),
    jsonb_build_object('status', p_new_status, 'metadata', coalesce(p_metadata, '{}'::jsonb)),
    nullif(coalesce(p_metadata->>'reason', ''), ''),
    now()
  );
end;
$$;

create or replace function private.normalize_operator_display_name(
  p_value text,
  p_compact boolean default false
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text;
begin
  v_value := lower(extensions.unaccent(coalesce(p_value, '')));
  if p_compact then
    return regexp_replace(v_value, '[^[:alnum:]]+', '', 'g');
  end if;
  return btrim(
    regexp_replace(
      regexp_replace(v_value, '[^[:alnum:]]+', ' ', 'g'),
      '[[:space:]]+',
      ' ',
      'g'
    )
  );
end;
$$;

create or replace function private.operator_playlist_capabilities(p_type text, p_status text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'can_rename', p_status <> 'archived',
    'can_remove_tracks', p_status <> 'archived',
    'can_reorder_tracks', p_status <> 'archived',
    'can_add_tracks_from_principal', p_type = 'secondary' and p_status <> 'archived',
    'can_archive', p_type = 'secondary' and p_status <> 'archived',
    'can_remove_from_principal', p_type = 'principal' and p_status <> 'archived',
    'can_edit_principal_name', p_type = 'principal' and p_status <> 'archived',
    'can_delete_playlist', false
  );
$$;

create or replace function private.operator_runtime_payload(
  p_operator_id uuid,
  p_session_id uuid,
  p_result text
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_state public.operator_states%rowtype;
  v_op public.operators%rowtype;
  v_sess public.operator_sessions%rowtype;
  v_shift_info jsonb;
  v_block public.operator_blocks%rowtype;
  v_challenge record;
  v_pending_challenge jsonb := null;
  v_status_operacional text := 'offline';
  v_next_screen text := 'login';
  v_blocked_until timestamptz := null;
  v_expires_at timestamptz := null;
begin
  select * into v_op
  from public.operators
  where id = p_operator_id;

  select * into v_sess
  from public.operator_sessions
  where id = p_session_id
    and operator_id = p_operator_id;

  select * into v_state
  from public.operator_states
  where operator_id = p_operator_id;

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > now())
  order by started_at desc
  limit 1;

  if v_block.id is not null then
    v_blocked_until := v_block.blocked_until;
  end if;

  select
    cl.id,
    cl.challenge_id,
    cl.status,
    cl.expires_at,
    cl.paused_at,
    cl.resumed_at,
    cl.pause_reason,
    c.title,
    c.prompt,
    c.kind,
    c.answer_definition
  into v_challenge
  from public.challenge_logs cl
  join public.challenges c on c.id = cl.challenge_id
  where cl.operator_id = p_operator_id
    and cl.status in ('pending', 'displayed', 'paused')
    and (p_session_id is null or cl.session_id is null or cl.session_id = p_session_id)
  order by cl.created_at desc
  limit 1;

  if v_challenge.id is not null then
    v_expires_at := case
      when coalesce(v_state.call_active, false) then null
      else v_challenge.expires_at
    end;
    v_pending_challenge := jsonb_build_object(
      'id', v_challenge.id,
      'challenge_id', v_challenge.challenge_id,
      'status', v_challenge.status,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', v_challenge.answer_definition,
      'expires_at', v_expires_at,
      'paused_at', v_challenge.paused_at,
      'pause_reason', v_challenge.pause_reason
    );
  end if;

  v_status_operacional := case coalesce(v_state.status, 'offline')
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else 'offline'
  end;

  v_next_screen := case
    when coalesce(v_state.call_active, false) then 'call'
    when v_block.id is not null then 'blocked'
    when v_pending_challenge is not null then 'challenge'
    when coalesce(v_state.status, 'offline') = 'outside_shift' then 'outside_shift'
    when coalesce(v_state.status, 'offline') = 'offline' then 'login'
    else 'player'
  end;

  v_shift_info := public._app_shift_info(coalesce(v_sess.shift_id, v_op.default_shift_id));

  return jsonb_build_object(
    'result', p_result,
    'call_active', coalesce(v_state.call_active, false),
    'status_operacional', v_status_operacional,
    'server_now', to_char((now() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'blocked_until', v_blocked_until,
    'pending_challenge', v_pending_challenge,
    'expires_at', v_expires_at,
    'next_screen', v_next_screen,
    'operator_state', jsonb_build_object(
      'status', coalesce(v_state.status, 'offline'),
      'revision', coalesce(v_state.revision, 0),
      'effective_at', v_state.effective_at,
      'call_active', coalesce(v_state.call_active, false)
    ),
    'session', case when v_sess.id is null then null else jsonb_build_object(
      'id', v_sess.id,
      'status', v_sess.status,
      'expires_at', v_sess.expires_at
    ) end,
    'shift', v_shift_info,
    'block', case when v_block.id is null then null else jsonb_build_object(
      'id', v_block.id,
      'reason_code', v_block.reason_code,
      'blocked_until', v_block.blocked_until
    ) end
  );
end;
$$;

create or replace function private.require_admin_for_backend(
  p_allowed_roles text[] default null,
  p_unit_id uuid default null
)
returns public.admin_users
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'acesso_negado';
  end if;

  if p_allowed_roles is not null and not (v_admin.role = any(p_allowed_roles)) then
    raise exception 'permissao_insuficiente';
  end if;

  if p_unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(p_unit_id) then
    raise exception 'fora_do_escopo_da_unidade';
  end if;

  return v_admin;
end;
$$;

create or replace function private.require_available_track_link()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_status text;
begin
  select status into v_status from public.tracks where id = new.track_id for share;
  if not found or v_status <> 'available' then
    raise exception 'TRACK_NOT_AVAILABLE' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create or replace function private.require_release_admin()
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid;
begin
  select public.current_admin_user_id() into v_admin_id;
  if v_admin_id is null or not public.is_release_admin() then
    raise exception 'forbidden';
  end if;
  return v_admin_id;
end;
$$;

create or replace function private.set_challenge_operator_state(
  p_operator_id uuid,
  p_session_id uuid,
  p_status text,
  p_reason_code text
)
returns public.operator_states
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous public.operator_states%rowtype;
  v_current public.operator_states%rowtype;
  v_target_status text := p_status;
begin
  if v_target_status not in (
    'active', 'in_call', 'idle', 'blocked', 'outside_shift', 'offline'
  ) then
    raise exception 'status_operacional_invalido';
  end if;

  select * into v_previous
  from public.operator_states
  where operator_id = p_operator_id
  for update;

  if coalesce(v_previous.call_active, false) and v_target_status <> 'in_call' then
    v_target_status := 'in_call';
  end if;

  if v_previous.operator_id is null then
    insert into public.operator_states(
      operator_id,
      session_id,
      status,
      activity,
      reason_code,
      call_active,
      effective_at,
      revision,
      updated_at
    )
    values (
      p_operator_id,
      p_session_id,
      v_target_status,
      case when v_target_status = 'idle' then 'challenge_idle' else null end,
      p_reason_code,
      false,
      now(),
      1,
      now()
    )
    returning * into v_current;

    insert into public.operator_status_history(
      operator_id,
      session_id,
      from_status,
      to_status,
      reason_code,
      source,
      occurred_at,
      state_revision
    )
    values (
      p_operator_id,
      p_session_id,
      null,
      v_target_status,
      p_reason_code,
      'challenge_backend',
      now(),
      v_current.revision
    );
  elsif v_previous.status is distinct from v_target_status
     or v_previous.session_id is distinct from p_session_id then
    update public.operator_states
    set session_id = p_session_id,
        status = v_target_status,
        activity = case when v_target_status = 'idle' then 'challenge_idle' else null end,
        reason_code = p_reason_code,
        effective_at = now(),
        revision = revision + 1,
        updated_at = now()
    where operator_id = p_operator_id
    returning * into v_current;

    insert into public.operator_status_history(
      operator_id,
      session_id,
      from_status,
      to_status,
      reason_code,
      source,
      occurred_at,
      state_revision
    )
    values (
      p_operator_id,
      p_session_id,
      v_previous.status,
      v_target_status,
      p_reason_code,
      'challenge_backend',
      now(),
      v_current.revision
    );
  else
    v_current := v_previous;
  end if;

  return v_current;
end
$$;

create or replace function private.challenge_public_options(
  p_answer_definition jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object('id', value->>'id', 'text', value->>'text')
      order by ordinality
    ),
    '[]'::jsonb
  )
  from jsonb_array_elements(coalesce(p_answer_definition->'options', '[]'::jsonb))
    with ordinality
$$;

revoke all on function private.challenge_public_options(jsonb) from public;

CREATE OR REPLACE FUNCTION private.challenge_operational_snapshot(
  p_operator_id uuid,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_operator public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
  v_state public.operator_states%rowtype;
  v_challenge public.challenge_logs%rowtype;
  v_block public.operator_blocks%rowtype;
  v_shift_info jsonb;
  v_target_status text;
  v_reason_code text;
  v_status_operacional text;
  v_finished_blocks integer := 0;
begin
  update public.operator_blocks
     set status = 'finished',
         finished_at = coalesce(finished_at, pg_catalog.now()),
         revision = revision + 1
   where operator_id = p_operator_id
     and status = 'active'
     and blocked_until is not null
     and blocked_until <= pg_catalog.now();

  get diagnostics v_finished_blocks = row_count;

  select *
    into v_operator
    from public.operators
   where id = p_operator_id;

  select *
    into v_session
    from public.operator_sessions
   where id = p_session_id
     and operator_id = p_operator_id;

  select *
    into v_state
    from public.operator_states
   where operator_id = p_operator_id;

  select *
    into v_block
    from public.operator_blocks
   where operator_id = p_operator_id
     and status = 'active'
     and (
       blocked_until is null
       or blocked_until > pg_catalog.now()
     )
   order by started_at desc, id desc
   limit 1;

  select *
    into v_challenge
    from private.current_operator_challenge(
      p_operator_id,
      p_session_id
    );

  v_shift_info := public._app_shift_info(
    coalesce(
      v_session.shift_id,
      v_operator.default_shift_id
    )
  );

  if coalesce(v_state.call_active, false) then
    v_target_status := 'in_call';
    v_reason_code := 'call_active';

  elsif v_block.id is not null then
    v_target_status := 'blocked';
    v_reason_code := v_block.reason_code;

  elsif v_challenge.status = 'idle' then
    v_target_status := 'idle';
    v_reason_code := 'challenge_expired';

  elsif not coalesce(
    (v_shift_info->>'in_shift')::boolean,
    true
  ) then
    v_target_status := 'outside_shift';
    v_reason_code := 'outside_shift';

  else
    v_target_status := 'active';

    v_reason_code := case
      when v_finished_blocks > 0
        then 'challenge_block_finished'
      else 'challenge_state_synced'
    end;
  end if;

  v_state := private.set_challenge_operator_state(
    p_operator_id,
    p_session_id,
    v_target_status,
    v_reason_code
  );

  v_status_operacional := case v_state.status
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else v_state.status
  end;

  return pg_catalog.jsonb_build_object(
    'status_operacional',
    v_status_operacional,
    'operator_state',
    pg_catalog.jsonb_build_object(
      'status',
      v_state.status,
      'revision',
      v_state.revision,
      'effective_at',
      v_state.effective_at,
      'call_active',
      coalesce(v_state.call_active, false)
    )
  );
end;
$function$;

REVOKE ALL ON FUNCTION
  private.challenge_operational_snapshot(uuid, uuid)
FROM PUBLIC;

create or replace function private.challenge_payload(
  p_operator_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_block public.operator_blocks%rowtype;
  v_operational_snapshot jsonb;
  v_payload jsonb;
begin
  v_operational_snapshot := private.challenge_operational_snapshot(
    p_operator_id,
    p_session_id
  );

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > now())
  order by started_at desc, id desc
  limit 1;

  if v_block.id is not null then
    v_payload := jsonb_build_object(
      'next_screen', 'blocked',
      'blocked_until', v_block.blocked_until,
      'block_reason', v_block.reason_code,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_log
  from private.current_operator_challenge(p_operator_id, p_session_id);

  if v_log.id is null then
    v_payload := jsonb_build_object('next_screen', 'player', 'server_now', now());
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  if v_log.status = 'idle' then
    v_payload := jsonb_build_object(
      'next_screen', 'idle',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'paused' then
    v_payload := jsonb_build_object(
      'next_screen', 'paused_by_call',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'scheduled' and v_log.scheduled_for > now() then
    v_payload := jsonb_build_object(
      'next_screen', 'player',
      'next_challenge_at', v_log.scheduled_for,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  v_payload := jsonb_build_object(
    'next_screen', 'challenge',
    'server_now', now(),
    'challenge', jsonb_build_object(
      'log_id', v_log.id,
      'id', v_challenge.id,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', jsonb_build_object(
        'alternatives', v_challenge.answer_definition->'alternatives',
        'options', private.challenge_public_options(v_challenge.answer_definition)
      ),
      'expires_at', v_log.expires_at
    )
  );
  return v_payload || v_operational_snapshot;
end
$$;

create or replace function private.statistics_reset_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select nullif(value->>'reset_at', '')::timestamptz
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
$$;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    return null;
  end if;
  return p_value::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;
CREATE OR REPLACE TRIGGER "audit_admin_users" AFTER INSERT OR DELETE OR UPDATE ON "public"."admin_users" FOR EACH ROW EXECUTE FUNCTION "public"."audit_admin_change"();



CREATE OR REPLACE TRIGGER "audit_operators" AFTER INSERT OR DELETE OR UPDATE ON "public"."operators" FOR EACH ROW EXECUTE FUNCTION "public"."audit_admin_change"();



CREATE OR REPLACE TRIGGER "audit_units" AFTER INSERT OR DELETE OR UPDATE ON "public"."units" FOR EACH ROW EXECUTE FUNCTION "public"."audit_admin_change"();



CREATE OR REPLACE TRIGGER "capture_admin_display_name_change" AFTER UPDATE OF "display_name" ON "public"."operators" FOR EACH ROW EXECUTE FUNCTION "private"."capture_admin_display_name_change"();



CREATE OR REPLACE TRIGGER "challenge_defer_after_call" BEFORE UPDATE ON "public"."challenge_logs" FOR EACH ROW EXECUTE FUNCTION "private"."defer_challenge_after_call"();



CREATE OR REPLACE TRIGGER "t_adminusers_updated" BEFORE UPDATE ON "public"."admin_users" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_app_notice_ack_updated_at" BEFORE UPDATE ON "public"."app_notice_acknowledgements" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "t_app_notices_metadata" BEFORE INSERT OR UPDATE ON "public"."app_notices" FOR EACH ROW EXECUTE FUNCTION "public"."sync_app_notice_metadata"();



CREATE OR REPLACE TRIGGER "t_app_release_note_ack_updated_at" BEFORE UPDATE ON "public"."app_release_note_acknowledgements" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "t_app_release_notes_metadata" BEFORE INSERT OR UPDATE ON "public"."app_release_notes" FOR EACH ROW EXECUTE FUNCTION "public"."sync_app_release_note_metadata"();



CREATE OR REPLACE TRIGGER "t_app_releases_immutable_files" BEFORE UPDATE ON "public"."app_releases" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_released_app_release_file_changes"();



CREATE OR REPLACE TRIGGER "t_app_releases_updated_at" BEFORE UPDATE ON "public"."app_releases" FOR EACH ROW EXECUTE FUNCTION "public"."touch_app_release_updated_at"();



CREATE OR REPLACE TRIGGER "t_categories_updated" BEFORE UPDATE ON "public"."categories" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_challenges_updated" BEFORE UPDATE ON "public"."challenges" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_devices_updated" BEFORE UPDATE ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_ogroups_updated" BEFORE UPDATE ON "public"."operator_groups" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_operators_updated" BEFORE UPDATE ON "public"."operators" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_playlists_updated" BEFORE UPDATE ON "public"."playlists" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_plperms_updated" BEFORE UPDATE ON "public"."playlist_permissions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_relrules_updated" BEFORE UPDATE ON "public"."app_release_rules" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_sessions_updated" BEFORE UPDATE ON "public"."operator_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_settings_updated" BEFORE UPDATE ON "public"."system_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_shifts_updated" BEFORE UPDATE ON "public"."shifts" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_states_updated" BEFORE UPDATE ON "public"."operator_states" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_touch_release_note_on_release" AFTER UPDATE OF "status" ON "public"."app_releases" FOR EACH ROW EXECUTE FUNCTION "public"."touch_release_note_on_release"();



CREATE OR REPLACE TRIGGER "t_tracks_updated" BEFORE UPDATE ON "public"."tracks" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "t_units_updated" BEFORE UPDATE ON "public"."units" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_capture_playlist_request_track" AFTER INSERT OR UPDATE OF "playlist_id", "track_id", "position" ON "public"."playlist_tracks" FOR EACH ROW EXECUTE FUNCTION "public"."capture_playlist_request_track"();



CREATE OR REPLACE TRIGGER "trg_enforce_principal_track_limit" BEFORE INSERT ON "public"."playlist_tracks" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_principal_track_limit"();



CREATE OR REPLACE TRIGGER "trg_enforce_secondary_limit" BEFORE INSERT ON "public"."playlists" FOR EACH ROW EXECUTE FUNCTION "public"."_enforce_secondary_limit"();



CREATE OR REPLACE TRIGGER "trg_enforce_track_duration_limit" BEFORE INSERT OR UPDATE OF "duration_ms" ON "public"."tracks" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_track_duration_limit"();



CREATE OR REPLACE TRIGGER "trg_keep_principal_tracks_during_import" BEFORE DELETE ON "public"."playlist_tracks" FOR EACH ROW EXECUTE FUNCTION "public"."keep_principal_tracks_during_import"();



CREATE OR REPLACE TRIGGER "trg_preserve_playlist_request_on_approval" AFTER UPDATE OF "status" ON "public"."playlist_requests" FOR EACH ROW WHEN ((("new"."status" = 'approved'::"text") AND ("old"."status" IS DISTINCT FROM "new"."status"))) EXECUTE FUNCTION "public"."preserve_playlist_request_on_approval"();



CREATE OR REPLACE TRIGGER "trg_require_available_track_link" BEFORE INSERT OR UPDATE OF "track_id" ON "public"."playlist_tracks" FOR EACH ROW EXECUTE FUNCTION "private"."require_available_track_link"();



CREATE OR REPLACE TRIGGER "trg_sync_playlist_import_from_job" AFTER INSERT OR UPDATE OF "status", "total", "completed", "failed", "error", "error_code", "error_message", "error_details", "last_error_at", "started_at", "finished_at" ON "public"."download_jobs" FOR EACH ROW EXECUTE FUNCTION "public"."sync_playlist_import_from_job"();



CREATE OR REPLACE TRIGGER "trg_sync_playlist_review_import_defaults" BEFORE UPDATE OF "approval_status" ON "public"."playlists" FOR EACH ROW EXECUTE FUNCTION "public"."sync_playlist_review_import_defaults"();



ALTER TABLE ONLY "public"."admin_audit_logs"
    ADD CONSTRAINT "admin_audit_logs_admin_user_id_fkey" FOREIGN KEY ("admin_user_id") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."app_notice_acknowledgements"
    ADD CONSTRAINT "app_notice_acknowledgements_notice_id_fkey" FOREIGN KEY ("notice_id") REFERENCES "public"."app_notices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_notice_acknowledgements"
    ADD CONSTRAINT "app_notice_acknowledgements_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_notices"
    ADD CONSTRAINT "app_notices_condominium_id_fkey" FOREIGN KEY ("condominium_id") REFERENCES "public"."units"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_notices"
    ADD CONSTRAINT "app_notices_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_notices"
    ADD CONSTRAINT "app_notices_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_notices"
    ADD CONSTRAINT "app_notices_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_release_audit"
    ADD CONSTRAINT "app_release_audit_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."app_release_audit"
    ADD CONSTRAINT "app_release_audit_release_id_fkey" FOREIGN KEY ("release_id") REFERENCES "public"."app_releases"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_release_note_acknowledgements"
    ADD CONSTRAINT "app_release_note_acknowledgements_note_id_fkey" FOREIGN KEY ("note_id") REFERENCES "public"."app_release_notes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_release_note_acknowledgements"
    ADD CONSTRAINT "app_release_note_acknowledgements_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_release_notes"
    ADD CONSTRAINT "app_release_notes_app_release_id_fkey" FOREIGN KEY ("app_release_id") REFERENCES "public"."app_releases"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_release_notes"
    ADD CONSTRAINT "app_release_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_release_notes"
    ADD CONSTRAINT "app_release_notes_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_releases_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_releases_blocked_by_fkey" FOREIGN KEY ("blocked_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_releases_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."app_releases"
    ADD CONSTRAINT "app_releases_released_by_fkey" FOREIGN KEY ("released_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."call_sessions"
    ADD CONSTRAINT "call_sessions_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id");



ALTER TABLE ONLY "public"."call_sessions"
    ADD CONSTRAINT "call_sessions_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."call_sessions"
    ADD CONSTRAINT "call_sessions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."challenge_logs"
    ADD CONSTRAINT "challenge_logs_challenge_id_fkey" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id");



ALTER TABLE ONLY "public"."challenge_logs"
    ADD CONSTRAINT "challenge_logs_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."challenge_logs"
    ADD CONSTRAINT "challenge_logs_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."challenges"
    ADD CONSTRAINT "challenges_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."download_jobs"
    ADD CONSTRAINT "download_jobs_playlist_id_fkey" FOREIGN KEY ("playlist_id") REFERENCES "public"."playlists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."download_jobs"
    ADD CONSTRAINT "download_jobs_playlist_request_id_fkey" FOREIGN KEY ("playlist_request_id") REFERENCES "public"."playlist_requests"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."operator_blocks"
    ADD CONSTRAINT "operator_blocks_challenge_log_id_fkey" FOREIGN KEY ("challenge_log_id") REFERENCES "public"."challenge_logs"("id");



ALTER TABLE ONLY "public"."operator_blocks"
    ADD CONSTRAINT "operator_blocks_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operator_blocks"
    ADD CONSTRAINT "operator_blocks_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."operator_display_name_moderation_terms"
    ADD CONSTRAINT "operator_display_name_moderation_terms_created_by_admin_id_fkey" FOREIGN KEY ("created_by_admin_id") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."operator_display_name_moderation_terms"
    ADD CONSTRAINT "operator_display_name_moderation_terms_updated_by_admin_id_fkey" FOREIGN KEY ("updated_by_admin_id") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_actor_admin_user_id_fkey" FOREIGN KEY ("actor_admin_user_id") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_moderation_term_id_fkey" FOREIGN KEY ("moderation_term_id") REFERENCES "public"."operator_display_name_moderation_terms"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_reviewed_by_admin_id_fkey" FOREIGN KEY ("reviewed_by_admin_id") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."operator_display_name_requests"
    ADD CONSTRAINT "operator_display_name_requests_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operator_group_members"
    ADD CONSTRAINT "operator_group_members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."operator_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."operator_group_members"
    ADD CONSTRAINT "operator_group_members_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."operator_groups"
    ADD CONSTRAINT "operator_groups_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."operator_preferences"
    ADD CONSTRAINT "operator_preferences_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operator_sessions"
    ADD CONSTRAINT "operator_sessions_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id");



ALTER TABLE ONLY "public"."operator_sessions"
    ADD CONSTRAINT "operator_sessions_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operator_sessions"
    ADD CONSTRAINT "operator_sessions_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id");



ALTER TABLE ONLY "public"."operator_sessions"
    ADD CONSTRAINT "operator_sessions_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."operator_states"
    ADD CONSTRAINT "operator_states_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operator_states"
    ADD CONSTRAINT "operator_states_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."operator_status_history"
    ADD CONSTRAINT "operator_status_history_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."operator_status_history"
    ADD CONSTRAINT "operator_status_history_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."operator_sessions"("id");



ALTER TABLE ONLY "public"."operators"
    ADD CONSTRAINT "operators_default_shift_id_fkey" FOREIGN KEY ("default_shift_id") REFERENCES "public"."shifts"("id");



ALTER TABLE ONLY "public"."operators"
    ADD CONSTRAINT "operators_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."playlist_permissions"
    ADD CONSTRAINT "playlist_permissions_playlist_id_fkey" FOREIGN KEY ("playlist_id") REFERENCES "public"."playlists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."playlist_request_tracks"
    ADD CONSTRAINT "playlist_request_tracks_playlist_request_id_fkey" FOREIGN KEY ("playlist_request_id") REFERENCES "public"."playlist_requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."playlist_request_tracks"
    ADD CONSTRAINT "playlist_request_tracks_track_id_fkey" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_download_job_id_fkey" FOREIGN KEY ("download_job_id") REFERENCES "public"."download_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."operators"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."playlist_requests"
    ADD CONSTRAINT "playlist_requests_playlist_id_fkey" FOREIGN KEY ("playlist_id") REFERENCES "public"."playlists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."playlist_tracks"
    ADD CONSTRAINT "playlist_tracks_playlist_id_fkey" FOREIGN KEY ("playlist_id") REFERENCES "public"."playlists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."playlist_tracks"
    ADD CONSTRAINT "playlist_tracks_track_id_fkey" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id");



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id");



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_created_by_operator_id_fkey" FOREIGN KEY ("created_by_operator_id") REFERENCES "public"."operators"("id");



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_reviewed_by_admin_id_fkey" FOREIGN KEY ("reviewed_by_admin_id") REFERENCES "public"."admin_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."admin_users"("id");



ALTER TABLE ONLY "public"."playlists"
    ADD CONSTRAINT "playlists_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units"("id");



ALTER TABLE ONLY "public"."storage_deletion_jobs"
    ADD CONSTRAINT "storage_deletion_jobs_track_id_fkey" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id");



ALTER TABLE ONLY "public"."tracks"
    ADD CONSTRAINT "tracks_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id");



CREATE POLICY "admin_all" ON "public"."app_release_rules" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."call_sessions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."categories" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."challenge_logs" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."challenges" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."devices" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_blocks" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_group_members" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_groups" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_preferences" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_sessions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."operator_states" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."playlist_permissions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."playlist_tracks" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."playlists" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."shifts" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."system_settings" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."tracks" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_all" ON "public"."units" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."admin_audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_insert" ON "public"."admin_audit_logs" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_insert" ON "public"."operational_events" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_insert" ON "public"."operator_status_history" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_select" ON "public"."admin_audit_logs" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "admin_select" ON "public"."operational_events" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "admin_select" ON "public"."operator_status_history" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."admin_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_users_del" ON "public"."admin_users" FOR DELETE TO "authenticated" USING ("public"."is_superadmin"());



CREATE POLICY "admin_users_ins" ON "public"."admin_users" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_superadmin"());



CREATE POLICY "admin_users_sel" ON "public"."admin_users" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "admin_users_upd" ON "public"."admin_users" FOR UPDATE TO "authenticated" USING ("public"."is_superadmin"()) WITH CHECK ("public"."is_superadmin"());



CREATE POLICY "admins read download_jobs" ON "public"."download_jobs" FOR SELECT USING ("public"."is_admin"());



CREATE POLICY "app_notice_ack_admin_select" ON "public"."app_notice_acknowledgements" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_notice_ack_operator_insert" ON "public"."app_notice_acknowledgements" FOR INSERT TO "authenticated" WITH CHECK (("operator_id" = "public"."current_operator_id"()));



CREATE POLICY "app_notice_ack_operator_select" ON "public"."app_notice_acknowledgements" FOR SELECT TO "authenticated" USING (("operator_id" = "public"."current_operator_id"()));



CREATE POLICY "app_notice_ack_operator_update" ON "public"."app_notice_acknowledgements" FOR UPDATE TO "authenticated" USING (("operator_id" = "public"."current_operator_id"())) WITH CHECK (("operator_id" = "public"."current_operator_id"()));



ALTER TABLE "public"."app_notice_acknowledgements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_notices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_notices_admin_select" ON "public"."app_notices" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_notices_operator_active_select" ON "public"."app_notices" FOR SELECT TO "authenticated" USING ((("status" = 'active'::"text") AND ("is_active" = true) AND (("starts_at" IS NULL) OR ("starts_at" <= "now"())) AND (("ends_at" IS NULL) OR ("ends_at" > "now"())) AND (("audience_type" = 'all'::"text") OR (("audience_type" = 'condominium'::"text") AND ("condominium_id" = ( SELECT "o"."unit_id"
   FROM "public"."operators" "o"
  WHERE (("o"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("o"."active" = true))
 LIMIT 1))) OR (("audience_type" = 'user'::"text") AND ("operator_id" = "public"."current_operator_id"())) OR (("audience_type" = 'shift'::"text") AND ("shift" = ( SELECT
        CASE
            WHEN ("lower"(COALESCE("s"."name", ''::"text")) ~~ '%diurno%'::"text") THEN 'day'::"text"
            WHEN ("lower"(COALESCE("s"."name", ''::"text")) ~~ '%noturno%'::"text") THEN 'night'::"text"
            ELSE 'other'::"text"
        END AS "case"
   FROM ("public"."operators" "o"
     LEFT JOIN "public"."shifts" "s" ON (("s"."id" = "o"."default_shift_id")))
  WHERE (("o"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("o"."active" = true))
 LIMIT 1))))));



CREATE POLICY "app_notices_release_admin_write" ON "public"."app_notices" TO "authenticated" USING ("public"."is_release_admin"()) WITH CHECK ("public"."is_release_admin"());



ALTER TABLE "public"."app_release_audit" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_release_audit_admin_select" ON "public"."app_release_audit" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_release_note_ack_admin_select" ON "public"."app_release_note_acknowledgements" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_release_note_ack_operator_insert" ON "public"."app_release_note_acknowledgements" FOR INSERT TO "authenticated" WITH CHECK (("operator_id" = "public"."current_operator_id"()));



CREATE POLICY "app_release_note_ack_operator_select" ON "public"."app_release_note_acknowledgements" FOR SELECT TO "authenticated" USING (("operator_id" = "public"."current_operator_id"()));



CREATE POLICY "app_release_note_ack_operator_update" ON "public"."app_release_note_acknowledgements" FOR UPDATE TO "authenticated" USING (("operator_id" = "public"."current_operator_id"())) WITH CHECK (("operator_id" = "public"."current_operator_id"()));



ALTER TABLE "public"."app_release_note_acknowledgements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_release_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_release_notes_admin_select" ON "public"."app_release_notes" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_release_notes_operator_published_select" ON "public"."app_release_notes" FOR SELECT TO "authenticated" USING ((("status" = 'published'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."app_releases" "r"
  WHERE (("r"."id" = "app_release_notes"."app_release_id") AND ("r"."status" = 'released'::"text"))))));



CREATE POLICY "app_release_notes_release_admin_write" ON "public"."app_release_notes" TO "authenticated" USING ("public"."is_release_admin"()) WITH CHECK ("public"."is_release_admin"());



ALTER TABLE "public"."app_release_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_releases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_releases_admin_select" ON "public"."app_releases" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "app_releases_release_admin_write" ON "public"."app_releases" TO "authenticated" USING ("public"."is_release_admin"()) WITH CHECK ("public"."is_release_admin"());



ALTER TABLE "public"."app_request_idempotency" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."call_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."challenge_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."challenges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."download_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "feedback_admin_all" ON "public"."feedback" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "feedback_op_sel" ON "public"."feedback" FOR SELECT TO "authenticated" USING (("operator_id" IN ( SELECT "operators"."id"
   FROM "public"."operators"
  WHERE ("operators"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



ALTER TABLE "public"."operational_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_blocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_display_name_moderation_terms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_display_name_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_group_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_groups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_states" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operator_status_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operators" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "operators_del" ON "public"."operators" FOR DELETE TO "authenticated" USING ("public"."is_superadmin"());



CREATE POLICY "operators_ins" ON "public"."operators" FOR INSERT TO "authenticated" WITH CHECK ("public"."admin_can_manage_operator_unit"("unit_id"));



CREATE POLICY "operators_sel" ON "public"."operators" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "operators_upd" ON "public"."operators" FOR UPDATE TO "authenticated" USING ("public"."admin_can_manage_operator_unit"("unit_id")) WITH CHECK ("public"."admin_can_manage_operator_unit"("unit_id"));



ALTER TABLE "public"."playlist_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."playlist_request_tracks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."playlist_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."playlist_tracks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."playlists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shifts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."storage_deletion_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tracks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."units" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON TABLE "public"."app_releases" TO "authenticated";
GRANT ALL ON TABLE "public"."app_releases" TO "service_role";



GRANT ALL ON TABLE "public"."challenge_logs" TO "anon";
GRANT ALL ON TABLE "public"."challenge_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."challenge_logs" TO "service_role";



GRANT ALL ON TABLE "public"."admin_users" TO "anon";
GRANT ALL ON TABLE "public"."admin_users" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_users" TO "service_role";



GRANT ALL ON TABLE "public"."operator_states" TO "anon";
GRANT ALL ON TABLE "public"."operator_states" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_states" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_app_envelope"("p_request_id" "text", "p_success" boolean, "p_data" "jsonb", "p_error" "jsonb", "p_meta" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_app_envelope"("p_request_id" "text", "p_success" boolean, "p_data" "jsonb", "p_error" "jsonb", "p_meta" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_app_envelope"("p_request_id" "text", "p_success" boolean, "p_data" "jsonb", "p_error" "jsonb", "p_meta" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_app_semver_ge"("a" "text", "b" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_app_semver_ge"("a" "text", "b" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_app_semver_ge"("a" "text", "b" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_app_shift_info"("p_shift" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_app_shift_info"("p_shift" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_app_shift_info"("p_shift" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_app_version_check"("p_unit" "uuid", "p_version" "text", "p_platform" "text", "p_channel" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_app_version_check"("p_unit" "uuid", "p_version" "text", "p_platform" "text", "p_channel" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_app_version_check"("p_unit" "uuid", "p_version" "text", "p_platform" "text", "p_channel" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_enforce_secondary_limit"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_enforce_secondary_limit"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_acknowledge_playlist_import_error"("p_playlist_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_acknowledge_playlist_import_error"("p_playlist_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_acknowledge_playlist_import_error"("p_playlist_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_analytics_answered_calls"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_analytics_answered_calls"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_analytics_answered_calls"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_analytics_dashboard"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_analytics_dashboard"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_analytics_dashboard"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_archive_secondary_playlist"("p_playlist" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_archive_secondary_playlist"("p_playlist" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_archive_secondary_playlist"("p_playlist" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_can_manage_operator_unit"("p_unit" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_can_manage_operator_unit"("p_unit" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_can_manage_operator_unit"("p_unit" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_challenge_leaderboard"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_challenge_leaderboard"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_challenge_leaderboard"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_correct_operator_registered_name"("p_operator" "uuid", "p_registered_name" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_correct_operator_registered_name"("p_operator" "uuid", "p_registered_name" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_correct_operator_registered_name"("p_operator" "uuid", "p_registered_name" "text", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_create_operator"("p_auth_user_id" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_operator"("p_auth_user_id" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_operator"("p_auth_user_id" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_create_unit"("p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_unit"("p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_unit"("p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_dismiss_skipped_track"("p_playlist_id" "uuid", "p_youtube_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_dismiss_skipped_track"("p_playlist_id" "uuid", "p_youtube_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_dismiss_skipped_track"("p_playlist_id" "uuid", "p_youtube_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_enqueue_track_replacement"("p_playlist_id" "uuid", "p_source_url" "text", "p_replace_youtube_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_enqueue_track_replacement"("p_playlist_id" "uuid", "p_source_url" "text", "p_replace_youtube_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_enqueue_track_replacement"("p_playlist_id" "uuid", "p_source_url" "text", "p_replace_youtube_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_grant_app_access"("p_admin_user" "uuid", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_grant_app_access"("p_admin_user" "uuid", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_grant_app_access"("p_admin_user" "uuid", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_grant_panel_access"("p_operator" "uuid", "p_mfa_required" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_grant_panel_access"("p_operator" "uuid", "p_mfa_required" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_grant_panel_access"("p_operator" "uuid", "p_mfa_required" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_integration_status"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_integration_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_integration_status"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_operator_display_name_requests"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_operator_display_name_requests"("p_request" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_list_operator_display_name_requests"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_operator_display_name_terms"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_operator_display_name_terms"("p_request" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_list_operator_display_name_terms"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_orphaned_music_tracks"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_orphaned_music_tracks"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_orphaned_music_tracks"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_pending_import_errors"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_pending_import_errors"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_pending_import_errors"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_music_library"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_music_library"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_music_library"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_music_library_page"("p_limit" integer, "p_offset" integer, "p_search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_music_library_page"("p_limit" integer, "p_offset" integer, "p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_music_library_page"("p_limit" integer, "p_offset" integer, "p_search" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_music_library_page_impl"("p_limit" integer, "p_offset" integer, "p_search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_music_library_page_impl"("p_limit" integer, "p_offset" integer, "p_search" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_music_storage_overview"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_music_storage_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_music_storage_overview"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_operator_attention_leaderboard"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_operator_attention_leaderboard"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_operator_attention_leaderboard"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_operator_email"("p_operator" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_operator_email"("p_operator" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_operator_email"("p_operator" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_queue_orphaned_music_deletions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_queue_orphaned_music_deletions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_queue_orphaned_music_deletions"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reimport_playlist_request"("p_request" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reimport_playlist_request"("p_request" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_reimport_playlist_request"("p_request" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_remove_playlist_track"("p_playlist_track" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_remove_playlist_track"("p_playlist_track" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_remove_playlist_track"("p_playlist_track" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_rename_music_playlist"("p_playlist" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_rename_music_playlist"("p_playlist" "uuid", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_rename_music_playlist"("p_playlist" "uuid", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reset_statistics"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reset_statistics"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_reset_statistics"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_retry_playlist_import"("p_playlist" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_retry_playlist_import"("p_playlist" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_retry_playlist_import"("p_playlist" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_review_operator_display_name_request"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_review_operator_display_name_request"("p_request" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_review_operator_display_name_request"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_review_playlist"("p_playlist" "uuid", "p_action" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_review_playlist"("p_playlist" "uuid", "p_action" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_review_playlist"("p_playlist" "uuid", "p_action" "text", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_review_playlist_impl"("p_playlist" "uuid", "p_action" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_review_playlist_impl"("p_playlist" "uuid", "p_action" "text", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_save_challenge_rules"("p_unit_id" "uuid", "p_rules" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_save_challenge_rules"("p_unit_id" "uuid", "p_rules" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_save_challenge_rules"("p_unit_id" "uuid", "p_rules" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_set_challenge_status"("p_challenge_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_challenge_status"("p_challenge_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_challenge_status"("p_challenge_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_set_operator_shift"("p_operator" "uuid", "p_kind" "text", "p_start" time without time zone, "p_end" time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_operator_shift"("p_operator" "uuid", "p_kind" "text", "p_start" time without time zone, "p_end" time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_operator_shift"("p_operator" "uuid", "p_kind" "text", "p_start" time without time zone, "p_end" time without time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_statistics_reset_info"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_statistics_reset_info"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_statistics_reset_info"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_admin_user"("p_admin_user" "uuid", "p_display_name" "text", "p_role" "text", "p_active" boolean, "p_mfa_required" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_admin_user"("p_admin_user" "uuid", "p_display_name" "text", "p_role" "text", "p_active" boolean, "p_mfa_required" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_admin_user"("p_admin_user" "uuid", "p_display_name" "text", "p_role" "text", "p_active" boolean, "p_mfa_required" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_feedback_status"("p_feedback" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_feedback_status"("p_feedback" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_feedback_status"("p_feedback" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_operator"("p_operator" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_operator"("p_operator" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_operator"("p_operator" "uuid", "p_display_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_operator_display_name"("p_operator" "uuid", "p_display_name" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_operator_display_name"("p_operator" "uuid", "p_display_name" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_update_operator_display_name"("p_operator" "uuid", "p_display_name" "text", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_update_operator_profile_v2"("p_operator" "uuid", "p_registered_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_operator_profile_v2"("p_operator" "uuid", "p_registered_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_update_operator_profile_v2"("p_operator" "uuid", "p_registered_name" "text", "p_username" "text", "p_unit_id" "uuid", "p_role" "text", "p_session_policy" "text", "p_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_update_unit"("p_unit" "uuid", "p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_unit"("p_unit" "uuid", "p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_unit"("p_unit" "uuid", "p_code" "text", "p_name" "text", "p_address" "text", "p_city" "text", "p_state" "text", "p_timezone" "text", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_upsert_challenge"("p_challenge" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_upsert_challenge"("p_challenge" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_challenge"("p_challenge" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_upsert_operator_display_name_term"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_upsert_operator_display_name_term"("p_request" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_upsert_operator_display_name_term"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."approve_app_release"("p_release_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_app_release"("p_release_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_app_release"("p_release_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."audit_admin_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_admin_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_app_release"("p_release_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_app_release"("p_release_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_app_release"("p_release_id" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."capture_playlist_request_track"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."capture_playlist_request_track"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_storage_deletion_job"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_storage_deletion_job"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_storage_deletion_job"("p_job_id" "uuid", "p_success" boolean, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_storage_deletion_job"("p_job_id" "uuid", "p_success" boolean, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_app_release"("p_version" "text", "p_title" "text", "p_release_notes" "text", "p_channel" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_app_release"("p_version" "text", "p_title" "text", "p_release_notes" "text", "p_channel" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_app_release"("p_version" "text", "p_title" "text", "p_release_notes" "text", "p_channel" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."current_admin_user_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_admin_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_admin_user_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."current_operator_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_operator_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_operator_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."end_operator_session"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."end_operator_session"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."end_operator_session"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_current_app_release_note"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_current_app_release_note"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_app_release_note"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_operator_display_name_status"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_operator_display_name_status"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_my_operator_display_name_status"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_playlist_requests"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_playlist_requests"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_playlist_requests"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_playlists"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_playlists"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_playlists"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_playlist_tracks"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_playlist_tracks"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_playlist_tracks"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_release_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_release_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_release_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_superadmin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_superadmin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_superadmin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."keep_principal_tracks_during_import"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."keep_principal_tracks_during_import"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."manage_operator_playlist"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."manage_operator_playlist"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_operator_playlist"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."manage_operator_playlist_impl"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."manage_operator_playlist_impl"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_answer"("p_log_id" "uuid", "p_answer" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_answer"("p_log_id" "uuid", "p_answer" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_answer"("p_log_id" "uuid", "p_answer" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_answer_v2"("p_log_id" "uuid", "p_answer" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_answer_v2"("p_log_id" "uuid", "p_answer" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_answer_v2"("p_log_id" "uuid", "p_answer" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_displayed"("p_log_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_displayed"("p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_displayed"("p_log_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_resume_idle"("p_session_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_resume_idle"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_resume_idle"("p_session_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_session_ended"("p_session_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_session_ended"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_session_ended"("p_session_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_challenge_state"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_challenge_state"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_challenge_state"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."operator_operational_event"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operator_operational_event"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operator_operational_event"("p_request" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."playlist_import_error_message"("p_error_code" "text", "p_raw_message" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."playlist_import_error_message"("p_error_code" "text", "p_raw_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."playlist_import_error_message"("p_error_code" "text", "p_raw_message" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."playlist_source_platform"("p_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."playlist_source_platform"("p_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."playlist_source_platform"("p_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."preserve_playlist_request_on_approval"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preserve_playlist_request_on_approval"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_released_app_release_file_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_released_app_release_file_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_released_app_release_file_changes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reconcile_operator_state"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reconcile_operator_state"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reconcile_operator_state"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_app_notice_acknowledgement"("p_notice_id" "uuid", "p_acknowledge" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_app_notice_acknowledgement"("p_notice_id" "uuid", "p_acknowledge" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_app_notice_acknowledgement"("p_notice_id" "uuid", "p_acknowledge" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_app_release_note_acknowledgement"("p_note_id" "uuid", "p_acknowledge" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_app_release_note_acknowledgement"("p_note_id" "uuid", "p_acknowledge" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_app_release_note_acknowledgement"("p_note_id" "uuid", "p_acknowledge" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_device"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_device"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_device"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_app_release"("p_release_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_app_release"("p_release_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_app_release"("p_release_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rename_principal_playlist"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rename_principal_playlist"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rename_principal_playlist"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rollback_app_release"("p_target_release_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rollback_app_release"("p_target_release_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rollback_app_release"("p_target_release_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."start_operator_session"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."start_operator_session"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."start_operator_session"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_feedback"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_feedback"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_feedback"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_playlist"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_playlist"("p_request" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_playlist"("p_request" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_app_notice_metadata"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_app_notice_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_app_notice_metadata"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_app_release_note_metadata"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_app_release_note_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_app_release_note_metadata"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_playlist_import_from_job"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_playlist_import_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_playlist_import_from_job"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_playlist_review_import_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_playlist_review_import_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_playlist_review_import_defaults"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_app_release_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_app_release_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_app_release_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_release_note_on_release"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_release_note_on_release"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_release_note_on_release"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."touch_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_app_notice_status"("p_notice_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_app_notice_status"("p_notice_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_app_notice_status"("p_notice_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_app_release"("p_release_id" "uuid", "p_title" "text", "p_release_notes" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_app_release"("p_release_id" "uuid", "p_title" "text", "p_release_notes" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_app_release"("p_release_id" "uuid", "p_title" "text", "p_release_notes" "text", "p_mandatory" boolean, "p_minimum_version" "text", "p_manifest_key" "text", "p_installer_key" "text", "p_blockmap_key" "text", "p_sha512" "text", "p_size_bytes" bigint, "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_my_operator_display_name"("p_display_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_my_operator_display_name"("p_display_name" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."update_my_operator_display_name"("p_display_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."upsert_app_notice"("p_notice_id" "uuid", "p_title" "text", "p_message" "text", "p_severity" "text", "p_status" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_audience_type" "text", "p_condominium_id" "uuid", "p_operator_id" "uuid", "p_shift" "text", "p_requires_ack" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_app_notice"("p_notice_id" "uuid", "p_title" "text", "p_message" "text", "p_severity" "text", "p_status" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_audience_type" "text", "p_condominium_id" "uuid", "p_operator_id" "uuid", "p_shift" "text", "p_requires_ack" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_app_notice"("p_notice_id" "uuid", "p_title" "text", "p_message" "text", "p_severity" "text", "p_status" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_audience_type" "text", "p_condominium_id" "uuid", "p_operator_id" "uuid", "p_shift" "text", "p_requires_ack" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."upsert_app_release_note"("p_app_release_id" "uuid", "p_title" "text", "p_summary" "text", "p_content" "text", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_app_release_note"("p_app_release_id" "uuid", "p_title" "text", "p_summary" "text", "p_content" "text", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_app_release_note"("p_app_release_id" "uuid", "p_title" "text", "p_summary" "text", "p_content" "text", "p_status" "text") TO "service_role";



GRANT ALL ON TABLE "public"."admin_audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."admin_audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."app_notice_acknowledgements" TO "authenticated";
GRANT ALL ON TABLE "public"."app_notice_acknowledgements" TO "service_role";



GRANT ALL ON TABLE "public"."app_notices" TO "authenticated";
GRANT ALL ON TABLE "public"."app_notices" TO "service_role";



GRANT ALL ON TABLE "public"."app_release_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."app_release_audit" TO "service_role";



GRANT ALL ON TABLE "public"."app_release_note_acknowledgements" TO "authenticated";
GRANT ALL ON TABLE "public"."app_release_note_acknowledgements" TO "service_role";



GRANT ALL ON TABLE "public"."app_release_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."app_release_notes" TO "service_role";



GRANT ALL ON TABLE "public"."app_release_rules" TO "anon";
GRANT ALL ON TABLE "public"."app_release_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."app_release_rules" TO "service_role";



GRANT ALL ON TABLE "public"."app_request_idempotency" TO "anon";
GRANT ALL ON TABLE "public"."app_request_idempotency" TO "authenticated";
GRANT ALL ON TABLE "public"."app_request_idempotency" TO "service_role";



GRANT ALL ON TABLE "public"."app_versions" TO "anon";
GRANT ALL ON TABLE "public"."app_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."app_versions" TO "service_role";



GRANT ALL ON TABLE "public"."call_sessions" TO "anon";
GRANT ALL ON TABLE "public"."call_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."call_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON TABLE "public"."challenges" TO "anon";
GRANT ALL ON TABLE "public"."challenges" TO "authenticated";
GRANT ALL ON TABLE "public"."challenges" TO "service_role";



GRANT ALL ON TABLE "public"."devices" TO "anon";
GRANT ALL ON TABLE "public"."devices" TO "authenticated";
GRANT ALL ON TABLE "public"."devices" TO "service_role";



GRANT ALL ON TABLE "public"."download_jobs" TO "anon";
GRANT ALL ON TABLE "public"."download_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."download_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."operational_events" TO "anon";
GRANT ALL ON TABLE "public"."operational_events" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_events" TO "service_role";



GRANT ALL ON TABLE "public"."operator_blocks" TO "anon";
GRANT ALL ON TABLE "public"."operator_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_blocks" TO "service_role";



GRANT ALL ON TABLE "public"."operator_display_name_moderation_terms" TO "service_role";



GRANT ALL ON TABLE "public"."operator_display_name_requests" TO "service_role";



GRANT ALL ON TABLE "public"."operator_group_members" TO "anon";
GRANT ALL ON TABLE "public"."operator_group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_group_members" TO "service_role";



GRANT ALL ON TABLE "public"."operator_groups" TO "anon";
GRANT ALL ON TABLE "public"."operator_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_groups" TO "service_role";



GRANT ALL ON TABLE "public"."operator_preferences" TO "anon";
GRANT ALL ON TABLE "public"."operator_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."operator_sessions" TO "anon";
GRANT ALL ON TABLE "public"."operator_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."operator_status_history" TO "anon";
GRANT ALL ON TABLE "public"."operator_status_history" TO "authenticated";
GRANT ALL ON TABLE "public"."operator_status_history" TO "service_role";



GRANT ALL ON TABLE "public"."operators" TO "anon";
GRANT ALL ON TABLE "public"."operators" TO "authenticated";
GRANT ALL ON TABLE "public"."operators" TO "service_role";



GRANT ALL ON TABLE "public"."playlist_permissions" TO "anon";
GRANT ALL ON TABLE "public"."playlist_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."playlist_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."playlist_request_tracks" TO "service_role";



GRANT ALL ON TABLE "public"."playlist_requests" TO "service_role";



GRANT ALL ON TABLE "public"."playlist_tracks" TO "service_role";



GRANT ALL ON TABLE "public"."playlists" TO "authenticated";
GRANT ALL ON TABLE "public"."playlists" TO "service_role";



GRANT ALL ON TABLE "public"."shifts" TO "anon";
GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";



GRANT ALL ON TABLE "public"."storage_deletion_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."system_settings" TO "anon";
GRANT ALL ON TABLE "public"."system_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."system_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tracks" TO "service_role";



GRANT ALL ON TABLE "public"."units" TO "anon";
GRANT ALL ON TABLE "public"."units" TO "authenticated";
GRANT ALL ON TABLE "public"."units" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
