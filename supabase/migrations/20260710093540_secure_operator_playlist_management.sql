-- Contrato do App do Operador: somente RPCs.  O importador pode usar service_role,
-- mas estes gatilhos continuam sendo aplicados a ele.

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

drop trigger if exists trg_enforce_track_duration_limit on public.tracks;
create trigger trg_enforce_track_duration_limit
before insert or update of duration_ms on public.tracks
for each row execute function private.enforce_track_duration_limit();

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

drop trigger if exists trg_enforce_principal_track_limit on public.playlist_tracks;
create trigger trg_enforce_principal_track_limit
before insert on public.playlist_tracks
for each row execute function private.enforce_principal_track_limit();

create or replace function public.manage_operator_playlist(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_request_id text := p_request->>'request_id';
  v_key uuid := nullif(p_request->>'idempotency_key','')::uuid;
  v_operation text := lower(coalesce(nullif(p_request->>'operation',''), ''));
  v_hash text := md5(coalesce(p_request - 'request_id', '{}'::jsonb)::text);
  v_op public.operators%rowtype;
  v_playlist public.playlists%rowtype;
  v_cached public.app_request_idempotency%rowtype;
  v_playlist_id uuid := nullif(p_request->>'playlist_id','')::uuid;
  v_expected bigint := nullif(p_request->>'expected_revision','')::bigint;
  v_name text := nullif(btrim(p_request->>'name'),'');
  v_url text := nullif(btrim(p_request->>'url'),'');
  v_ids uuid[];
  v_count integer;
  v_changed integer := 0;
  v_response jsonb;
  v_event_payload jsonb;
  v_type text;
begin
  if v_uid is null then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','FORBIDDEN','message','Sessao ausente.'),null);
  end if;
  select * into v_op from public.operators where auth_user_id = v_uid and active is true;
  if not found then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','FORBIDDEN','message','Operador nao autorizado.'),null);
  end if;
  if v_key is null then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','IDEMPOTENCY_KEY_REQUIRED','message','idempotency_key e obrigatoria.'),null);
  end if;

  select * into v_cached from public.app_request_idempotency where idempotency_key = v_key;
  if found then
    if v_cached.rpc_name = 'manage_operator_playlist'
       and v_cached.operator_id = v_op.id and v_cached.request_hash = v_hash then
      return v_cached.response;
    end if;
    return public._app_envelope(v_request_id,false,null,
      jsonb_build_object('code','IDEMPOTENCY_KEY_REUSED','message','A chave de idempotencia ja foi usada para outra solicitacao.'),null);
  end if;

  if v_operation not in ('submit','rename','archive_secondary','remove_tracks','reorder_tracks') then
    return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_OPERATION','message','Operacao de playlist invalida.'),null);
  end if;

  -- Um lock por Operador cobre criacao/arquivamento concorrentes de secundarias.
  perform pg_advisory_xact_lock(hashtext('operator-playlists:' || v_op.id::text));

  if v_operation = 'submit' then
    v_type := lower(coalesce(nullif(p_request->>'type',''), 'principal'));
    if v_type not in ('principal','secondary') or v_url is null or v_url !~* '^https?://' or length(v_url) > 2048 then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INVALID_URL','message','Informe uma URL http(s) valida.'),null);
    end if;
    if v_type = 'principal' then
      select * into v_playlist from public.playlists
       where created_by_operator_id=v_op.id and type='principal' for update;
      if found then
        if v_expected is null or v_expected <> v_playlist.revision then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_REVISION_CONFLICT','current_revision',v_playlist.revision),null);
        end if;
        update public.playlists set source_url=v_url, name=coalesce(v_name,name), approval_status='pending',
          status='draft', submitted_at=now(), rejection_reason=null, revision=revision+1, updated_at=now()
          where id=v_playlist.id returning * into v_playlist;
      else
        insert into public.playlists(unit_id,name,type,status,approval_status,created_by_operator_id,source_url,submitted_at)
          values(v_op.unit_id,coalesce(v_name,'Playlist principal'),'principal','draft','pending',v_op.id,v_url,now())
          returning * into v_playlist;
      end if;
    else
      select count(*) into v_count from public.playlists
       where created_by_operator_id=v_op.id and type='secondary' and status <> 'archived' and approval_status <> 'rejected';
      if v_count >= 2 then
        return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','SECONDARY_LIMIT_REACHED','limit',2),null);
      end if;
      insert into public.playlists(unit_id,name,type,status,approval_status,created_by_operator_id,source_url,submitted_at)
        values(v_op.unit_id,coalesce(v_name,'Playlist secundaria'),'secondary','draft','pending',v_op.id,v_url,now())
        returning * into v_playlist;
    end if;
    v_event_payload := jsonb_build_object('operation','submit','playlist_id',v_playlist.id,'type',v_playlist.type,'revision',v_playlist.revision);
  else
    if v_playlist_id is null then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED','message','playlist_id e obrigatorio.'),null);
    end if;
    select * into v_playlist from public.playlists
      where id=v_playlist_id and created_by_operator_id=v_op.id for update;
    if not found then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED','message','Playlist nao pertence ao Operador.'),null);
    end if;
    if v_expected is null or v_expected <> v_playlist.revision then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_REVISION_CONFLICT','current_revision',v_playlist.revision),null);
    end if;
    if v_playlist.status = 'archived' then
      return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED','message','Playlist arquivada nao pode ser alterada.'),null);
    end if;

    if v_operation = 'rename' then
      if v_name is null then
        return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_REQUIRED','message','Informe um nome.'),null);
      end if;
      if char_length(v_name)>80 then
        return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','NAME_TOO_LONG','max_length',80),null);
      end if;
      update public.playlists set name=v_name, revision=revision+1, updated_at=now()
       where id=v_playlist.id and name is distinct from v_name returning * into v_playlist;
      if not found then select * into v_playlist from public.playlists where id=v_playlist_id; end if;
    elsif v_operation = 'archive_secondary' then
      if v_playlist.type <> 'secondary' then
        return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED','message','Somente playlists secundarias podem ser arquivadas.'),null);
      end if;
      update public.playlists set status='archived', revision=revision+1, updated_at=now() where id=v_playlist.id returning * into v_playlist;
    else
      select array_agg(x.value::uuid) into v_ids from jsonb_array_elements_text(coalesce(p_request->'playlist_track_ids','[]'::jsonb)) x(value);
      if coalesce(array_length(v_ids,1),0)=0 then
        return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE','message','Nenhuma faixa valida foi informada.'),null);
      end if;
      if v_operation='remove_tracks' then
        delete from public.playlist_tracks where playlist_id=v_playlist.id and id=any(v_ids);
        get diagnostics v_changed = row_count;
        if v_changed <> cardinality(v_ids) then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE','message','Uma ou mais faixas nao estao na playlist.'),null);
        end if;
        update public.playlists set revision=revision+1, updated_at=now() where id=v_playlist.id returning * into v_playlist;
      else
        select count(*) into v_count from public.playlist_tracks pt join public.tracks t on t.id=pt.track_id
          where pt.playlist_id=v_playlist.id and pt.id=any(v_ids) and t.status='available';
        if v_count <> cardinality(v_ids) or v_count <> (select count(*) from public.playlist_tracks where playlist_id=v_playlist.id) then
          return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE','message','A ordenacao deve conter todas as faixas disponiveis da playlist.'),null);
        end if;
        -- Duas fases evitam colisao de posicao durante a reordenacao.
        update public.playlist_tracks set position=position+1000000 where playlist_id=v_playlist.id;
        update public.playlist_tracks pt set position=s.ord-1
          from unnest(v_ids) with ordinality as s(id,ord) where pt.id=s.id and pt.playlist_id=v_playlist.id;
        update public.playlists set revision=revision+1, updated_at=now() where id=v_playlist.id returning * into v_playlist;
      end if;
    end if;
    v_event_payload := jsonb_build_object('operation',v_operation,'playlist_id',v_playlist.id,'type',v_playlist.type,'revision',v_playlist.revision,'changed',v_changed);
  end if;

  insert into public.operational_events(event_type,operator_id,unit_id,related_entity_type,related_entity_id,idempotency_key,payload)
    values('playlist_changed',v_op.id,v_op.unit_id,'playlist',v_playlist.id,v_key,v_event_payload);
  v_response := public._app_envelope(v_request_id,true,jsonb_build_object('playlist',jsonb_build_object(
    'id',v_playlist.id,'type',v_playlist.type,'name',v_playlist.name,'status',v_playlist.status,'revision',v_playlist.revision)),null,
    jsonb_build_object('code','PLAYLIST_CHANGED','revision',v_playlist.revision));
  insert into public.app_request_idempotency(idempotency_key,rpc_name,operator_id,request_hash,response)
    values(v_key,'manage_operator_playlist',v_op.id,v_hash,v_response);
  return v_response;
exception when unique_violation then
  return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','IDEMPOTENCY_KEY_REUSED'),null);
when check_violation then
  return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','TRACK_NOT_AVAILABLE','message',SQLERRM),null);
when others then
  return public._app_envelope(v_request_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;

create or replace function public.rename_principal_playlist(p_request jsonb) returns jsonb
language sql security definer set search_path = '' as $$
  select public.manage_operator_playlist(jsonb_set(p_request,'{operation}',to_jsonb('rename'::text),true));
$$;

create or replace function public.submit_playlist(p_request jsonb) returns jsonb
language sql security definer set search_path = '' as $$
  select public.manage_operator_playlist(jsonb_set(p_request,'{operation}',to_jsonb('submit'::text),true));
$$;

create or replace function public.get_my_playlists(p_request jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid:=auth.uid(); v_req text:=p_request->>'request_id'; v_op public.operators%rowtype; v_rows jsonb; v_sec int;
begin
  select * into v_op from public.operators where auth_user_id=v_uid and active is true;
  if v_uid is null or not found then return public._app_envelope(v_req,false,null,jsonb_build_object('code','FORBIDDEN'),null); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'status',p.status,'approval_status',p.approval_status,'revision',p.revision,
    'capabilities',jsonb_build_object('can_rename',p.status<>'archived','can_archive',p.type='secondary' and p.status<>'archived','can_remove_tracks',p.status<>'archived','can_reorder_tracks',p.status<>'archived')) order by p.type,p.created_at),'[]'::jsonb) into v_rows from public.playlists p where p.created_by_operator_id=v_op.id;
  select count(*) into v_sec from public.playlists where created_by_operator_id=v_op.id and type='secondary' and status<>'archived' and approval_status<>'rejected';
  return public._app_envelope(v_req,true,jsonb_build_object('playlists',v_rows,'capabilities',jsonb_build_object('can_create_secondary',v_sec<2,'can_submit_principal',true)),null,jsonb_build_object('secondary_limit',2,'secondary_count',v_sec,'principal_track_limit',170,'track_duration_limit_seconds',960));
