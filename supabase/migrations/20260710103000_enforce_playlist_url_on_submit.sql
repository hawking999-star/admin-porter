-- Trava de defesa em profundidade: no submit, links do YouTube precisam ser de uma
-- PLAYLIST (têm `list=`), não de um vídeo único. Espelha a validação do app.
-- Rejeita também playlists automáticas do YouTube (mix/rádio: list=RD/UL/LL/WL).
-- Retorna o erro tipado URL_NOT_A_PLAYLIST no envelope padrão.
--
-- Recria manage_operator_playlist adicionando o guard logo após a checagem INVALID_URL
-- do ramo `submit`. O restante da função é idêntico à versão anterior.

CREATE OR REPLACE FUNCTION public.manage_operator_playlist(p_request jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
