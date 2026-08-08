begin;

create or replace function public.worker_claim_youtube_probe(p_lease_seconds integer default 180)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_health private.music_provider_health%rowtype;
  v_playlist_id uuid;
begin
  select * into v_health
    from private.music_provider_health
   where provider = 'youtube'
   for update;
  if v_health.status = 'healthy'
     or v_health.next_probe_at is null
     or v_health.next_probe_at > now()
     or coalesce(v_health.probe_lease_until, '-infinity'::timestamptz) > now() then
    return pg_catalog.jsonb_build_object(
      'claimed', false,
      'status', v_health.status,
      'next_probe_at', v_health.next_probe_at
    );
  end if;

  select job.playlist_id into v_playlist_id
    from public.download_jobs job
   where job.operational_status = 'waiting_provider'
   order by job.provider_first_deferred_at nulls last, job.created_at, job.id
   limit 1;
  update private.music_provider_health
     set status = 'probing',
         probe_lease_until = now() + pg_catalog.make_interval(
           secs => least(greatest(coalesce(p_lease_seconds, 180), 30), 600)
         ),
         updated_at = now()
   where provider = 'youtube';
  return pg_catalog.jsonb_build_object(
    'claimed', true,
    'status', v_health.status,
    'next_probe_at', v_health.next_probe_at,
    'probe_playlist_id', v_playlist_id
  );
end;
$$;

revoke all on function public.worker_claim_youtube_probe(integer) from public, anon, authenticated;
grant execute on function public.worker_claim_youtube_probe(integer) to service_role;

commit;
