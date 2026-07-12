begin;

create table if not exists public.playlist_requests (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  source_url text not null check (btrim(source_url) <> ''),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  request_id uuid,
  idempotency_key uuid not null,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.admin_users(id) on delete set null,
  is_legacy boolean not null default false,
  constraint playlist_requests_idempotency_key_key unique (idempotency_key),
  constraint playlist_requests_decision_check check (
    (status = 'pending' and decided_at is null and rejection_reason is null)
    or (status = 'approved' and decided_at is not null and rejection_reason is null)
    or (status = 'rejected' and decided_at is not null)
  )
);

create unique index if not exists playlist_requests_one_legacy_per_playlist_idx
  on public.playlist_requests (playlist_id)
  where is_legacy;

create index if not exists playlist_requests_operator_created_idx
  on public.playlist_requests (operator_id, created_at desc);

create index if not exists playlist_requests_playlist_pending_idx
  on public.playlist_requests (playlist_id, created_at desc)
  where status = 'pending';

alter table public.playlist_requests enable row level security;
revoke all on table public.playlist_requests from public, anon, authenticated;

-- A snapshot of each already-submitted playlist. Drafts have never been sent,
-- so they intentionally do not become historical requests.
insert into public.playlist_requests (
  operator_id, playlist_id, source_url, status, idempotency_key,
  rejection_reason, created_at, updated_at, decided_at, decided_by, is_legacy
)
select
  p.created_by_operator_id,
  p.id,
  btrim(p.source_url),
  p.approval_status,
  (substr(md5('playlist-request-legacy:' || p.id::text), 1, 8) || '-' ||
   substr(md5('playlist-request-legacy:' || p.id::text), 9, 4) || '-' ||
   substr(md5('playlist-request-legacy:' || p.id::text), 13, 4) || '-' ||
   substr(md5('playlist-request-legacy:' || p.id::text), 17, 4) || '-' ||
   substr(md5('playlist-request-legacy:' || p.id::text), 21, 12))::uuid,
  case when p.approval_status = 'rejected'
    then nullif(left(btrim(regexp_replace(coalesce(p.rejection_reason, ''), '[[:cntrl:]]+', ' ', 'g')), 500), '')
    else null end,
  coalesce(p.submitted_at, p.created_at),
  coalesce(p.reviewed_at, p.updated_at, p.submitted_at, p.created_at),
  case when p.approval_status in ('approved', 'rejected')
    then coalesce(p.reviewed_at, p.updated_at, p.submitted_at, p.created_at) else null end,
  case when p.approval_status in ('approved', 'rejected') then p.reviewed_by_admin_id else null end,
  true
from public.playlists p
where p.created_by_operator_id is not null
  and nullif(btrim(p.source_url), '') is not null
  and p.approval_status in ('pending', 'approved', 'rejected')
on conflict (playlist_id) where is_legacy do nothing;

-- Keep the existing implementation intact behind a private entry point. The
-- public wrapper below preserves the exact RPC signature and response shape.
alter function public.manage_operator_playlist(jsonb) rename to manage_operator_playlist_impl;
revoke all on function public.manage_operator_playlist_impl(jsonb) from public, anon, authenticated;

