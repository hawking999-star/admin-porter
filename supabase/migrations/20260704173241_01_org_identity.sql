-- Baseline local minimo para tornar o repo reproduzivel em um banco limpo.
-- A producao ja tem esta versao marcada como aplicada; por isso este arquivo
-- e aditivo/idempotente e serve principalmente para supabase db reset local.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.units (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  address text,
  city text,
  state text,
  timezone text not null default 'America/Sao_Paulo',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint units_code_key unique (code),
  constraint units_code_not_blank check (btrim(code) <> ''),
  constraint units_name_not_blank check (btrim(name) <> '')
);

create table if not exists public.admin_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  role text not null,
  active boolean not null default true,
  mfa_required boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_users_display_name_not_blank check (btrim(display_name) <> ''),
  constraint admin_users_role_check check (
    role = any (array[
      'superadmin',
      'unit_manager',
      'operations_manager',
      'content_manager',
      'challenge_manager',
      'release_manager',
      'auditor',
      'support_readonly'
    ])
  )
);

create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid references public.units(id) on delete cascade,
  name text not null,
  starts_at time,
  ends_at time,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.operators (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  username text unique,
  employee_code text,
  unit_id uuid not null references public.units(id) on delete restrict,
  role text not null default 'operador',
  session_policy text not null default 'single',
  default_shift_id uuid references public.shifts(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operators_display_name_not_blank check (btrim(display_name) <> ''),
  constraint operators_username_format check (username is null or username ~ '^[a-z0-9._-]{3,60}$'),
  constraint operators_role_check check (role in ('operador', 'supervisor')),
  constraint operators_session_policy_check check (session_policy in ('single', 'multi'))
);

create table if not exists public.operator_sessions (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  shift_id uuid references public.shifts(id) on delete set null,
  status text not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  expires_at timestamptz not null default (now() + interval '12 hours'),
  last_heartbeat_at timestamptz,
  end_reason text,
  app_version text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_sessions_status_check check (status in ('active', 'ended', 'expired', 'revoked'))
);

create table if not exists public.operator_states (
  operator_id uuid primary key references public.operators(id) on delete cascade,
  session_id uuid references public.operator_sessions(id) on delete set null,
  status text not null default 'offline',
  activity text,
  reason_code text,
  effective_at timestamptz,
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint operator_states_status_check check (status in ('active', 'in_call', 'idle', 'blocked', 'outside_shift', 'offline'))
);

create table if not exists public.operator_status_history (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid references public.operators(id) on delete cascade,
  session_id uuid references public.operator_sessions(id) on delete set null,
  from_status text,
  to_status text,
  reason_code text,
  source text,
  occurred_at timestamptz not null default now(),
  state_revision bigint,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.operator_blocks (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id) on delete cascade,
  status text not null default 'active',
  reason_code text,
  blocked_until timestamptz,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  constraint operator_blocks_status_check check (status in ('active', 'ended'))
);

create table if not exists public.operational_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  operator_id uuid references public.operators(id) on delete set null,
  session_id uuid references public.operator_sessions(id) on delete set null,
  device_id uuid,
  unit_id uuid references public.units(id) on delete set null,
  idempotency_key uuid unique,
  client_sent_at timestamptz,
  occurred_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb
);

