begin;

-- Serializa o preflight com a implementacao interna. Assim dois cliques ou
-- retries concorrentes nao conseguem criar duas solicitacoes da mesma categoria.
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
  v_type text := lower(coalesce(nullif(p_request->>'type', ''), 'principal'));
  v_url text := nullif(btrim(p_request->>'url'), '');
  v_key uuid := private.try_uuid(nullif(p_request->>'idempotency_key', ''));
  v_request_id_raw text := nullif(p_request->>'request_id', '');
  v_request_id uuid := private.try_uuid(v_request_id_raw);
  v_request_id_text text := coalesce(v_request_id::text, gen_random_uuid()::text);
begin
  if lower(coalesce(p_request->>'operation', '')) = 'submit'
     and v_uid is not null
     and v_key is not null
     and v_url is not null
     and v_type in ('principal', 'secondary')
     and (v_request_id_raw is null or v_request_id is not null)
  then
    select o.id into v_operator_id
    from public.operators o
    where o.auth_user_id = v_uid and o.active is true;

    if v_operator_id is not null then
      perform pg_advisory_xact_lock(hashtext('operator-playlists:' || v_operator_id::text));

      -- Retry legitimo: a implementacao interna devolve a resposta idempotente.
      if exists (
        select 1 from public.playlist_requests r
        where r.operator_id = v_operator_id and r.idempotency_key = v_key
      ) then
        return public.manage_operator_playlist_impl(p_request);
      end if;

      -- Nunca sobrescreva a Principal enquanto o Worker processa o link aprovado.
      if exists (
        select 1
        from public.playlists p
        join public.download_jobs j on j.playlist_id = p.id
        where p.created_by_operator_id = v_operator_id
          and p.type = v_type
          and j.status in ('queued', 'running')
      ) then
        return public._app_envelope(
          v_request_id_text,
          false,
          null,
          jsonb_build_object('code', 'PLAYLIST_IMPORT_IN_PROGRESS'),
          null
        );
      end if;

      -- Uma solicitacao pendente precisa de decisao antes de outro envio.
      if exists (
        select 1
        from public.playlist_requests r
        join public.playlists p on p.id = r.playlist_id
        where r.operator_id = v_operator_id
          and p.type = v_type
          and r.status = 'pending'
      ) then
        return public._app_envelope(
          v_request_id_text,
          false,
          null,
          jsonb_build_object('code', 'PLAYLIST_REQUEST_ALREADY_PENDING'),
          null
        );
      end if;
    end if;
  end if;

  v_response := public.manage_operator_playlist_impl(p_request);

  if lower(coalesce(p_request->>'operation', '')) <> 'submit'
     or coalesce((v_response->>'success')::boolean, false) is not true
     or v_uid is null
     or v_key is null
     or v_url is null
  then
    return v_response;
  end if;

  if v_operator_id is null then
    select o.id into v_operator_id
    from public.operators o
    where o.auth_user_id = v_uid and o.active is true;
  end if;

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

  insert into public.playlist_requests (
    operator_id, playlist_id, source_url, status, request_id, idempotency_key
  ) values (
    v_operator_id, v_playlist_id, v_url, 'pending', v_request_id, v_key
  );

  return v_response;
end;
$$;

-- Registra de forma inequivoca qual sessao administrativa decidiu a solicitacao.
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
  v_before jsonb;
  v_after jsonb;
  v_audit_request_id uuid := gen_random_uuid();
begin
  select to_jsonb(p) into v_before
  from public.playlists p
  where p.id = p_playlist;

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

  select to_jsonb(p) into v_after
  from public.playlists p
  where p.id = p_playlist;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, request_id,
    before_data, after_data, reason, occurred_at
  ) values (
    v_admin_id,
    case when v_status = 'approved' then 'playlist_approved' else 'playlist_rejected' end,
    'playlists',
    p_playlist,
    v_audit_request_id,
    v_before,
    v_after,
    case when v_status = 'rejected' then nullif(btrim(p_reason), '') else null end,
    now()
  );

  return v_response;
end;
$$;

revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb) to authenticated;
revoke all on function public.admin_review_playlist(uuid, text, text) from public, anon;
grant execute on function public.admin_review_playlist(uuid, text, text) to authenticated;

commit;
