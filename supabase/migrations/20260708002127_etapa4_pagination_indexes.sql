create extension if not exists pg_trgm;
create schema if not exists private;

alter table public.feedback
  add column if not exists resolved_at timestamptz;

create index if not exists operators_display_name_trgm_idx
  on public.operators using gin (display_name gin_trgm_ops);
create index if not exists operators_username_trgm_idx
  on public.operators using gin (username gin_trgm_ops);
create index if not exists operators_role_idx
  on public.operators (role);
create index if not exists operators_active_idx
  on public.operators (active);

create index if not exists units_name_trgm_idx
  on public.units using gin (name gin_trgm_ops);
create index if not exists units_code_trgm_idx
  on public.units using gin (code gin_trgm_ops);
create index if not exists units_city_trgm_idx
  on public.units using gin (city gin_trgm_ops);
create index if not exists units_active_idx
  on public.units (active);

create index if not exists feedback_message_trgm_idx
  on public.feedback using gin (message gin_trgm_ops);
create index if not exists feedback_type_created_idx
  on public.feedback (type, created_at desc);

create index if not exists playlists_created_by_operator_idx
  on public.playlists (created_by_operator_id, created_at desc);
create index if not exists playlists_type_created_idx
  on public.playlists (type, created_at desc);
create index if not exists playlists_import_status_created_idx
  on public.playlists (import_status, created_at desc);
create index if not exists playlists_submitted_at_idx
  on public.playlists (submitted_at desc);
create index if not exists playlists_source_url_trgm_idx
  on public.playlists using gin (source_url gin_trgm_ops);
create index if not exists playlists_error_message_trgm_idx
  on public.playlists using gin (error_message gin_trgm_ops);
create index if not exists playlists_rejection_reason_trgm_idx
  on public.playlists using gin (rejection_reason gin_trgm_ops);

create or replace function public.admin_music_library_page(
  p_limit integer default 12,
  p_offset integer default 0,
  p_search text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 12), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_total bigint := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  with visible_operators as (
    select o.id
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(o.unit_id))
      and (
        v_search is null
        or o.display_name ilike '%' || v_search || '%'
        or o.username ilike '%' || v_search || '%'
        or au.email ilike '%' || v_search || '%'
        or u.name ilike '%' || v_search || '%'
        or u.city ilike '%' || v_search || '%'
        or exists (
          select 1
          from public.playlists px
          where px.created_by_operator_id = o.id
            and (px.name ilike '%' || v_search || '%' or px.source_url ilike '%' || v_search || '%')
        )
      )
  )
  select count(*) into v_total
  from visible_operators;

  with visible_operators as (
    select o.*, u.name as unit_name, u.city as unit_city, u.state as unit_state, au.email
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where (public.is_superadmin() or public.admin_can_manage_operator_unit(o.unit_id))
      and (
        v_search is null
        or o.display_name ilike '%' || v_search || '%'
        or o.username ilike '%' || v_search || '%'
        or au.email ilike '%' || v_search || '%'
        or u.name ilike '%' || v_search || '%'
        or u.city ilike '%' || v_search || '%'
        or exists (
          select 1
          from public.playlists px
          where px.created_by_operator_id = o.id
            and (px.name ilike '%' || v_search || '%' or px.source_url ilike '%' || v_search || '%')
        )
      )
    order by o.display_name
    limit v_limit
    offset v_offset
  )
  select coalesce(jsonb_agg(operator_row order by operator_row->>'display_name'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'display_name', o.display_name,
      'username', o.username,
      'email', o.email,
      'active', o.active,
      'role', o.role,
      'unit_id', o.unit_id,
      'unit_name', o.unit_name,
      'unit_city', o.unit_city,
      'unit_state', o.unit_state,
      'updated_at', o.updated_at,
      'playlists', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'name', p.name,
            'type', p.type,
            'status', p.status,
            'approval_status', p.approval_status,
            'import_status', p.import_status,
            'source_url', p.source_url,
            'platform', public.playlist_source_platform(p.source_url),
            'revision', p.revision,
            'created_at', p.created_at,
            'updated_at', p.updated_at,
            'submitted_at', p.submitted_at,
            'reviewed_at', p.reviewed_at,
            'import_started_at', p.import_started_at,
            'import_finished_at', p.import_finished_at,
            'error_code', p.error_code,
            'error_message', p.error_message,
            'last_error_at', p.last_error_at,
            'track_count', coalesce((
              select count(*)
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), 0),
            'latest_job', (
              select to_jsonb(dj) - 'error_details'
              from public.download_jobs dj
              where dj.playlist_id = p.id
              order by dj.created_at desc
              limit 1
            ),
            'tracks', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'playlist_track_id', tr.id,
                  'track_id', tr.track_id,
                  'position', tr.position,
                  'title', tr.title,
                  'artist', tr.artist,
                  'duration_ms', tr.duration_ms,
                  'source_url', tr.metadata->>'source_url',
                  'public_url', tr.metadata->>'public_url',
                  'status', tr.status,
                  'added_by_type', tr.added_by_type,
                  'created_at', tr.created_at,
                  'updated_at', tr.updated_at
                )
                order by tr.position, tr.created_at
              )
              from (
                select
                  pt.id,
                  pt.track_id,
                  pt.position,
                  pt.added_by_type,
                  pt.created_at,
                  pt.updated_at,
                  t.title,
                  t.artist,
                  t.duration_ms,
                  t.metadata,
                  t.status
                from public.playlist_tracks pt
                join public.tracks t on t.id = pt.track_id
                where pt.playlist_id = p.id
                  and t.status in ('available','processing')
                order by pt.position, pt.created_at
                limit 100
              ) tr
            ), '[]'::jsonb)
          )
          order by case p.type when 'principal' then 0 else 1 end, p.created_at
        )
        from public.playlists p
        where p.created_by_operator_id = o.id
          and p.status <> 'archived'
      ), '[]'::jsonb),
      'request_history', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', hist.id,
            'name', hist.name,
            'type', hist.type,
            'approval_status', hist.approval_status,
            'import_status', hist.import_status,
            'source_url', hist.source_url,
            'submitted_at', hist.submitted_at,
            'reviewed_at', hist.reviewed_at,
            'rejection_reason', hist.rejection_reason,
            'error_message', hist.error_message
          )
          order by coalesce(hist.submitted_at, hist.created_at) desc
        )
        from (
          select p2.*
          from public.playlists p2
          where p2.created_by_operator_id = o.id
          order by coalesce(p2.submitted_at, p2.created_at) desc
          limit 20
        ) hist
      ), '[]'::jsonb)
    ) as operator_row
    from visible_operators o
  ) q;

  return jsonb_build_object('rows', v_rows, 'total', v_total);
end
$$;

revoke all on function public.admin_music_library_page(integer, integer, text) from public, anon;
grant execute on function public.admin_music_library_page(integer, integer, text) to authenticated;
