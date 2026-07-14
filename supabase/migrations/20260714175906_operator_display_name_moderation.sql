begin;

create extension if not exists unaccent with schema extensions;

alter table public.operators
  add column if not exists registered_name text;

update public.operators
set registered_name = display_name
where registered_name is null or btrim(registered_name) = '';

alter table public.operators
  alter column registered_name set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.operators'::regclass
      and conname = 'operators_registered_name_not_blank'
  ) then
    alter table public.operators
      add constraint operators_registered_name_not_blank
      check (btrim(registered_name) <> '');
  end if;
end;
$$;

alter table public.admin_audit_logs
  add column if not exists reason text;

create table if not exists public.operator_display_name_moderation_terms (
  id uuid primary key default gen_random_uuid(),
  term text not null,
  normalized_term text not null,
  compact_term text not null,
  match_type text not null,
  active boolean not null default true,
  reason text not null,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  updated_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_display_name_terms_match_type_check
    check (match_type in ('exact_name', 'whole_word', 'obfuscated')),
  constraint operator_display_name_terms_term_not_blank
    check (btrim(term) <> ''),
  constraint operator_display_name_terms_reason_not_blank
    check (btrim(reason) <> ''),
  constraint operator_display_name_terms_unique
    unique (normalized_term, match_type)
);

create table if not exists public.operator_display_name_requests (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  actor_auth_user_id uuid,
  actor_type text not null,
  actor_admin_user_id uuid references public.admin_users(id) on delete set null,
  previous_name text not null,
  requested_name text not null,
  normalized_name text not null,
  compact_name text not null,
  applied_name text,
  moderation_result text not null,
  moderation_term_id uuid references public.operator_display_name_moderation_terms(id) on delete set null,
  moderation_reason text,
  review_status text not null default 'not_required',
  reviewed_by_admin_id uuid references public.admin_users(id) on delete set null,
  reviewed_at timestamptz,
  review_reason text,
  source text not null,
  occurred_at timestamptz not null default now(),
  applied_at timestamptz,
  constraint operator_display_name_requests_actor_type_check
    check (actor_type in ('operator', 'admin', 'system')),
  constraint operator_display_name_requests_result_check
    check (moderation_result in ('allowed', 'blocked', 'rate_limited')),
  constraint operator_display_name_requests_review_check
    check (review_status in ('not_required', 'pending', 'approved', 'rejected')),
  constraint operator_display_name_requests_source_check
    check (source in ('operator_app', 'admin_panel', 'admin_approval', 'system'))
);

create index if not exists operator_display_name_requests_operator_time_idx
  on public.operator_display_name_requests (operator_id, occurred_at desc);
create index if not exists operator_display_name_requests_unit_time_idx
  on public.operator_display_name_requests (unit_id, occurred_at desc);
create index if not exists operator_display_name_requests_review_time_idx
  on public.operator_display_name_requests (review_status, occurred_at desc);
create index if not exists operator_display_name_requests_result_time_idx
  on public.operator_display_name_requests (moderation_result, occurred_at desc);
create index if not exists operator_display_name_terms_active_idx
  on public.operator_display_name_moderation_terms (active, updated_at desc);

alter table public.operator_display_name_moderation_terms enable row level security;
alter table public.operator_display_name_requests enable row level security;

revoke all on table public.operator_display_name_moderation_terms from public, anon, authenticated;
revoke all on table public.operator_display_name_requests from public, anon, authenticated;

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

revoke all on function private.normalize_operator_display_name(text, boolean)
  from public, anon, authenticated;

create or replace function public.audit_admin_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function public.audit_admin_change() from public, anon, authenticated;

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

drop trigger if exists capture_admin_display_name_change on public.operators;
create trigger capture_admin_display_name_change
after update of display_name on public.operators
for each row execute function private.capture_admin_display_name_change();

revoke all on function private.capture_admin_display_name_change()
  from public, anon, authenticated;