create table if not exists public.app_request_idempotency (
  idempotency_key uuid primary key,
  rpc_name text not null,
  operator_id uuid references public.operators(id) on delete cascade,
  request_hash text,
  response jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.system_settings (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null default 'global',
  scope_id uuid,
  key text not null default 'config',
  value jsonb not null default '{}'::jsonb,
  revision bigint not null default 1,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.challenges (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  prompt text not null,
  kind text not null default 'text',
  answer_definition jsonb not null default '{}'::jsonb,
  duration_seconds integer not null default 60,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.challenge_logs (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid references public.challenges(id) on delete set null,
  operator_id uuid references public.operators(id) on delete cascade,
  session_id uuid references public.operator_sessions(id) on delete set null,
  status text not null default 'pending',
  expires_at timestamptz,
  paused_at timestamptz,
  resumed_at timestamptz,
  pause_reason text,
  answered_at timestamptz,
  created_at timestamptz not null default now(),
  revision bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  constraint challenge_logs_status_check check (status in ('pending', 'displayed', 'paused', 'answered', 'expired', 'failed'))
);

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  created_by_operator_id uuid references public.operators(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  name text not null,
  type text not null default 'principal',
  status text not null default 'active',
  approval_status text not null default 'draft',
  source_url text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  rejection_reason text,
  revision bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint playlists_name_not_blank check (btrim(name) <> ''),
  constraint playlists_type_check check (type in ('principal', 'secondary')),
  constraint playlists_status_check check (status in ('active', 'archived')),
  constraint playlists_approval_status_check check (approval_status in ('draft', 'pending', 'approved', 'rejected'))
);

create table if not exists public.tracks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  artist text,
  duration_ms integer,
  status text not null default 'available',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tracks_title_not_blank check (btrim(title) <> ''),
  constraint tracks_status_check check (status in ('available', 'processing', 'failed', 'archived'))
);

create table if not exists public.playlist_tracks (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  position integer not null default 0,
  added_by_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint playlist_tracks_playlist_track_key unique (playlist_id, track_id)
);

create table if not exists public.download_jobs (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  source_url text,
  status text not null default 'queued',
  total integer not null default 0,
  completed integer not null default 0,
  failed integer not null default 0,
  error text,
  attempts integer not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint download_jobs_status_check check (status in ('queued', 'running', 'done', 'partial', 'error'))
);

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid references public.operators(id) on delete set null,
  unit_id uuid references public.units(id) on delete set null,
  type text not null,
  message text not null,
  status text not null default 'new',
  app_version text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint feedback_type_check check (type in ('suggestion', 'problem', 'praise')),
  constraint feedback_status_check check (status in ('new', 'read', 'resolved')),
  constraint feedback_message_not_blank check (btrim(message) <> '')
);

create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid references public.admin_users(id) on delete set null,
  action text not null,
  entity_type text,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists admin_users_auth_active_idx on public.admin_users (auth_user_id, active);
create index if not exists admin_users_role_active_idx on public.admin_users (role, active);
create index if not exists operators_auth_active_idx on public.operators (auth_user_id, active);
create index if not exists operators_unit_active_idx on public.operators (unit_id, active);
create index if not exists operators_username_idx on public.operators (username);
create index if not exists shifts_unit_active_idx on public.shifts (unit_id, active);
create index if not exists operator_sessions_operator_status_idx on public.operator_sessions (operator_id, status, started_at desc);
create index if not exists operator_sessions_status_started_idx on public.operator_sessions (status, started_at desc);
create index if not exists operator_states_status_idx on public.operator_states (status, updated_at desc);
create index if not exists operator_status_history_operator_time_idx on public.operator_status_history (operator_id, occurred_at desc);
create index if not exists operator_status_history_time_idx on public.operator_status_history (occurred_at desc);
create index if not exists operational_events_operator_time_idx on public.operational_events (operator_id, occurred_at desc);
create index if not exists operational_events_type_time_idx on public.operational_events (event_type, occurred_at desc);
create index if not exists operator_blocks_operator_active_idx on public.operator_blocks (operator_id, status, blocked_until);
create index if not exists challenge_logs_operator_status_idx on public.challenge_logs (operator_id, status, created_at desc);
create index if not exists playlists_operator_status_idx on public.playlists (created_by_operator_id, status, created_at desc);
create index if not exists playlists_unit_approval_idx on public.playlists (unit_id, approval_status, submitted_at desc);
create index if not exists playlists_reviewed_at_idx on public.playlists (reviewed_at desc);
create index if not exists playlist_tracks_playlist_position_idx on public.playlist_tracks (playlist_id, position);
create index if not exists download_jobs_playlist_created_idx on public.download_jobs (playlist_id, created_at desc);
create index if not exists download_jobs_status_created_idx on public.download_jobs (status, created_at desc);
create index if not exists feedback_status_created_idx on public.feedback (status, created_at desc);
create index if not exists feedback_operator_created_idx on public.feedback (operator_id, created_at desc);
create index if not exists admin_audit_logs_admin_time_idx on public.admin_audit_logs (admin_user_id, occurred_at desc);
create index if not exists admin_audit_logs_entity_time_idx on public.admin_audit_logs (entity_type, entity_id, occurred_at desc);

create or replace function private.require_admin(
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
     and v_admin.role <> 'superadmin'
     and v_admin.role <> 'operations_manager' then
    raise exception 'fora_do_escopo_da_unidade';
  end if;

  return v_admin;
end;
$$;

create or replace function public.current_admin_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select a.id
  from public.admin_users a
  where a.auth_user_id = auth.uid()
    and a.active = true
  limit 1
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.auth_user_id = auth.uid()
      and a.active = true
      and a.role in (
        'superadmin',
        'unit_manager',
        'operations_manager',
        'content_manager',
        'challenge_manager',
        'release_manager',
        'auditor',
        'support_readonly'
      )
  )
$$;

create or replace function public.is_superadmin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.auth_user_id = auth.uid()
      and a.active = true
      and a.role = 'superadmin'
  )
