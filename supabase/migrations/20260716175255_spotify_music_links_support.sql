begin;

-- Fase 4: cada envio continua em playlist_requests (não criamos outra tabela de
-- solicitações). source_url permanece como o link de compatibilidade; os campos
-- abaixo preservam o link recebido, sua forma canônica e a identidade da origem.
alter table public.playlist_requests
  add column if not exists source_type text,
  add column if not exists source_resource_type text,
  add column if not exists source_resource_id text,
  add column if not exists original_url text,
  add column if not exists normalized_url text,
  add column if not exists source_metadata jsonb not null default '{}'::jsonb;

comment on column public.playlist_requests.source_type is
  'Origem canônica do link: youtube ou spotify.';
comment on column public.playlist_requests.source_resource_type is
  'Tipo canônico do recurso: video, track, album ou playlist.';
comment on column public.playlist_requests.source_resource_id is
  'ID externo canônico do recurso na plataforma de origem.';
comment on column public.playlist_requests.original_url is
  'URL enviada pelo Operador antes da normalização.';
comment on column public.playlist_requests.normalized_url is
  'URL canônica usada para aprovação e importação.';
comment on column public.playlist_requests.source_metadata is
  'Metadados adicionais da origem, quando disponíveis, sem duplicar os campos canônicos.';

