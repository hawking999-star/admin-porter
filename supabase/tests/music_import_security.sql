begin;

do $$
declare
  v_playlist uuid := gen_random_uuid();
  v_job_one uuid := gen_random_uuid();
  v_job_two uuid := gen_random_uuid();
  v_claimed uuid;
begin
  if pg_catalog.has_function_privilege(
    'anon', 'public.worker_claim_download_job(integer)', 'execute'
  ) then
    raise exception 'anon must not execute worker_claim_download_job';
  end if;
  if pg_catalog.has_function_privilege(
    'authenticated', 'public.worker_claim_download_job(integer)', 'execute'
  ) then
    raise exception 'authenticated must not execute worker_claim_download_job';
  end if;
  if not pg_catalog.has_function_privilege(
    'service_role', 'public.worker_claim_download_job(integer)', 'execute'
  ) then
    raise exception 'service_role must execute worker_claim_download_job';
  end if;
  if pg_catalog.has_table_privilege('authenticated', 'public.playlist_requests', 'select')
     or pg_catalog.has_table_privilege('authenticated', 'public.playlist_request_tracks', 'select') then
    raise exception 'request tables must remain RPC-only';
  end if;

  insert into public.playlists (id, name, type)
  values (v_playlist, 'Security claim test', 'principal');
  insert into public.download_jobs (id, playlist_id, source_url, status)
  values
    (v_job_one, v_playlist, 'https://www.youtube.com/watch?v=hQf7MeBTR2E', 'queued'),
    (v_job_two, v_playlist, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'queued');

  select id into v_claimed from public.worker_claim_download_job(1);
  if v_claimed is null then raise exception 'first job was not claimed'; end if;

  select id into v_claimed from public.worker_claim_download_job(1);
  if v_claimed is not null then raise exception 'global concurrency limit was bypassed'; end if;

  update public.download_jobs set status = 'done' where status = 'running';
  select id into v_claimed from public.worker_claim_download_job(1);
  if v_claimed is null then raise exception 'second job was not claimed after capacity release'; end if;
end;
$$;

rollback;
