-- Shared, immutable administrative notes for playlists.
--
-- Visibility follows the existing Admin panel contract: active admins can read
-- notes, while only operational/content roles can create a new version. The
-- author is always resolved from auth.uid() inside the database.

create table public.playlist_admin_notes (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  version integer not null,
  content text not null,
  created_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint playlist_admin_notes_version_positive check (version > 0),
  constraint playlist_admin_notes_content_length check (char_length(content) <= 5000),
  constraint playlist_admin_notes_playlist_version_key unique (playlist_id, version)
);

create index playlist_admin_notes_playlist_created_idx
  on public.playlist_admin_notes (playlist_id, created_at desc, id desc);

alter table public.playlist_admin_notes enable row level security;

revoke all on table public.playlist_admin_notes from public, anon, authenticated;
grant select on table public.playlist_admin_notes to authenticated;
grant select, insert, update, delete on table public.playlist_admin_notes to service_role;

create policy playlist_admin_notes_admin_read
on public.playlist_admin_notes
for select
to authenticated
using (public.is_admin());

create or replace function public.admin_list_playlist_notes(
  p_playlist uuid,
  p_limit integer default 20
)
returns table (
  id uuid,
  playlist_id uuid,
  version integer,
  content text,
  created_by_admin_id uuid,
  created_by_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_playlist public.playlists%rowtype;
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
begin
  perform private.require_admin_for_backend(null, null);

  select * into v_playlist
  from public.playlists
  where public.playlists.id = p_playlist;

  if v_playlist.id is null then
    raise exception using errcode = 'P0002', message = 'PLAYLIST_NOT_FOUND';
  end if;

  return query
  select
    note.id,
    note.playlist_id,
    note.version,
    note.content,
    note.created_by_admin_id,
    admin_user.display_name,
    note.created_at
  from public.playlist_admin_notes note
  left join public.admin_users admin_user on admin_user.id = note.created_by_admin_id
  where note.playlist_id = p_playlist
  order by note.version desc
  limit v_limit;
end;
$$;

create or replace function public.admin_save_playlist_note(
  p_playlist uuid,
  p_content text
)
returns table (
  id uuid,
  playlist_id uuid,
  version integer,
  content text,
  created_by_admin_id uuid,
  created_by_name text,
  created_at timestamptz,
  created boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_previous public.playlist_admin_notes%rowtype;
  v_saved public.playlist_admin_notes%rowtype;
  v_content text := btrim(coalesce(p_content, ''));
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  select * into v_playlist
  from public.playlists
  where public.playlists.id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception using errcode = 'P0002', message = 'PLAYLIST_NOT_FOUND';
  end if;

  if v_playlist.unit_id is not null
     and v_admin.role in ('unit_manager', 'operations_manager')
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception using errcode = '42501', message = 'PLAYLIST_NOTE_OUTSIDE_UNIT_SCOPE';
  end if;

  if char_length(v_content) > 5000 then
    raise exception using errcode = '22001', message = 'PLAYLIST_NOTE_TOO_LONG';
  end if;

  select * into v_previous
  from public.playlist_admin_notes note
  where note.playlist_id = p_playlist
  order by note.version desc
  limit 1;

  if v_previous.id is not null and v_previous.content = v_content then
    return query
    select
      v_previous.id,
      v_previous.playlist_id,
      v_previous.version,
      v_previous.content,
      v_previous.created_by_admin_id,
      previous_admin.display_name,
      v_previous.created_at,
      false
    from public.admin_users previous_admin
    where previous_admin.id = v_previous.created_by_admin_id;
    return;
  end if;

  insert into public.playlist_admin_notes (
    playlist_id,
    version,
    content,
    created_by_admin_id,
    created_at
  ) values (
    p_playlist,
    coalesce(v_previous.version, 0) + 1,
    v_content,
    v_admin.id,
    clock_timestamp()
  )
  returning * into v_saved;

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
    case when v_content = '' then 'playlist_admin_note_cleared' else 'playlist_admin_note_saved' end,
    'playlist',
    p_playlist,
    case when v_previous.id is null then null else jsonb_build_object(
      'note_id', v_previous.id,
      'version', v_previous.version,
      'cleared', v_previous.content = ''
    ) end,
    jsonb_build_object(
      'note_id', v_saved.id,
      'version', v_saved.version,
      'cleared', v_saved.content = ''
    ),
    v_saved.created_at
  );

  return query
  select
    v_saved.id,
    v_saved.playlist_id,
    v_saved.version,
    v_saved.content,
    v_saved.created_by_admin_id,
    v_admin.display_name,
    v_saved.created_at,
    true;
end;
$$;

revoke all on function public.admin_list_playlist_notes(uuid, integer) from public, anon;
grant execute on function public.admin_list_playlist_notes(uuid, integer) to authenticated;

revoke all on function public.admin_save_playlist_note(uuid, text) from public, anon;
grant execute on function public.admin_save_playlist_note(uuid, text) to authenticated;
