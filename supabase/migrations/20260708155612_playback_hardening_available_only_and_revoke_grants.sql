-- Playback hardening (2026-07-08)
-- 1) get_playlist_tracks passa a retornar SOMENTE faixas 'available'.
--    Faixas em 'processing' ainda nao tem objeto/URL final e nao devem
--    chegar ao App como tocaveis (causa potencial do erro de reproducao).
-- 2) Revoga grants amplos de anon/authenticated em tracks e playlist_tracks.
--    O App/Admin acessam esses dados apenas via RPCs SECURITY DEFINER;
--    ninguem deve consultar/gravar essas tabelas diretamente.

-- 1) RPC available-only ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_playlist_tracks(p_request jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_req text := p_request->>'request_id';
  v_pid uuid := nullif(p_request->>'playlist_id','')::uuid;
  v_limit int := least(greatest(coalesce(nullif(p_request->>'limit','')::int,200),1),500);
  v_offset int := greatest(coalesce(nullif(p_request->>'offset','')::int,0),0);
  v_op record; v_pl record; v_rows jsonb; v_total int;
begin
  if v_uid is null then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao ausente.'),null);
  end if;
  select * into v_op from public.operators where auth_user_id = v_uid;
  if not found then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado.'),null);
  end if;
  if v_pid is null then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','PLAYLIST_ID_REQUIRED','message','Informe playlist_id.'),null);
  end if;
  select * into v_pl from public.playlists where id = v_pid;
  if not found then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','PLAYLIST_NOT_FOUND','message','Playlist nao encontrada.'),null);
  end if;
  if v_pl.created_by_operator_id is distinct from v_op.id then
    return public._app_envelope(v_req,false,null,jsonb_build_object('code','FORBIDDEN','message','Sem permissao para esta playlist.'),null);
  end if;

  select count(*) into v_total
    from public.playlist_tracks pt
    join public.tracks t on t.id = pt.track_id
   where pt.playlist_id = v_pid and t.status = 'available';

  select coalesce(jsonb_agg(q order by q.position),'[]'::jsonb) into v_rows from (
    select pt.position,
           t.id, t.title, t.artist, t.duration_ms,
           t.storage_object_key,
           (t.metadata->>'public_url') as public_url,
           t.status, t.updated_at
    from public.playlist_tracks pt
    join public.tracks t on t.id = pt.track_id
    where pt.playlist_id = v_pid and t.status = 'available'
    order by pt.position
    limit v_limit offset v_offset
  ) q;

  return public._app_envelope(v_req, true,
    jsonb_build_object('playlist_id', v_pid, 'playlist_revision', v_pl.revision, 'tracks', v_rows),
    null,
    jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset,
                       'returned', jsonb_array_length(v_rows)));
end;
$function$;

-- 2) Revogar acesso direto as tabelas de midia --------------------------
REVOKE ALL ON TABLE public.tracks FROM anon, authenticated;
REVOKE ALL ON TABLE public.playlist_tracks FROM anon, authenticated;
