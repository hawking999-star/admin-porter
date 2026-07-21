begin;

create or replace function public.playlist_request_item_operator_message(
  p_status text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'review_recommended' then 'Esta música parece ser uma versão diferente e precisa de revisão.'
    when 'not_found' then 'Não foi possível localizar esta música no YouTube.'
    when 'duration_exceeded' then 'A música ultrapassa a duração máxima de 16 minutos.'
    when 'playlist_limit_exceeded' then 'A playlist ultrapassa o limite de 170 músicas.'
    when 'failed' then 'O serviço de importação está temporariamente indisponível.'
    when 'duplicate' then 'Esta música já está na playlist.'
    when 'skipped' then 'Esta música não será adicionada à playlist.'
    else null
  end
$$;

revoke all on function public.playlist_request_item_operator_message(text)
  from public, anon, authenticated;

create or replace function public.playlist_request_operator_messages(
  p_request_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_general text;
  v_source text;
  v_error_code text;
  v_review integer := 0;
  v_not_found integer := 0;
  v_duration integer := 0;
  v_limit integer := 0;
  v_messages jsonb := '[]'::jsonb;
begin
  select
    public.playlist_request_general_status(r.id),
    public.playlist_source_platform(r.source_url),
    (
      select j.error_code
        from public.download_jobs j
       where j.playlist_request_id = r.id
          or j.id = r.download_job_id
       order by j.created_at desc, j.id desc
       limit 1
    )
  into v_general, v_source, v_error_code
  from public.playlist_requests r
  where r.id = p_request_id;

  if v_general is null then return '[]'::jsonb; end if;

  select
    count(*) filter (where item_status = 'review_recommended')::integer,
    count(*) filter (where item_status = 'not_found')::integer,
    count(*) filter (where item_status = 'duration_exceeded')::integer,
    count(*) filter (where item_status = 'playlist_limit_exceeded')::integer
  into v_review, v_not_found, v_duration, v_limit
  from public.playlist_request_tracks
  where playlist_request_id = p_request_id;

  if v_general = 'partially_completed' then
    v_messages := v_messages || jsonb_build_array('A solicitação foi concluída parcialmente.');
  end if;
  if v_general = 'waiting_review' or v_review > 0 then
    v_messages := v_messages || jsonb_build_array(
      'Existem músicas que parecem versões diferentes e precisam de revisão.'
    );
  end if;

  if v_error_code = 'SPOTIFY_PLAYLIST_EMPTY' then
    v_messages := v_messages || jsonb_build_array(
      'A playlist do Spotify não possui músicas disponíveis.'
    );
  elsif v_error_code = 'PLAYLIST_EMPTY' then
    v_messages := v_messages || jsonb_build_array('A playlist não possui músicas disponíveis.');
  elsif v_error_code = 'SPOTIFY_LINK_UNAVAILABLE' then
    v_messages := v_messages || jsonb_build_array('O link do Spotify não está mais disponível.');
  elsif v_error_code = any(array[
    'SPOTIFY_RESOLVER_UNAVAILABLE', 'SPOTIFY_RESOLVE_TIMEOUT',
    'IMPORT_TIMEOUT', 'REQUEST_TIMEOUT', 'WORKER_STALE_TIMEOUT',
    'WORKER_ENV_MISSING', 'SUPABASE_PERMISSION_DENIED', 'SUPABASE_ERROR',
    'R2_ACCESS_DENIED', 'R2_ERROR', 'IMPORTER_ERROR'
  ]) then
    v_messages := v_messages || jsonb_build_array(
      'O serviço de importação está temporariamente indisponível.'
    );
  end if;

  if v_not_found > 0 or v_error_code in ('SPOTIFY_MATCH_NOT_FOUND', 'IMPORTED_WITH_UNAVAILABLE') then
    v_messages := v_messages || jsonb_build_array(
      'Não foi possível localizar algumas músicas no YouTube.'
    );
  end if;
  if v_limit > 0 then
    v_messages := v_messages || jsonb_build_array(
      'A playlist ultrapassa o limite de 170 músicas.'
    );
  end if;
  if v_duration > 0 then
    v_messages := v_messages || jsonb_build_array(
      'Uma ou mais músicas ultrapassam a duração máxima de 16 minutos.'
    );
  end if;
  if v_general = 'failed' and jsonb_array_length(v_messages) = 0 then
    v_messages := jsonb_build_array(
      case when v_source = 'spotify'
        then 'Não foi possível processar este link do Spotify.'
        else 'O serviço de importação está temporariamente indisponível.'
      end
    );
  end if;
  return v_messages;
end;
$$;

revoke all on function public.playlist_request_operator_messages(uuid)
  from public, anon, authenticated;

-- Mantém o contrato anterior e acrescenta mensagens próprias para o App.
alter function public.get_my_playlist_requests(jsonb)
  rename to get_my_playlist_requests_phase12_impl;
revoke all on function public.get_my_playlist_requests_phase12_impl(jsonb)
  from public, anon, authenticated;

create function public.get_my_playlist_requests(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_requests jsonb;
begin
  v_payload := public.get_my_playlist_requests_phase12_impl(p_request);
  if coalesce((v_payload->>'success')::boolean, false) is not true then return v_payload; end if;

  select coalesce(jsonb_agg(
    request_row || jsonb_build_object(
      'operator_messages', messages.value,
      'operator_message', messages.value->>0,
      'failure_message', case
        when request_row->>'general_status' in ('failed', 'partially_completed')
          then messages.value->>0
        else null
      end
    ) order by request_row->>'created_at' desc, request_row->>'id' desc
  ), '[]'::jsonb)
  into v_requests
  from jsonb_array_elements(coalesce(v_payload#>'{data,requests}', '[]'::jsonb)) request_row
  cross join lateral (
    select public.playlist_request_operator_messages((request_row->>'id')::uuid) as value
  ) messages;

  return jsonb_set(v_payload, '{data,requests}', v_requests, true);
end;
$$;

revoke all on function public.get_my_playlist_requests(jsonb) from public, anon;
grant execute on function public.get_my_playlist_requests(jsonb) to authenticated;

-- O Admin recebe a mensagem amigável e o diagnóstico técnico em campos distintos.
alter function public.admin_playlist_request_detail(uuid)
  rename to admin_playlist_request_detail_phase12_impl;
revoke all on function public.admin_playlist_request_detail_phase12_impl(uuid)
  from public, anon, authenticated;

create function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_request_id uuid;
  v_messages jsonb;
  v_items jsonb;
  v_technical jsonb;
begin
  v_payload := public.admin_playlist_request_detail_phase12_impl(p_playlist_id);
  if v_payload is null then return null; end if;
  v_request_id := nullif(v_payload#>>'{request,id}', '')::uuid;
  v_messages := public.playlist_request_operator_messages(v_request_id);

  select coalesce(jsonb_agg(
    item || jsonb_build_object(
      'operator_message',
      public.playlist_request_item_operator_message(item->>'status')
    ) order by coalesce((item->>'position')::integer, 0), item->>'id'
  ), '[]'::jsonb)
  into v_items
  from jsonb_array_elements(coalesce(v_payload->'items', '[]'::jsonb)) item;

  select jsonb_build_object(
    'code', j.error_code,
    'summary', j.error_details->>'technical_summary',
    'details', j.error_details
  )
  into v_technical
  from public.download_jobs j
  where j.playlist_request_id = v_request_id
     or j.id = (select r.download_job_id from public.playlist_requests r where r.id = v_request_id)
  order by j.created_at desc, j.id desc
  limit 1;

  v_payload := jsonb_set(v_payload, '{items}', v_items, true);
  v_payload := jsonb_set(v_payload, '{request,operator_messages}', v_messages, true);
  v_payload := jsonb_set(
    v_payload,
    '{request,operator_message}',
    coalesce(to_jsonb(v_messages->>0), 'null'::jsonb),
    true
  );
  v_payload := jsonb_set(v_payload, '{request,technical_error}', coalesce(v_technical, 'null'::jsonb), true);
  return v_payload;
end;
$$;

revoke all on function public.admin_playlist_request_detail(uuid) from public, anon;
grant execute on function public.admin_playlist_request_detail(uuid) to authenticated;

commit;