-- Parser canônico do contrato de links. O App possui a mesma regra em TypeScript,
-- mas o banco continua sendo a autoridade antes de persistir qualquer solicitação.
create function public.parse_music_url(p_url text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_original text := p_url;
  v_url text := nullif(pg_catalog.btrim(p_url), '');
  v_base text;
  v_match text[];
  v_path text;
  v_resource_type text;
  v_resource_id text;
  v_playlist_id text;
begin
  if v_url is null
     or pg_catalog.length(v_url) > 2048
     or v_url !~* '^https?://'
  then
    return null;
  end if;

  -- Spotify: somente track, album e playlist no host oficial.
  v_base := pg_catalog.regexp_replace(v_url, '[?#].*$', '', 'g');
  v_match := pg_catalog.regexp_match(
    v_base,
    '^https?://open[.]spotify[.]com/(intl-[a-z]{2}/)?(track|album|playlist)/([A-Za-z0-9]{22})/?$',
    'i'
  );
  if v_match is not null then
    v_resource_type := pg_catalog.lower(v_match[2]);
    v_resource_id := v_match[3];
    return pg_catalog.jsonb_build_object(
      'source', 'spotify',
      'resourceType', v_resource_type,
      'resourceId', v_resource_id,
      'originalUrl', v_original,
      'normalizedUrl', 'https://open.spotify.com/' || v_resource_type || '/' || v_resource_id
    );
  end if;

  -- YouTube curto. Se houver list=, preserva o comportamento atual e trata como playlist.
  v_match := pg_catalog.regexp_match(
    v_url,
    '^https?://youtu[.]be/([A-Za-z0-9_-]{11})/?([?#].*)?$',
    'i'
  );
  if v_match is not null then
    if v_url ~* '[?&]list=' then
      v_playlist_id := (pg_catalog.regexp_match(
        v_url,
        '[?&]list=([A-Za-z0-9_-]+)(&|#|$)',
        'i'
      ))[1];
      if v_playlist_id is null
         or pg_catalog.upper(pg_catalog.left(v_playlist_id, 2)) = any (array['RD', 'UL', 'LL', 'WL'])
      then
        return null;
      end if;
      return pg_catalog.jsonb_build_object(
        'source', 'youtube',
        'resourceType', 'playlist',
        'resourceId', v_playlist_id,
        'originalUrl', v_original,
        'normalizedUrl', 'https://www.youtube.com/playlist?list=' || v_playlist_id
      );
    end if;

    v_resource_id := v_match[1];
    return pg_catalog.jsonb_build_object(
      'source', 'youtube',
      'resourceType', 'video',
      'resourceId', v_resource_id,
      'originalUrl', v_original,
      'normalizedUrl', 'https://www.youtube.com/watch?v=' || v_resource_id
    );
  end if;

  -- YouTube, www.youtube.com e music.youtube.com. Outros subdomínios são rejeitados.
  v_match := pg_catalog.regexp_match(
    v_url,
    '^https?://(www[.]|music[.])?youtube[.]com(/[^?#]*)?([?#].*)?$',
    'i'
  );
  if v_match is null then
    return null;
  end if;
  v_path := coalesce(v_match[2], '/');

  if v_url ~* '[?&]list=' then
    v_playlist_id := (pg_catalog.regexp_match(
      v_url,
      '[?&]list=([A-Za-z0-9_-]+)(&|#|$)',
      'i'
    ))[1];
    if v_playlist_id is null
       or pg_catalog.upper(pg_catalog.left(v_playlist_id, 2)) = any (array['RD', 'UL', 'LL', 'WL'])
    then
      return null;
    end if;
  end if;

  if v_path = '/playlist' then
    if v_playlist_id is null then
      return null;
    end if;
    return pg_catalog.jsonb_build_object(
      'source', 'youtube',
      'resourceType', 'playlist',
      'resourceId', v_playlist_id,
      'originalUrl', v_original,
      'normalizedUrl', 'https://www.youtube.com/playlist?list=' || v_playlist_id
    );
  end if;

  if v_path = '/watch' then
    if v_playlist_id is not null then
      return pg_catalog.jsonb_build_object(
        'source', 'youtube',
        'resourceType', 'playlist',
        'resourceId', v_playlist_id,
        'originalUrl', v_original,
        'normalizedUrl', 'https://www.youtube.com/playlist?list=' || v_playlist_id
      );
    end if;

    if v_url !~* '[?&]v=' then
      return null;
    end if;
    v_resource_id := (pg_catalog.regexp_match(
      v_url,
      '[?&]v=([A-Za-z0-9_-]{11})(&|#|$)',
      'i'
    ))[1];
    if v_resource_id is null then
      return null;
    end if;
    return pg_catalog.jsonb_build_object(
      'source', 'youtube',
      'resourceType', 'video',
      'resourceId', v_resource_id,
      'originalUrl', v_original,
      'normalizedUrl', 'https://www.youtube.com/watch?v=' || v_resource_id
    );
  end if;

  return null;
end;
$$;

-- Função pura, sem leitura de tabelas ou dados privados. Mantemos EXECUTE público
-- para preservar chamadas indiretas de playlist_source_platform (SECURITY INVOKER).

create or replace function public.playlist_source_platform(p_url text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_url is null or pg_catalog.btrim(p_url) = '' then 'none'
    when public.parse_music_url(p_url) is not null then public.parse_music_url(p_url)->>'source'
    when p_url ~* '^https?://' then 'unsupported'
    else 'invalid'
  end
$$;

create or replace function public.playlist_import_error_message(
  p_error_code text,
  p_raw_message text default null
)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_error_code
    when 'INVALID_URL' then 'Link inválido ou plataforma não suportada.'
    when 'UNSUPPORTED_PLATFORM' then 'Plataforma não suportada pelo importador.'
    when 'PLAYLIST_PRIVATE_OR_UNAVAILABLE' then 'Playlist privada ou indisponível.'
    when 'PLAYLIST_EMPTY' then 'Playlist vazia ou sem músicas disponíveis.'
    when 'YOUTUBE_ERROR' then 'Falha no YouTube ao ler ou baixar a playlist.'
    when 'YOUTUBE_COOKIES_MISSING' then 'Falha ao importar: YouTube exigiu autenticação e a variável YOUTUBE_COOKIES não está configurada.'
    when 'YOUTUBE_FORMAT_UNAVAILABLE' then 'Falha no YouTube: nenhum formato de áudio disponível para download no ambiente do importador.'
    when 'SPOTIFY_METADATA_ERROR' then 'Falha ao ler os metadados do Spotify.'
    when 'SPOTIFY_RESOLVE_TIMEOUT' then 'Falha ao localizar as músicas do Spotify no YouTube: tempo limite excedido.'
    when 'SPOTIFY_MATCH_NOT_FOUND' then 'Não foi possível localizar uma correspondência desta música no YouTube.'
    when 'R2_ACCESS_DENIED' then 'Falha ao salvar no R2: acesso negado.'
    when 'R2_ERROR' then 'Falha ao salvar no R2.'
    when 'SUPABASE_PERMISSION_DENIED' then 'Falha no Supabase: permissão negada.'
    when 'SUPABASE_ERROR' then 'Falha no Supabase ao gravar a importação.'
    when 'IMPORT_TIMEOUT' then 'Falha no importador: tempo limite excedido.'
    when 'WORKER_ENV_MISSING' then 'Falha no importador: variável de ambiente obrigatória ausente.'
    when 'NO_TRACKS_DOWNLOADED' then 'Nenhuma música foi baixada da playlist.'
    else coalesce(nullif(p_raw_message, ''), 'Falha ao importar playlist.')
  end
$$;

-- O núcleo legado possui todas as regras de autorização, concorrência, limites e
-- idempotência. Mantemos esse núcleo e adicionamos um adaptador somente para:
-- 1) receber a URL normalizada; 2) permitir vídeo único do YouTube.
alter function public.manage_operator_playlist_impl(jsonb)
  rename to manage_operator_playlist_core_impl;
