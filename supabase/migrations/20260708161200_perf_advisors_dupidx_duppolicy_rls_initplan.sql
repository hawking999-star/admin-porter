-- Performance advisors (2026-07-08)
-- 1) Indice duplicado: manter o que sustenta a constraint, remover o solto.
DROP INDEX IF EXISTS public.playlist_tracks_playlist_track_uniq;

-- 2) Policy redundante em units: admin_all e units_admin_all sao identicas
--    (ALL, authenticated, is_admin()). Remover a duplicata.
DROP POLICY IF EXISTS units_admin_all ON public.units;

-- 3) RLS init plan: avaliar auth.uid() uma vez por query, nao por linha.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'feedback'
      AND policyname = 'feedback_op_sel'
  ) THEN
    ALTER POLICY feedback_op_sel ON public.feedback
      USING (operator_id IN (
        SELECT operators.id FROM public.operators
        WHERE operators.auth_user_id = (select auth.uid())
      ));
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'playlists'
      AND policyname = 'playlists_op_sel'
  ) THEN
    ALTER POLICY playlists_op_sel ON public.playlists
      USING (created_by_operator_id IN (
        SELECT operators.id FROM public.operators
        WHERE operators.auth_user_id = (select auth.uid())
      ));
  END IF;
END $$;
