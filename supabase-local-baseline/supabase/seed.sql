-- Deterministic, fictitious fixtures for the isolated local baseline only.
-- No record in this file may be loaded into a remote Supabase project.

insert into auth.users (id)
values
  ('00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000002'),
  ('00000000-0000-4000-8000-000000000011'),
  ('00000000-0000-4000-8000-000000000012'),
  ('00000000-0000-4000-8000-000000000013')
on conflict (id) do nothing;

insert into public.units (
  id, code, name, timezone, active, address, city, state
)
values
  (
    '10000000-0000-4000-8000-000000000001',
    'LOCAL-A',
    'Condomínio Fictício Local A',
    'America/Sao_Paulo',
    true,
    'Rua de Teste, 100',
    'Cidade Exemplo',
    'SP'
  ),
  (
    '10000000-0000-4000-8000-000000000002',
    'LOCAL-B',
    'Condomínio Fictício Local B',
    'America/Sao_Paulo',
    true,
    'Avenida de Teste, 200',
    'Cidade Exemplo',
    'RJ'
  )
on conflict (id) do nothing;

insert into public.admin_users (
  id, auth_user_id, display_name, role, unit_scope, active, mfa_required
)
values
  (
    '20000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000001',
    'Superadmin Local',
    'superadmin',
    '{}'::uuid[],
    true,
    false
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '00000000-0000-4000-8000-000000000002',
    'Gestor Local',
    'operations_manager',
    array[
      '10000000-0000-4000-8000-000000000001'::uuid,
      '10000000-0000-4000-8000-000000000002'::uuid
    ],
    true,
    false
  )
on conflict (id) do nothing;

insert into public.shifts (
  id, unit_id, name, starts_at, ends_at, days_of_week, timezone, active
)
values
  (
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'Turno Local A',
    '08:00',
    '20:00',
    '{1,2,3,4,5,6,7}'::smallint[],
    'America/Sao_Paulo',
    true
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'Turno Local B',
    '08:00',
    '20:00',
    '{1,2,3,4,5,6,7}'::smallint[],
    'America/Sao_Paulo',
    true
  )
on conflict (id) do nothing;

insert into public.operators (
  id,
  auth_user_id,
  unit_id,
  employee_code,
  registered_name,
  display_name,
  default_shift_id,
  active,
  session_policy,
  role,
  username
)
values
  (
    '40000000-0000-4000-8000-000000000011',
    '00000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    'LOCAL-OP-01',
    'Operador Fictício Um',
    'Operador Local Um',
    '30000000-0000-4000-8000-000000000001',
    true,
    'single',
    'operador',
    'local_operador_01'
  ),
  (
    '40000000-0000-4000-8000-000000000012',
    '00000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000002',
    'LOCAL-OP-02',
    'Operador Fictício Dois',
    'Operador Local Dois',
    '30000000-0000-4000-8000-000000000002',
    true,
    'single',
    'operador',
    'local_operador_02'
  ),
  (
    '40000000-0000-4000-8000-000000000013',
    '00000000-0000-4000-8000-000000000013',
    '10000000-0000-4000-8000-000000000001',
    'LOCAL-SUP-01',
    'Supervisor Fictício',
    'Supervisor Local',
    '30000000-0000-4000-8000-000000000001',
    true,
    'single',
    'supervisor',
    'local_supervisor_01'
  )
on conflict (id) do nothing;

insert into public.devices (
  id, unit_id, label, fingerprint_hash, status, approved_at, metadata
)
values
  (
    '50000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    'Dispositivo Local 01',
    'local-fixture-fingerprint-01',
    'allowed',
    now(),
    '{"fixture":true}'::jsonb
  ),
  (
    '50000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000002',
    'Dispositivo Local 02',
    'local-fixture-fingerprint-02',
    'allowed',
    now(),
    '{"fixture":true}'::jsonb
  )
on conflict (id) do nothing;

insert into public.system_settings (
  id, key, scope_type, scope_id, value, schema_version, active, revision
)
values (
  '60000000-0000-4000-8000-000000000001',
  'challenge_rules',
  'global',
  null,
  '{
    "min_interval_seconds": 180,
    "max_interval_seconds": 300,
    "response_seconds": 60,
    "abandon_block_seconds": 300,
    "error_block_seconds": [300, 900, 3600],
    "active_window_start": "00:00",
    "active_window_end": "00:00",
    "timezone": "America/Sao_Paulo"
  }'::jsonb,
  1,
  true,
  1
)
on conflict (id) do nothing;
