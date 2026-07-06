# Relatório para o dev do app — Contrato de Turno (timer regressivo)

Data: 06/07/2026 · Projeto Supabase `porter music` (`aifadvyxsefxfcgzgqol`)

## 1) Causa do "turno não aparecia" (corrigido)
- `operators.default_shift_id`: preenchido. ✅
- Turno em `shifts`: existe e ativo ("12x36 Diurno", 06:00–18:00). ✅
- `start_operator_session`: sempre retornou `data.shift` (recalcula do `default_shift_id` no login). ✅
- **Bug:** `reconcile_operator_state` lia o turno de `operator_sessions.shift_id`, **congelado no login**. Sessões abertas antes de o turno ser atribuído ficavam com `shift_id = null` → `data.shift = null` para sempre.
- **Correção:** o `reconcile` agora usa `coalesce(session.shift_id, operator.default_shift_id)`, "cola" o turno na sessão e passou a incluir `in_shift`. Backfill aplicado nas sessões ativas.

## 2) Contrato do turno (validado)
`data.shift` agora é idêntico em **`start_operator_session`** e **`reconcile_operator_state`**:

```json
"server_now": "2026-07-06T13:35:07.350Z",
"data": {
  "shift": {
    "id": "shift-uuid",
    "name": "12x36 Diurno",       // nome completo da escala (Admin)
    "display_name": "Diurno",      // rótulo curto, pronto para exibir
    "period": "day",               // "day" | "night" — enum estável
    "ends_at": "2026-07-06T21:00:00+00:00",  // timestamptz absoluto
    "in_shift": true
  }
}
```

### Campos novos (para o app não precisar interpretar texto)
- **`period`**: `"day"` | `"night"`. Enum estável. Derivado do nome (Diurno/Noturno); para escalas sem essa palavra (ex.: 6x1), é derivado do horário de início (05:00–16:59 = `day`, senão `night`).
- **`display_name`**: rótulo curto já sem o prefixo da escala (`12x36 Diurno` → `Diurno`, `12x36 Noturno` → `Noturno`, `6x1` → `Diurno`/`Noturno` conforme o horário). O Admin continua guardando/exibindo o **nome completo**; esses campos são só para apresentação no app.

> Recomendação: use `period` (lógica) e `display_name` (exibição). Não faça parse de `name`.

## 3) Respostas às perguntas da validação
1. **`server_now` + `ends_at`:** ambos presentes nas duas RPCs. Use `server_now` como relógio e `ends_at` como término. ✅
2. **`ends_at`:** é `timestamptz`, representa a **ocorrência atual** do turno, respeita o **timezone do condomínio** (`shifts.timezone`, default America/Sao_Paulo) e **atravessa a meia-noite**. Exemplo real do Noturno (18:00–06:00), consultado às 10:35 (SP): `ends_at = 2026-07-07T09:00:00+00:00` (= 06:00 do dia seguinte em SP). ✅
3. **Convenção de nomes:** os turnos 12x36 sempre contêm "Diurno" ou "Noturno". Para 6x1 o nome não traz período — por isso adicionamos `period`/`display_name`, que o app deve usar em vez do texto.
4. **Campo estável:** implementado — **ambos** `period` e `display_name` já vêm no `data.shift`.
5. **Sem turno:** se `default_shift_id` estiver vazio, `data.shift = null` (o app mostra "—"). ✅

## 4) Exemplos reais anonimizados

### `start_operator_session` → `data`
```json
{
  "unit": { "id": "unit-uuid", "code": "COND-01", "name": "Condomínio Exemplo", "active": true, "timezone": "America/Sao_Paulo" },
  "shift": { "id": "shift-uuid", "name": "12x36 Diurno", "display_name": "Diurno", "period": "day", "ends_at": "2026-07-06T21:00:00+00:00", "in_shift": true },
  "session": { "id": "session-uuid", "status": "active" }
}
```

### `reconcile_operator_state` → `data`
```json
{
  "session": { "id": "session-uuid", "status": "active", "expires_at": "2026-07-06T22:27:33+00:00" },
  "unit": { "id": "unit-uuid", "code": "COND-01", "name": "Condomínio Exemplo", "active": true, "timezone": "America/Sao_Paulo" },
  "operator": { "id": "operator-uuid", "display_name": "Operador Exemplo" },
  "operator_state": { "status": "active", "revision": 9 },
  "shift": { "id": "shift-uuid", "name": "12x36 Diurno", "display_name": "Diurno", "period": "day", "ends_at": "2026-07-06T21:00:00+00:00", "in_shift": true },
  "version": { "allowed": true, "update_policy": "optional" },
  "playback_allowed": true,
  "configuration": { "revision": 1 },
  "challenge": null, "block": null, "call": null
}
```

Nenhuma alteração no Admin, tabelas ou nomes de turno foi feita — apenas as duas RPCs e o helper `_app_shift_info` (aditivo).