revoke all on function public.manage_operator_playlist_core_impl(jsonb)
  from public, anon, authenticated;

create function public.manage_operator_playlist_impl(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parsed jsonb;
  v_normalized_request jsonb := p_request;
  v_core_request jsonb;
  v_response jsonb;
  v_playlist_id uuid;
  v_normalized_url text;
  v_placeholder_url text;
begin
  if pg_catalog.lower(coalesce(p_request->>'operation', '')) <> 'submit' then
    return public.manage_operator_playlist_core_impl(p_request);
  end if;

  v_parsed := public.parse_music_url(p_request->>'url');
  if v_parsed is null then
    return public.manage_operator_playlist_core_impl(p_request);
  end if;

  v_normalized_url := v_parsed->>'normalizedUrl';
  v_normalized_request := pg_catalog.jsonb_set(
    p_request,
    '{url}',
    pg_catalog.to_jsonb(v_normalized_url),
    true
  );
  v_core_request := v_normalized_request;

  -- O núcleo antigo rejeita vídeo único por ausência de list=. O placeholder
  -- existe apenas dentro da transação e é substituído antes de qualquer commit.
  if v_parsed->>'source' = 'youtube'
     and v_parsed->>'resourceType' = 'video'
  then
    v_placeholder_url := 'https://porter-music.invalid/youtube-video/' || (v_parsed->>'resourceId');
    v_core_request := pg_catalog.jsonb_set(
      v_normalized_request,
      '{url}',
      pg_catalog.to_jsonb(v_placeholder_url),
      true
    );
  end if;

  v_response := public.manage_operator_playlist_core_impl(v_core_request);

  if coalesce((v_response->>'success')::boolean, false)
     and v_placeholder_url is not null
  then
    v_playlist_id := private.try_uuid(v_response#>>'{data,playlist_id}');
    if v_playlist_id is not null then
      update public.playlists
         set source_url = v_normalized_url
       where id = v_playlist_id
         and source_url = v_placeholder_url;
    end if;
  end if;

  return v_response;
end;
$$;

revoke all on function public.manage_operator_playlist_impl(jsonb)
  from public, anon, authenticated;

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
  v_original_url text := nullif(p_request->>'url', '');
  v_raw_url text := nullif(pg_catalog.btrim(p_request->>'url'), '');
  v_parsed jsonb := public.parse_music_url(v_raw_url);
  v_url text := v_parsed->>'normalizedUrl';
  v_normalized_request jsonb := p_request;
  v_key uuid := private.try_uuid(nullif(p_request->>'idempotency_key', ''));
  v_request_id_raw text := nullif(p_request->>'request_id', '');
  v_request_id uuid := private.try_uuid(v_request_id_raw);
  v_request_id_text text := coalesce(v_request_id::text, gen_random_uuid()::text);
  v_existing_source_url text;
begin
  if v_parsed is not null then
    v_normalized_request := pg_catalog.jsonb_set(
      p_request,
      '{url}',
      pg_catalog.to_jsonb(v_url),
      true
    );
  end if;

  if pg_catalog.lower(coalesce(p_request->>'operation', '')) = 'submit'
     and v_uid is not null
     and v_key is not null
     and v_raw_url is not null
     and v_type in ('principal', 'secondary')
     and (v_request_id_raw is null or v_request_id is not null)
  then
    select operator_row.id
      into v_operator_id
      from public.operators as operator_row
     where operator_row.auth_user_id = v_uid
       and operator_row.active is true;

    if v_operator_id is not null then
      if v_parsed is null then
        return public._app_envelope(
          v_request_id_text,
          false,
          null,
          pg_catalog.jsonb_build_object(
            'code', 'INVALID_URL',
            'supported_sources', pg_catalog.jsonb_build_array('youtube', 'spotify')
          ),
          null
        );
      end if;

      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('operator-playlists:' || v_operator_id::text)
      );

      select request_row.source_url
        into v_existing_source_url
        from public.playlist_requests as request_row
       where request_row.operator_id = v_operator_id
         and request_row.idempotency_key = v_key;

      if found then
        -- Compatibilidade com solicitações anteriores à normalização.
        if v_existing_source_url = v_url then
          return public.manage_operator_playlist_impl(v_normalized_request);
        end if;
        return public.manage_operator_playlist_core_impl(p_request);
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

  v_response := public.manage_operator_playlist_impl(v_normalized_request);

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
    source_type,
    source_resource_type,
    source_resource_id,
    original_url,
    normalized_url,
    source_metadata,
    status,
    request_id,
    idempotency_key
  ) values (
    v_operator_id,
    v_playlist_id,
    v_url,
    v_parsed->>'source',
    v_parsed->>'resourceType',
    v_parsed->>'resourceId',
    v_original_url,
    v_url,
    '{}'::jsonb,
    'pending',
    v_request_id,
    v_key
  );

  return v_response;
