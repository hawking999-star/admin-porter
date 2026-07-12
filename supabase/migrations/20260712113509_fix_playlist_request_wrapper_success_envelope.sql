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
  v_request_id uuid := private.try_uuid(nullif(p_request->>'request_id', ''));
begin
  v_response := public.manage_operator_playlist_impl(p_request);

  if lower(coalesce(p_request->>'operation', '')) <> 'submit'
     or coalesce((v_response->>'success')::boolean, false) is not true
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

revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb) to authenticated;