$$;

create or replace function public.admin_can_manage_operator_unit(p_unit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.auth_user_id = auth.uid()
      and a.active = true
      and (
        a.role in ('superadmin', 'operations_manager')
      )
  )
$$;

create or replace function public._app_envelope(
  p_request_id text,
  p_ok boolean,
  p_data jsonb,
  p_error jsonb,
  p_meta jsonb
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'request_id', p_request_id,
    'ok', p_ok,
    'data', p_data,
    'error', p_error,
    'meta', coalesce(p_meta, '{}'::jsonb)
  )
$$;

create or replace function public._app_shift_info(p_shift_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_shift public.shifts%rowtype;
begin
  if p_shift_id is null then
    return jsonb_build_object('id', null, 'name', null, 'in_shift', true);
  end if;

  select * into v_shift from public.shifts where id = p_shift_id;

  return jsonb_build_object(
    'id', v_shift.id,
    'name', v_shift.name,
    'starts_at', v_shift.starts_at,
    'ends_at', v_shift.ends_at,
    'in_shift', coalesce(v_shift.active, true)
  );
end;
$$;

create or replace function public._app_version_check(
  p_unit_id uuid,
  p_app_version text,
  p_platform text,
  p_channel text
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'allowed', true,
    'update_policy', 'none',
    'unit_id', p_unit_id,
    'app_version', p_app_version,
    'platform', p_platform,
    'channel', p_channel
  )
$$;

create or replace function public.admin_operator_email(p_operator uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator public.operators%rowtype;
  v_email text;
begin
  select * into v_operator
  from public.operators
  where id = p_operator;

  if v_operator.id is null then
    raise exception 'operator_not_found';
  end if;

  perform private.require_admin(array['superadmin','unit_manager','operations_manager'], v_operator.unit_id);

  select email into v_email
  from auth.users
  where id = v_operator.auth_user_id;

  return v_email;
end;
$$;

create or replace function public.admin_set_operator_shift(
  p_operator uuid,
  p_kind text,
  p_start text default null,
  p_end text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_shift_id uuid;
  v_name text;
  v_start time;
  v_end time;
begin
  select * into v_operator
  from public.operators
  where id = p_operator
  for update;

  if v_operator.id is null then
    raise exception 'operator_not_found';
  end if;

  v_admin := private.require_admin(array['superadmin','unit_manager','operations_manager'], v_operator.unit_id);

  if p_kind = 'none' then
    update public.operators
    set default_shift_id = null,
        updated_at = now()
    where id = p_operator;

    return null;
  elsif p_kind = '12x36_dia' then
    v_name := '12x36 Diurno';
    v_start := '06:00'::time;
    v_end := '18:00'::time;
  elsif p_kind = '12x36_noite' then
    v_name := '12x36 Noturno';
    v_start := '18:00'::time;
    v_end := '06:00'::time;
  elsif p_kind = '6x1' then
    v_name := '6x1';
    v_start := nullif(p_start, '')::time;
    v_end := nullif(p_end, '')::time;
  else
    raise exception 'shift_kind_invalid';
  end if;

  insert into public.shifts (unit_id, name, starts_at, ends_at, active, created_at, updated_at)
  values (v_operator.unit_id, v_name, v_start, v_end, true, now(), now())
  returning id into v_shift_id;

  update public.operators
  set default_shift_id = v_shift_id,
      updated_at = now()
  where id = p_operator;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'operator_shift_updated',
    'operator',
    p_operator,
    jsonb_build_object('shift_id', v_shift_id, 'kind', p_kind, 'starts_at', v_start, 'ends_at', v_end),
    now()
  );

  return v_shift_id;
end;
$$;

create or replace function public.admin_review_playlist(
  p_playlist uuid,
  p_action text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.playlists%rowtype;
  v_after public.playlists%rowtype;
  v_status text;
begin
  if p_action not in ('approve', 'reject') then
    raise exception 'playlist_action_invalid';
  end if;

  select * into v_before
  from public.playlists
  where id = p_playlist
  for update;

  if v_before.id is null then
    raise exception 'playlist_not_found';
  end if;

  v_admin := private.require_admin(
    array['superadmin','unit_manager','operations_manager','content_manager'],
    v_before.unit_id
  );

  v_status := case when p_action = 'approve' then 'approved' else 'rejected' end;

  update public.playlists
  set approval_status = v_status,
      rejection_reason = case when p_action = 'reject' then nullif(btrim(coalesce(p_reason, '')), '') else null end,
      reviewed_at = now(),
      reviewed_by_admin_id = v_admin.id,
      updated_at = now(),
      revision = revision + 1
  where id = p_playlist
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case when p_action = 'approve' then 'playlist_approved' else 'playlist_rejected' end,
    'playlist',
    p_playlist,
    jsonb_build_object('approval_status', v_before.approval_status, 'rejection_reason', v_before.rejection_reason),
    jsonb_build_object('approval_status', v_after.approval_status, 'rejection_reason', v_after.rejection_reason),
    now()
  );
end;
$$;

do $$
declare
  v_table text;
  v_tables text[] := array[
    'units',
    'admin_users',
    'shifts',
    'operators',
    'operator_sessions',
    'operator_states',
    'operator_status_history',
    'operator_blocks',
    'operational_events',
    'app_request_idempotency',
    'system_settings',
    'challenges',
    'challenge_logs',
    'playlists',
    'tracks',
    'playlist_tracks',
    'download_jobs',
    'feedback',
    'admin_audit_logs'
  ];
begin
  foreach v_table in array v_tables loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('drop policy if exists ptm_admin_select on public.%I', v_table);
    execute format(
      'create policy ptm_admin_select on public.%I for select to authenticated using (public.is_admin())',
      v_table
    );
    execute format('revoke all on table public.%I from anon', v_table);
    execute format('grant select on table public.%I to authenticated', v_table);
  end loop;
end $$;

revoke all on schema private from public, anon, authenticated;
revoke all on function private.require_admin(text[], uuid) from public, anon, authenticated;

revoke all on function public.current_admin_user_id() from public, anon;
revoke all on function public.is_admin() from public, anon;
revoke all on function public.is_superadmin() from public, anon;
revoke all on function public.admin_can_manage_operator_unit(uuid) from public, anon;
grant execute on function public.current_admin_user_id() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_superadmin() to authenticated;
grant execute on function public.admin_can_manage_operator_unit(uuid) to authenticated;

revoke all on function public._app_envelope(text, boolean, jsonb, jsonb, jsonb) from public, anon;
revoke all on function public._app_shift_info(uuid) from public, anon;
revoke all on function public._app_version_check(uuid, text, text, text) from public, anon;
grant execute on function public._app_envelope(text, boolean, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public._app_shift_info(uuid) to authenticated;
grant execute on function public._app_version_check(uuid, text, text, text) to authenticated;

revoke all on function public.admin_operator_email(uuid) from public, anon;
revoke all on function public.admin_set_operator_shift(uuid, text, text, text) from public, anon;
revoke all on function public.admin_review_playlist(uuid, text, text) from public, anon;
grant execute on function public.admin_operator_email(uuid) to authenticated;
grant execute on function public.admin_set_operator_shift(uuid, text, text, text) to authenticated;
grant execute on function public.admin_review_playlist(uuid, text, text) to authenticated;
-- Mantido localmente para sincronizar o histórico do Supabase CLI.
