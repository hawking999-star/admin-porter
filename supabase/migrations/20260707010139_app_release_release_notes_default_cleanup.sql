alter table if exists public.app_releases
  alter column release_notes drop default;

update public.app_releases
set release_notes = null
where release_notes = '{}';