create or replace function public.admin_create_operator(
  p_auth_user_id uuid,
  p_display_name text,
  p_username text,
  p_unit_id uuid,
  p_role text,
  p_session_policy text,
  p_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.admin_update_operator_profile_v2(
  p_operator uuid,
  p_registered_name text,
  p_username text,
  p_unit_id uuid,
  p_role text,
  p_session_policy text,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_registered_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select * into v_before
  from public.operators
  where id = p_operator
  for update;

  if v_before.id is null then raise exception 'operator_not_found'; end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_before.unit_id
  );
  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if v_registered_name is null then raise exception 'registered_name_required'; end if;
  if v_registered_name is distinct from v_before.registered_name and v_admin.role <> 'superadmin' then
    raise exception 'registered_name_requires_superadmin';
  end if;
  if v_username is not null and v_username !~ '^[a-z0-9._-]{3,60}$' then raise exception 'username_invalid'; end if;
  if p_role not in ('operador', 'supervisor') then raise exception 'operator_role_invalid'; end if;
  if p_session_policy not in ('single', 'multi') then raise exception 'session_policy_invalid'; end if;
  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  perform set_config('app.audit_source', 'admin_profile', true);
  update public.operators
  set registered_name = v_registered_name,
      username = v_username,
      unit_id = p_unit_id,
      role = p_role,
      session_policy = p_session_policy,
      active = coalesce(p_active, active),
      updated_at = clock_timestamp()
  where id = p_operator;
end;
$$;

create or replace function public.update_my_operator_display_name(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator public.operators%rowtype;
  v_display_name text;
  v_normalized_name text;
  v_compact_name text;
  v_server_now timestamptz := clock_timestamp();
  v_last_applied_at timestamptz;
  v_next_change_at timestamptz;
  v_attempt_count integer;
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

  select max(applied_at) into v_last_applied_at
  from public.operator_display_name_requests
  where operator_id = v_operator.id
    and applied_at is not null;

  v_next_change_at := case
    when v_last_applied_at is null then null
    else v_last_applied_at + interval '15 days'
  end;

  if v_operator.display_name = v_display_name then
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

  select count(*)::integer into v_attempt_count
  from public.operator_display_name_requests
  where operator_id = v_operator.id
    and actor_type = 'operator'
    and occurred_at >= v_server_now - interval '10 minutes';

  if v_attempt_count >= 5 then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_RATE_LIMITED',
        'message', 'Muitas tentativas. Aguarde alguns minutos para tentar novamente.',
        'retryable', true,
        'retry_at', (
          select min(occurred_at) + interval '10 minutes'
          from public.operator_display_name_requests
          where operator_id = v_operator.id
            and actor_type = 'operator'
            and occurred_at >= v_server_now - interval '10 minutes'
        )
      )
    );
  end if;

  v_normalized_name := private.normalize_operator_display_name(v_display_name, false);
  v_compact_name := private.normalize_operator_display_name(v_display_name, true);

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

create or replace function public.admin_list_operator_display_name_requests(
  p_request jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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

create or replace function public.admin_list_operator_display_name_terms(
  p_request jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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

create or replace function public.admin_upsert_operator_display_name_term(
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

create or replace function public.admin_review_operator_display_name_request(
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function public.admin_create_operator(uuid, text, text, uuid, text, text, boolean) from public, anon;
grant execute on function public.admin_create_operator(uuid, text, text, uuid, text, text, boolean) to authenticated;

revoke all on function public.admin_update_operator_profile_v2(uuid, text, text, uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.admin_update_operator_profile_v2(uuid, text, text, uuid, text, text, boolean) to authenticated;

revoke all on function public.update_my_operator_display_name(text) from public, anon, authenticated;
grant execute on function public.update_my_operator_display_name(text) to authenticated;

revoke all on function public.admin_list_operator_display_name_requests(jsonb) from public, anon, authenticated;
grant execute on function public.admin_list_operator_display_name_requests(jsonb) to authenticated;

revoke all on function public.admin_list_operator_display_name_terms(jsonb) from public, anon, authenticated;
grant execute on function public.admin_list_operator_display_name_terms(jsonb) to authenticated;

revoke all on function public.admin_upsert_operator_display_name_term(jsonb) from public, anon, authenticated;
grant execute on function public.admin_upsert_operator_display_name_term(jsonb) to authenticated;

revoke all on function public.admin_review_operator_display_name_request(jsonb) from public, anon, authenticated;
grant execute on function public.admin_review_operator_display_name_request(jsonb) to authenticated;

commit;