end;
$$;

revoke all on function public.manage_operator_playlist(jsonb) from public, anon;
grant execute on function public.manage_operator_playlist(jsonb) to authenticated;

-- Aprovação passa a enfileirar YouTube e Spotify no mesmo download_jobs.
create or replace function public.admin_review_playlist_impl(
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
  v_pl record;
  v_admin uuid;
  v_platform text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_pl from public.playlists where id = p_playlist;
  if not found then raise exception 'playlist_not_found'; end if;

  if v_pl.approval_status in ('approved', 'rejected') then
    raise exception 'already_reviewed';
  end if;

  if v_pl.unit_id is not null and not public.admin_can_manage_operator_unit(v_pl.unit_id) then
    if not public.is_superadmin() then raise exception 'forbidden'; end if;
  end if;
  select id into v_admin from public.admin_users where auth_user_id = auth.uid();

  if p_action = 'approve' then
    v_platform := public.playlist_source_platform(v_pl.source_url);
    if v_platform not in ('youtube', 'spotify') then
      raise exception 'unsupported_platform';
    end if;

    update public.playlists
       set approval_status = 'approved',
           status = 'active',
           reviewed_at = pg_catalog.now(),
           reviewed_by = v_admin,
           rejection_reason = null,
           updated_at = pg_catalog.now(),
           revision = revision + 1
     where id = p_playlist;

    if not exists (
      select 1
        from public.download_jobs
       where playlist_id = p_playlist
         and status in ('queued', 'running')
    ) then
      insert into public.download_jobs (playlist_id, source_url, status)
      values (p_playlist, v_pl.source_url, 'queued');
    end if;

  elsif p_action = 'reject' then
    update public.playlists
       set approval_status = 'rejected',
           status = 'inactive',
           reviewed_at = pg_catalog.now(),
           reviewed_by = v_admin,
           rejection_reason = nullif(pg_catalog.btrim(p_reason), ''),
           updated_at = pg_catalog.now(),
           revision = revision + 1
     where id = p_playlist;
  else
    raise exception 'invalid_action';
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'approval_status', case when p_action = 'approve' then 'approved' else 'rejected' end
  );
end;
$$;

revoke all on function public.admin_review_playlist_impl(uuid, text, text)
  from public, anon, authenticated;

create or replace function public.sync_playlist_review_import_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid;
  v_platform text;
begin
  if new.approval_status is distinct from old.approval_status then
    select id into v_admin_id
      from public.admin_users
     where auth_user_id = auth.uid()
     limit 1;

    if new.approval_status in ('approved', 'rejected') then
      new.reviewed_by_admin_id := coalesce(new.reviewed_by_admin_id, v_admin_id);
      new.reviewed_at := coalesce(new.reviewed_at, pg_catalog.now());
    end if;

    if new.approval_status = 'rejected' then
      new.import_status := 'not_started';
      new.import_started_at := null;
      new.import_finished_at := null;
      new.error_code := null;
      new.error_message := null;
      new.error_details := null;
      new.last_error_at := null;
    elsif new.approval_status = 'approved' then
      v_platform := public.playlist_source_platform(new.source_url);

      if v_platform in ('youtube', 'spotify') then
        new.import_status := 'not_started';
        new.error_code := null;
        new.error_message := null;
        new.error_details := null;
        new.last_error_at := null;
      else
        new.import_status := 'failed';
        new.error_code := case when v_platform = 'invalid' then 'INVALID_URL' else 'UNSUPPORTED_PLATFORM' end;
        new.error_message := public.playlist_import_error_message(new.error_code, null);
        new.error_details := pg_catalog.jsonb_build_object(
          'platform', v_platform,
          'source_url', new.source_url
        );
        new.last_error_at := pg_catalog.now();
      end if;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.sync_playlist_review_import_defaults()
  from public, anon, authenticated;

