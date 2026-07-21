begin;

do $$
declare
  v_parsed jsonb;
begin
  v_parsed := public.parse_music_url(
    'https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA?si=teste'
  );
  if v_parsed#>>'{source}' <> 'spotify'
     or v_parsed#>>'{resourceType}' <> 'playlist'
     or v_parsed#>>'{normalizedUrl}' <> 'https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA'
  then
    raise exception 'spotify_playlist_parse_failed: %', v_parsed;
  end if;

  v_parsed := public.parse_music_url('https://youtu.be/hQf7MeBTR2E?si=teste');
  if v_parsed#>>'{resourceType}' <> 'video'
     or v_parsed#>>'{normalizedUrl}' <> 'https://www.youtube.com/watch?v=hQf7MeBTR2E'
  then
    raise exception 'youtube_video_parse_failed: %', v_parsed;
  end if;

  if public.parse_music_url('https://open.spotify.com/episode/3QaPy1KgI7nu9FJEQUgn6h') is not null
     or public.parse_music_url('https://open.spotify.com/artist/3QaPy1KgI7nu9FJEQUgn6h') is not null
     or public.parse_music_url('https://evil.example/spotify/track/3QaPy1KgI7nu9FJEQUgn6h') is not null
     or public.parse_music_url('spotify') is not null
     or public.parse_music_url('https://www.youtube.com/playlist?list=RD1234567890') is not null
  then
    raise exception 'unsupported_url_was_accepted';
  end if;

  if public.playlist_source_platform(
       'https://open.spotify.com/track/3QaPy1KgI7nu9FJEQUgn6h'
     ) <> 'spotify'
     or public.playlist_source_platform(
       'https://www.youtube.com/watch?v=hQf7MeBTR2E'
     ) <> 'youtube'
  then
    raise exception 'playlist_source_platform_failed';
  end if;

  if pg_catalog.strpos(
       pg_catalog.lower(
         pg_catalog.pg_get_functiondef(
           'public.admin_review_playlist_impl(uuid,text,text)'::pg_catalog.regprocedure
         )
       ),
       'spotify'
     ) = 0
  then
    raise exception 'admin_review_does_not_enqueue_spotify';
  end if;
end;
$$;

rollback;