end;
$$;

create or replace function public.get_playlist_tracks(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid:=auth.uid(); v_req text:=p_request->>'request_id'; v_pid uuid:=nullif(p_request->>'playlist_id','')::uuid; v_op public.operators%rowtype; v_pl public.playlists%rowtype; v_rows jsonb;
begin
  select * into v_op from public.operators where auth_user_id=v_uid and active is true;
  if v_uid is null or not found then return public._app_envelope(v_req,false,null,jsonb_build_object('code','FORBIDDEN'),null); end if;
  select * into v_pl from public.playlists where id=v_pid and created_by_operator_id=v_op.id;
  if not found then return public._app_envelope(v_req,false,null,jsonb_build_object('code','PLAYLIST_NOT_ALLOWED'),null); end if;
  select coalesce(jsonb_agg(jsonb_build_object('playlist_track_id',pt.id,'id',t.id,'title',t.title,'artist',t.artist,'duration_ms',t.duration_ms,'position',pt.position,'public_url',t.metadata->>'public_url','status',t.status) order by pt.position),'[]'::jsonb) into v_rows from public.playlist_tracks pt join public.tracks t on t.id=pt.track_id where pt.playlist_id=v_pl.id and t.status='available';
  return public._app_envelope(v_req,true,jsonb_build_object('playlist_id',v_pl.id,'playlist_revision',v_pl.revision,'tracks',v_rows),null,null);
end;
$$;

revoke all on function private.enforce_track_duration_limit() from public, anon, authenticated;
revoke all on function private.enforce_principal_track_limit() from public, anon, authenticated;
revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
revoke all on function public.rename_principal_playlist(jsonb) from public, anon;
revoke all on function public.submit_playlist(jsonb) from public, anon;
revoke all on function public.get_my_playlists(jsonb) from public, anon;
revoke all on function public.get_playlist_tracks(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb), public.rename_principal_playlist(jsonb), public.submit_playlist(jsonb), public.get_my_playlists(jsonb), public.get_playlist_tracks(jsonb) to authenticated;

-- Nenhum cliente autenticado consulta ou altera faixas/vinculos diretamente.
revoke all on table public.tracks, public.playlist_tracks from anon, authenticated;