create or replace function public.admin_retry_playlist_import(p_playlist uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_platform text;
begin
  select * into v_admin
    from public.admin_users
   where auth_user_id = auth.uid()
     and active = true
   limit 1;

  if v_admin.id is null then raise exception 'forbidden'; end if;

  select * into v_playlist
    from public.playlists
   where id = p_playlist
   for update;

  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if v_playlist.approval_status <> 'approved' then raise exception 'playlist_not_approved'; end if;

  v_platform := public.playlist_source_platform(v_playlist.source_url);
  if v_platform not in ('youtube', 'spotify') then
    update public.playlists
       set import_status = 'failed',
           error_code = 'UNSUPPORTED_PLATFORM',
           error_message = public.playlist_import_error_message('UNSUPPORTED_PLATFORM', null),
           error_details = pg_catalog.jsonb_build_object(
             'platform', v_platform,
             'source_url', v_playlist.source_url
           ),
           last_error_at = pg_catalog.now()
     where id = p_playlist;
    return;
  end if;

  if exists (
    select 1
      from public.download_jobs
     where playlist_id = p_playlist
       and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
     set import_status = 'processing',
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         import_started_at = pg_catalog.now(),
         import_finished_at = null
   where id = p_playlist;

  insert into public.download_jobs (
    playlist_id, source_url, status, attempts, created_at, updated_at
  ) values (
    p_playlist, v_playlist.source_url, 'queued', 0, pg_catalog.now(), pg_catalog.now()
  );
end;
$$;

revoke all on function public.admin_retry_playlist_import(uuid) from public, anon;
grant execute on function public.admin_retry_playlist_import(uuid) to authenticated;

create or replace function public.admin_reimport_playlist_request(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_job_id uuid;
begin
  select * into v_admin
    from public.admin_users
   where auth_user_id = auth.uid()
     and active is true
   limit 1;

  if v_admin.id is null then raise exception 'forbidden'; end if;

  select * into v_request
    from public.playlist_requests
   where id = p_request
   for update;

  if v_request.id is null then raise exception 'playlist_request_not_found'; end if;

  select * into v_playlist
    from public.playlists
   where id = v_request.playlist_id
   for update;

  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id)
  then
    raise exception 'forbidden';
  end if;
  if v_request.status <> 'approved' then raise exception 'playlist_request_not_approved'; end if;
  if public.playlist_source_platform(v_request.source_url) not in ('youtube', 'spotify') then
    raise exception 'unsupported_platform';
  end if;

  if exists (
    select 1
      from public.download_jobs
     where playlist_id = v_playlist.id
       and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
     set source_url = v_request.source_url,
         approval_status = 'approved',
         import_status = 'processing',
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         import_started_at = pg_catalog.now(),
         import_finished_at = null,
         updated_at = pg_catalog.now(),
         revision = revision + 1
   where id = v_playlist.id;

  insert into public.download_jobs (
    playlist_id,
    playlist_request_id,
    source_url,
    status,
    attempts,
    mode,
    created_at,
    updated_at
  ) values (
    v_playlist.id,
    v_request.id,
    v_request.source_url,
    'queued',
    0,
    'playlist',
    pg_catalog.now(),
    pg_catalog.now()
  ) returning id into v_job_id;

  insert into public.admin_audit_logs (
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    occurred_at
  ) values (
    v_admin.id,
    'playlist_request_reimported',
    'playlist_requests',
    v_request.id,
    pg_catalog.to_jsonb(v_playlist),
    pg_catalog.jsonb_build_object(
      'playlist_id', v_playlist.id,
      'playlist_request_id', v_request.id,
      'source_url', v_request.source_url,
      'download_job_id', v_job_id
    ),
    pg_catalog.now()
  );
end;
$$;

revoke all on function public.admin_reimport_playlist_request(uuid) from public, anon;
grant execute on function public.admin_reimport_playlist_request(uuid) to authenticated;

commit;
