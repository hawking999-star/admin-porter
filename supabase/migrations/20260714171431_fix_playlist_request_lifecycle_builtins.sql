begin;

-- A migration de ciclo de vida foi aplicada primeiro no remoto. Mantemos esta
-- correção autocontida para bancos novos e para alinhar o histórico local.
alter table public.playlist_requests
  add column if not exists download_job_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'playlist_requests_download_job_id_fkey'
      and conrelid = 'public.playlist_requests'::pg_catalog.regclass
  ) then
    alter table public.playlist_requests
      add constraint playlist_requests_download_job_id_fkey
      foreign key (download_job_id)
      references public.download_jobs(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists playlist_requests_download_job_idx
  on public.playlist_requests(download_job_id)
  where download_job_id is not null;

-- NULLIF, COALESCE, LEAST e GREATEST são expressões especiais do PostgreSQL,
-- não funções que possam ser qualificadas como pg_catalog.<nome>. A versão
-- remota anterior fazia essa qualificação e falhava com SQLSTATE 42883 antes de
-- executar qualquer regra do contrato.
create or replace function public.manage_operator_playlist(p_request jsonb)
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

create or replace function public.admin_review_playlist(
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
$$;

revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb) to authenticated;

revoke all on function public.admin_review_playlist(uuid, text, text) from public, anon;
grant execute on function public.admin_review_playlist(uuid, text, text) to authenticated;

revoke all on function public.get_my_playlist_requests(jsonb) from public, anon;
grant execute on function public.get_my_playlist_requests(jsonb) to authenticated;

commit;