create function public.manage_operator_playlist(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response jsonb;
  v_uid uuid := auth.uid();
  v_operator_id uuid;
  v_playlist_id uuid;
  v_type text := lower(coalesce(nullif(p_request->>'type', ''), 'principal'));
  v_url text := nullif(btrim(p_request->>'url'), '');
  v_key uuid := private.try_uuid(nullif(p_request->>'idempotency_key', ''));
  v_request_id uuid := private.try_uuid(nullif(p_request->>'request_id', ''));
begin
  v_response := public.manage_operator_playlist_impl(p_request);

  if lower(coalesce(p_request->>'operation', '')) <> 'submit'
     or coalesce((v_response->>'ok')::boolean, false) is not true
     or v_uid is null
     or v_key is null
     or v_url is null
  then
    return v_response;
  end if;

  select o.id into v_operator_id
  from public.operators o
  where o.auth_user_id = v_uid and o.active is true;

  if v_operator_id is null
     or exists (select 1 from public.playlist_requests r where r.idempotency_key = v_key)
  then
    return v_response;
  end if;

  select p.id into v_playlist_id
  from public.playlists p
  where p.created_by_operator_id = v_operator_id
    and p.type = v_type
    and p.source_url = v_url
  order by p.submitted_at desc nulls last, p.created_at desc
  limit 1;

  if v_playlist_id is null then
    raise exception 'playlist_request_link_not_found';
  end if;

  -- The principal playlist is overwritten on each manual submission. Close an
  -- older still-pending occurrence before recording the new independent one.
  if v_type = 'principal' then
    update public.playlist_requests r
       set status = 'rejected',
           rejection_reason = 'Solicitação substituída por um novo envio.',
           updated_at = now(),
           decided_at = now(),
           decided_by = null
     where r.playlist_id = v_playlist_id
       and r.status = 'pending';
  end if;

  insert into public.playlist_requests (
    operator_id, playlist_id, source_url, status, request_id, idempotency_key
  ) values (
    v_operator_id, v_playlist_id, v_url, 'pending', v_request_id, v_key
  );

  return v_response;
end;
$$;

-- This legacy public RPC remains supported and now uses the public wrapper.
create or replace function public.submit_playlist(p_request jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.manage_operator_playlist(jsonb_set(p_request, '{operation}', to_jsonb('submit'::text), true));
$$;

alter function public.admin_review_playlist(uuid, text, text) rename to admin_review_playlist_impl;
revoke all on function public.admin_review_playlist_impl(uuid, text, text) from public, anon, authenticated;

create function public.admin_review_playlist(
  p_playlist uuid,
  p_action text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response jsonb;
  v_status text;
  v_admin_id uuid;
begin
  v_response := public.admin_review_playlist_impl(p_playlist, p_action, p_reason);
  v_status := case when p_action = 'approve' then 'approved' when p_action = 'reject' then 'rejected' else null end;

  if v_status is null then
    return v_response;
  end if;

  select a.id into v_admin_id
  from public.admin_users a
  where a.auth_user_id = auth.uid() and a.active is true;

  update public.playlist_requests r
     set status = v_status,
         updated_at = now(),
         decided_at = now(),
         decided_by = v_admin_id,
         rejection_reason = case when v_status = 'rejected'
           then nullif(left(btrim(regexp_replace(coalesce(p_reason, ''), '[[:cntrl:]]+', ' ', 'g')), 500), '')
           else null end
   where r.id = (
     select pending.id
     from public.playlist_requests pending
     where pending.playlist_id = p_playlist and pending.status = 'pending'
     order by pending.created_at desc, pending.id desc
     limit 1
     for update
   );

  return v_response;
end;
$$;

create or replace function public.get_my_playlist_requests(
  p_request jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_operator_id uuid;
  v_request_id uuid := gen_random_uuid();
  v_request_id_text text;
  v_limit integer := 20;
  v_rows jsonb := '[]'::jsonb;
begin
  if p_request is null or jsonb_typeof(p_request) <> 'object' then
    return jsonb_build_object(
      'success', false, 'request_id', v_request_id, 'server_now', now(),
      'data', null, 'error', jsonb_build_object('code', 'INVALID_REQUEST')
    );
  end if;

  v_request_id_text := nullif(p_request->>'request_id', '');
  if v_request_id_text is not null then
    v_request_id := private.try_uuid(v_request_id_text);
    if v_request_id is null then
      return jsonb_build_object(
        'success', false, 'request_id', null, 'server_now', now(),
        'data', null, 'error', jsonb_build_object('code', 'INVALID_UUID', 'field', 'request_id')
      );
    end if;
  end if;

  if p_request ? 'limit' then
    if coalesce(p_request->>'limit', '') !~ '^[0-9]+$' then
      return jsonb_build_object(
        'success', false, 'request_id', v_request_id, 'server_now', now(),
        'data', null, 'error', jsonb_build_object('code', 'INVALID_LIMIT')
      );
    end if;
    v_limit := least(greatest((p_request->>'limit')::integer, 1), 100);
  end if;

  if v_uid is null then
    return jsonb_build_object(
      'success', false, 'request_id', v_request_id, 'server_now', now(),
      'data', null, 'error', jsonb_build_object('code', 'FORBIDDEN')
    );
  end if;

  select o.id into v_operator_id
  from public.operators o
  where o.auth_user_id = v_uid and o.active is true;

  if v_operator_id is null then
    return jsonb_build_object(
      'success', false, 'request_id', v_request_id, 'server_now', now(),
      'data', null, 'error', jsonb_build_object('code', 'FORBIDDEN')
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'playlist_id', r.playlist_id,
    'source_url', r.source_url,
    'status', r.status,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'rejection_reason', case when r.status = 'rejected'
      then nullif(left(btrim(regexp_replace(coalesce(r.rejection_reason, ''), '[[:cntrl:]]+', ' ', 'g')), 500), '')
      else null end
  ) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_rows
  from (
    select * from public.playlist_requests
    where operator_id = v_operator_id
    order by created_at desc, id desc
    limit v_limit
  ) r;

  return jsonb_build_object(
    'success', true,
    'request_id', v_request_id,
    'server_now', now(),
    'data', jsonb_build_object('requests', v_rows),
    'error', null
  );
end;
$$;

revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
revoke all on function public.submit_playlist(jsonb) from public, anon;
revoke all on function public.admin_review_playlist(uuid, text, text) from public, anon;
revoke all on function public.get_my_playlist_requests(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb) to authenticated;
grant execute on function public.submit_playlist(jsonb) to authenticated;
grant execute on function public.admin_review_playlist(uuid, text, text) to authenticated;
grant execute on function public.get_my_playlist_requests(jsonb) to authenticated;

commit;
