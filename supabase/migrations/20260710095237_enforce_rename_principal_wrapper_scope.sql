create or replace function public.rename_principal_playlist(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function public.rename_principal_playlist(jsonb) from public,anon;
grant execute on function public.rename_principal_playlist(jsonb) to authenticated;
