-- Teste único consolidado. Todos os dados são revertidos ao final.
begin;

create temporary table contract_test_samples(name text primary key, response jsonb) on commit drop;

do $$
declare
  v_op1 public.operators%rowtype;
  v_op2 public.operators%rowtype;
  v_p1 uuid; v_p2 uuid; v_s1 uuid; v_s2 uuid;
  v_p1_rev bigint:=1; v_p2_rev bigint:=1; v_s1_rev bigint; v_s2_rev bigint;
  v_ta uuid; v_tb uuid; v_tc uuid;
  v_pta1 uuid; v_ptb1 uuid; v_ptc1 uuid; v_pta2 uuid;
  v_desta uuid; v_destb uuid;
  v_job uuid; v_key uuid;
  v_resp jsonb; v_resp2 jsonb; v_payload jsonb; v_caps jsonb;
  v_count integer;
begin
  select * into v_op1 from public.operators o
   where o.active and o.auth_user_id is not null
     and not exists(select 1 from public.playlists p where p.created_by_operator_id=o.id and p.type='principal')
   order by o.id limit 1;
  select * into v_op2 from public.operators o
   where o.active and o.auth_user_id is not null and o.id<>v_op1.id
     and not exists(select 1 from public.playlists p where p.created_by_operator_id=o.id and p.type='principal')
   order by o.id limit 1;
  if v_op1.id is null or v_op2.id is null then raise exception 'TEST_SETUP: dois Operadores livres sao necessarios'; end if;

  insert into public.playlists(unit_id,name,type,status,approval_status,import_status,created_by_operator_id)
    values(v_op1.unit_id,'Teste Principal A','principal','active','approved','success',v_op1.id) returning id into v_p1;
  insert into public.playlists(unit_id,name,type,status,approval_status,import_status,created_by_operator_id)
    values(v_op2.unit_id,'Teste Principal B','principal','active','approved','success',v_op2.id) returning id into v_p2;

  insert into public.tracks(title,duration_ms,storage_object_key,status,metadata)
    values('Teste A',1000,'contract-test/'||gen_random_uuid()||'.mp3','available',jsonb_build_object('public_url','https://example.invalid/a.mp3')) returning id into v_ta;
  insert into public.tracks(title,duration_ms,storage_object_key,status,metadata)
    values('Teste B',1000,'contract-test/'||gen_random_uuid()||'.mp3','available',jsonb_build_object('public_url','https://example.invalid/b.mp3')) returning id into v_tb;
  insert into public.tracks(title,duration_ms,storage_object_key,status,metadata)
    values('Teste C',1000,'contract-test/'||gen_random_uuid()||'.mp3','available',jsonb_build_object('public_url','https://example.invalid/c.mp3')) returning id into v_tc;
  insert into public.playlist_tracks(playlist_id,track_id,position,added_by_type) values(v_p1,v_ta,0,'system') returning id into v_pta1;
  insert into public.playlist_tracks(playlist_id,track_id,position,added_by_type) values(v_p1,v_tb,1,'system') returning id into v_ptb1;
  insert into public.playlist_tracks(playlist_id,track_id,position,added_by_type) values(v_p1,v_tc,2,'system') returning id into v_ptc1;
  insert into public.playlist_tracks(playlist_id,track_id,position,added_by_type) values(v_p2,v_ta,0,'system') returning id into v_pta2;

  perform set_config('request.jwt.claim.sub',v_op1.auth_user_id::text,true);

  v_resp:=public.get_my_playlists(jsonb_build_object('request_id','test-read'));
  if not (v_resp->>'success')::boolean or (v_resp#>>'{data,secondary_limit}')::int<>2
     or (v_resp#>>'{data,principal_track_limit}')::int<>170
     or (v_resp#>>'{data,track_duration_limit_seconds}')::int<>960 then
    raise exception 'READ_LIMITS_FAILED: %',v_resp;
  end if;
  select x into v_caps from jsonb_array_elements(v_resp#>'{data,playlists}') x where x->>'id'=v_p1::text;
  if not (v_caps#>>'{capabilities,can_remove_from_principal}')::boolean
     or (v_caps#>>'{capabilities,can_archive}')::boolean then raise exception 'PRINCIPAL_CAPABILITIES_FAILED'; end if;

  v_resp:=public.get_playlist_tracks(jsonb_build_object('request_id','test-tracks','playlist_id',v_p1));
  if not (v_resp->>'success')::boolean or (v_resp#>'{data,tracks,0}') ? 'id'
     or (v_resp#>'{data,tracks,0}') ? 'storage_object_key' then raise exception 'TRACK_READ_EXPOSURE_FAILED: %',v_resp; end if;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','create-1','idempotency_key',gen_random_uuid(),'operation','create_secondary','name','  Secundaria   Um  '));
  if not (v_resp->>'success')::boolean then raise exception 'CREATE_SECONDARY_1_FAILED: %',v_resp; end if;
  v_s1:=(v_resp#>>'{data,created_playlist,id}')::uuid; v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;
  insert into contract_test_samples values('create_secondary',v_resp);

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','create-2','idempotency_key',gen_random_uuid(),'operation','create_secondary','name','Secundaria Dois'));
  if not (v_resp->>'success')::boolean then raise exception 'CREATE_SECONDARY_2_FAILED: %',v_resp; end if;
  v_s2:=(v_resp#>>'{data,created_playlist,id}')::uuid; v_s2_rev:=(v_resp#>>'{data,revision}')::bigint;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','create-3','idempotency_key',gen_random_uuid(),'operation','create_secondary','name','Terceira'));
  if v_resp#>>'{error,code}'<>'SECONDARY_LIMIT_REACHED' then raise exception 'THIRD_SECONDARY_NOT_BLOCKED: %',v_resp; end if;
  insert into contract_test_samples values('secondary_limit',v_resp);

  v_resp:=public.rename_principal_playlist(jsonb_build_object('request_id','rename-p','idempotency_key',gen_random_uuid(),'playlist_id',v_p1,'expected_revision',v_p1_rev,'name','Principal Renomeada'));
  if not (v_resp->>'success')::boolean then raise exception 'RENAME_PRINCIPAL_FAILED: %',v_resp; end if;
  v_p1_rev:=(v_resp#>>'{data,revision}')::bigint;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','rename-s1','idempotency_key',gen_random_uuid(),'operation','rename','playlist_id',v_s1,'expected_revision',v_s1_rev,'name','Secundaria A'));
  if not (v_resp->>'success')::boolean then raise exception 'RENAME_SECONDARY_1_FAILED: %',v_resp; end if;
  v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;
  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','rename-s2','idempotency_key',gen_random_uuid(),'operation','rename','playlist_id',v_s2,'expected_revision',v_s2_rev,'name','Secundaria B'));
  if not (v_resp->>'success')::boolean then raise exception 'RENAME_SECONDARY_2_FAILED: %',v_resp; end if;
  v_s2_rev:=(v_resp#>>'{data,revision}')::bigint;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','add-one','idempotency_key',gen_random_uuid(),'operation','add_tracks','playlist_id',v_s1,'expected_revision',v_s1_rev,'source_playlist_track_ids',jsonb_build_array(v_pta1)));
  if not (v_resp->>'success')::boolean or jsonb_array_length(v_resp#>'{data,added_playlist_track_ids}')<>1 then raise exception 'ADD_ONE_FAILED: %',v_resp; end if;
  v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','add-batch','idempotency_key',gen_random_uuid(),'operation','add_tracks','playlist_id',v_s1,'expected_revision',v_s1_rev,'source_playlist_track_ids',jsonb_build_array(v_pta1,v_ptb1)));
  if not (v_resp->>'success')::boolean or jsonb_array_length(v_resp#>'{data,added_playlist_track_ids}')<>1
     or not (v_resp#>'{data,already_present_source_ids}') @> jsonb_build_array(v_pta1) then raise exception 'ADD_BATCH_OR_ALREADY_PRESENT_FAILED: %',v_resp; end if;
  v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;
  insert into contract_test_samples values('add_tracks_batch',v_resp);

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','add-duplicate','idempotency_key',gen_random_uuid(),'operation','add_tracks','playlist_id',v_s1,'expected_revision',v_s1_rev,'source_playlist_track_ids',jsonb_build_array(v_pta1,v_pta1)));
  if v_resp#>>'{error,code}'<>'DUPLICATE_TRACK_REFERENCE' then raise exception 'DUPLICATE_INPUT_NOT_BLOCKED: %',v_resp; end if;

  select id into v_desta from public.playlist_tracks where playlist_id=v_s1 and track_id=v_ta;
  select id into v_destb from public.playlist_tracks where playlist_id=v_s1 and track_id=v_tb;
  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','reorder','idempotency_key',gen_random_uuid(),'operation','reorder_tracks','playlist_id',v_s1,'expected_revision',v_s1_rev,'playlist_track_ids',jsonb_build_array(v_destb,v_desta)));
  if not (v_resp->>'success')::boolean then raise exception 'REORDER_FAILED: %',v_resp; end if;
  v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;
  if (select position from public.playlist_tracks where id=v_destb)<>0 then raise exception 'REORDER_POSITION_FAILED'; end if;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','remove-secondary','idempotency_key',gen_random_uuid(),'operation','remove_tracks','playlist_id',v_s1,'expected_revision',v_s1_rev,'playlist_track_ids',jsonb_build_array(v_destb)));
  if not (v_resp->>'success')::boolean then raise exception 'REMOVE_SECONDARY_FAILED: %',v_resp; end if;
  v_s1_rev:=(v_resp#>>'{data,revision}')::bigint;
  if exists(select 1 from public.playlist_tracks where id=v_destb)
     or not exists(select 1 from public.playlist_tracks where id=v_ptb1)
     or not exists(select 1 from public.tracks where id=v_tb)
     or exists(select 1 from public.storage_deletion_jobs where track_id=v_tb) then raise exception 'REMOVE_SECONDARY_SEMANTICS_FAILED'; end if;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','remove-principal-one','idempotency_key',gen_random_uuid(),'operation','remove_tracks','playlist_id',v_p1,'expected_revision',v_p1_rev,'playlist_track_ids',jsonb_build_array(v_pta1)));
  if not (v_resp->>'success')::boolean then raise exception 'REMOVE_PRINCIPAL_ONE_FAILED: %',v_resp; end if;
  v_p1_rev:=(v_resp#>>'{data,revision}')::bigint;
  if exists(select 1 from public.playlist_tracks pt join public.playlists p on p.id=pt.playlist_id where p.created_by_operator_id=v_op1.id and pt.track_id=v_ta)
     or not exists(select 1 from public.playlist_tracks where id=v_pta2)
     or not exists(select 1 from public.tracks where id=v_ta)
     or exists(select 1 from public.storage_deletion_jobs where track_id=v_ta) then raise exception 'SHARED_TRACK_PRESERVATION_FAILED'; end if;
  insert into contract_test_samples values('remove_principal_shared',v_resp);

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','remove-principal-batch','idempotency_key',gen_random_uuid(),'operation','remove_tracks','playlist_id',v_p1,'expected_revision',v_p1_rev,'playlist_track_ids',jsonb_build_array(v_ptb1,v_ptc1)));
  if not (v_resp->>'success')::boolean or (v_resp#>>'{data,storage_cleanup_queued_count}')::int<>2 then raise exception 'REMOVE_PRINCIPAL_BATCH_FAILED: %',v_resp; end if;
  v_p1_rev:=(v_resp#>>'{data,revision}')::bigint;
  if (select count(*) from public.storage_deletion_jobs where track_id=any(array[v_tb,v_tc]))<>2
     or exists(select 1 from public.tracks where id=any(array[v_tb,v_tc]) and status<>'disabled') then raise exception 'ORPHAN_QUEUE_FAILED'; end if;

  select id into v_job from public.storage_deletion_jobs where track_id=v_tb;
  v_resp:=public.complete_storage_deletion_job(v_job,true,null);
  if not (v_resp->>'success')::boolean or exists(select 1 from public.tracks where id=v_tb) then raise exception 'FINALIZE_LAST_REFERENCE_FAILED: %',v_resp; end if;
  insert into contract_test_samples values('storage_finalize_after_worker_success',v_resp);

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','revision-conflict','idempotency_key',gen_random_uuid(),'operation','rename','playlist_id',v_p1,'expected_revision',1,'name','Nao Aplicar'));
  if v_resp#>>'{error,code}'<>'PLAYLIST_REVISION_CONFLICT' or not (v_resp#>>'{error,reload_required}')::boolean then raise exception 'REVISION_CONFLICT_FAILED: %',v_resp; end if;
  insert into contract_test_samples values('revision_conflict',v_resp);

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','archive','idempotency_key',gen_random_uuid(),'operation','archive_secondary','playlist_id',v_s2,'expected_revision',v_s2_rev));
  if not (v_resp->>'success')::boolean then raise exception 'ARCHIVE_FAILED: %',v_resp; end if;

  perform set_config('request.jwt.claim.sub',v_op2.auth_user_id::text,true);
  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','isolation','idempotency_key',gen_random_uuid(),'operation','rename','playlist_id',v_p1,'expected_revision',v_p1_rev,'name','Ataque'));
  if v_resp#>>'{error,code}'<>'PLAYLIST_NOT_ALLOWED' then raise exception 'OPERATOR_ISOLATION_FAILED: %',v_resp; end if;

  v_resp:=public.manage_operator_playlist(jsonb_build_object('request_id','remove-last-shared','idempotency_key',gen_random_uuid(),'operation','remove_tracks','playlist_id',v_p2,'expected_revision',v_p2_rev,'playlist_track_ids',jsonb_build_array(v_pta2)));
  if not (v_resp->>'success')::boolean or not exists(select 1 from public.storage_deletion_jobs where track_id=v_ta) then raise exception 'LAST_SHARED_REFERENCE_QUEUE_FAILED: %',v_resp; end if;
  v_p2_rev:=(v_resp#>>'{data,revision}')::bigint;

  v_key:=gen_random_uuid();
  v_payload:=jsonb_build_object('request_id','idem','idempotency_key',v_key,'operation','rename','playlist_id',v_p2,'expected_revision',v_p2_rev,'name','Idempotente');
  v_resp:=public.manage_operator_playlist(v_payload);
  v_resp2:=public.manage_operator_playlist(v_payload);
  if v_resp<>v_resp2 or not (v_resp->>'success')::boolean then raise exception 'IDEMPOTENT_RETRY_FAILED'; end if;
  select count(*) into v_count from public.operational_events where idempotency_key=v_key and event_type='playlist_changed';
  if v_count<>1 then raise exception 'IDEMPOTENT_EVENT_DUPLICATED'; end if;
  v_resp2:=public.manage_operator_playlist(jsonb_set(v_payload,'{name}',to_jsonb('Payload Diferente'::text),true));
  if v_resp2#>>'{error,code}'<>'IDEMPOTENCY_KEY_REUSED' then raise exception 'IDEMPOTENCY_REUSE_FAILED: %',v_resp2; end if;
  insert into contract_test_samples values('idempotent_success',v_resp);
  insert into contract_test_samples values('idempotency_key_reused',v_resp2);

  select count(*) into v_count from public.operational_events
   where related_entity_id=any(array[v_p1,v_p2,v_s1,v_s2]) and event_type='playlist_changed';
  if v_count<>14 then raise exception 'AUDIT_EVENT_COUNT_FAILED: esperado 14, encontrado %',v_count; end if;

  perform set_config('request.jwt.claim.sub',v_op1.auth_user_id::text,true);
  v_resp:=public.get_my_playlists(jsonb_build_object('request_id','final-read'));
  if not (v_resp#>>'{data,capabilities,can_create_secondary}')::boolean then raise exception 'CAPABILITY_AFTER_ARCHIVE_FAILED'; end if;
end;
$$;

select jsonb_build_object(
  'success',true,
  'checks',jsonb_build_array(
    'read_and_limits','create_two_secondaries','block_third_secondary','rename_principal_and_secondaries',
    'add_one_and_batch','prevent_duplicates','reorder','remove_secondary_only','remove_principal_cascade',
    'preserve_shared_track','queue_last_reference','finalize_after_storage_success','revision_conflict',
    'idempotency','operator_isolation','playlist_changed_audit','capabilities'
  ),
  'samples',(select jsonb_object_agg(name,response) from contract_test_samples)
) as consolidated_result;

rollback;
