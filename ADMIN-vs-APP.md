# Porter Music — Quem controla o quê (Admin × App × Supabase)

Este é o "jeito certo" de funcionar, seguindo os seus documentos (01 a 11). A regra de ouro: **o Supabase é a fonte da verdade. O Admin define regras; o App executa sob autorização.** O App nunca decide sozinho sessão, estado, desafio, bloqueio ou versão — ele pede e o backend valida.

## Resumo em uma frase

- **Admin (este painel):** cadastra, configura e comanda. Cria operadores, músicas, playlists, desafios, versões e regras. Revoga sessões e bloqueia.
- **App (Electron):** identifica-se, toca música permitida, reporta eventos e obedece ao estado oficial que o Supabase devolve.
- **Supabase:** guarda tudo, valida cada ação por RLS/RPC e é o único relógio que vale.

## Divisão por área

| Área | Quem CONTROLA (decide/grava) | Papel do App | Onde vive |
|---|---|---|---|
| Operadores, unidades, turnos, grupos | **Admin** | Só exibe o próprio perfil mínimo | `operators`, `units`, `shifts`, `operator_groups` |
| Dispositivos (aprovar/bloquear) | **Admin** | Envia fingerprint; não se auto-aprova | `devices` |
| Login / identidade | Supabase Auth + Admin (provisiona) | Apresenta credencial, guarda token | `auth.users`, `admin_users` |
| Sessão (abrir/renovar) | App **pede**, Supabase **decide** | Mantém `session_id`, manda heartbeat | `operator_sessions` |
| Sessão (revogar) | **Admin** | Recebe sinal e encerra | `operator_sessions.status` |
| Estado operacional (ativo/ocioso/em atendimento/offline) | Supabase calcula; **Admin** pode forçar | Renderiza o estado; pede transição | `operator_states` |
| Catálogo de músicas | **Admin** | Toca o que é permitido | `tracks`, `categories` |
| Playlists e ordem | **Admin** (principal); App só secundária com permissão | Consome; edita secundária se `can_edit` | `playlists`, `playlist_tracks` |
| Permissões de playlist | **Admin** | Recebe só a permissão efetiva, não a matriz | `playlist_permissions` |
| Player (play/pause/volume/posição) | **App** (local), dentro dos limites | Controla a reprodução | Estado local do Electron |
| Desafios (criar regra/resposta) | **Admin** | Exibe ocorrência sanitizada, envia resposta | `challenges`, `challenge_logs` |
| Resultado do desafio + bloqueio | **Supabase** (avalia no servidor) | Nunca decide se acertou; só mostra | `challenge_answers`, `operator_blocks` |
| Atendimento (início/fim) | App/detector **reporta**, Supabase confirma | Chama `start/finish_call_session` | `call_sessions` |
| Versões e regras de atualização | **Admin** | Reporta versão instalada e obedece | `app_versions`, `app_release_rules` |
| Configurações e tema (policy) | **Admin** | Aplica config efetiva; tema conforme policy | `system_settings`, `operator_preferences` |
| Auditoria e eventos | Supabase (append-only) | Produz eventos permitidos; não edita | `admin_audit_logs`, `operational_events` |

## O que este Admin JÁ faz hoje

Login real (Supabase Auth), dashboard com contadores e estado ao vivo dos operadores, e CRUD completo com auditoria automática em: unidades, turnos, operadores, grupos, dispositivos, sessões (revogar via status), categorias, músicas, playlists, faixas, permissões, desafios, bloqueios, versões, regras de versão, configurações e administradores. Ocorrências, atendimentos, auditoria e eventos são somente-leitura, como manda o contrato.

## O que ainda falta (próxima rodada, quando você quiser)

O que existe agora é o **modelo de dados + o Admin operando direto nas tabelas** (protegido por RLS de admin). O contrato completo pede que as **mutações críticas do App** passem por **RPCs atômicas** (não por acesso direto do Electron às tabelas). Faltam, portanto: as funções `start_operator_session`, `change_operator_status`, `submit_challenge_answer`, `record_heartbeat`, etc.; as políticas RLS específicas do papel **operador**; o Realtime; e o Storage de áudio. Nada disso trava o Admin — ele já funciona. Isso entra quando formos plugar o App Electron de fato.

---

## PROMPT PARA ALINHAR O APP ELECTRON COM O ADMIN

Cole o texto abaixo na conversa do projeto do **app Electron** (Porter Music). Ele explica ao assistente do app exatamente como se conectar a este backend sem quebrar o contrato.

```
Contexto: existe um backend Supabase e um painel Admin já prontos para o Porter Music.
O App Electron é uma casca visual (400x650) que ainda não conecta a nada. Preciso alinhá-lo ao backend.

Fonte da verdade = Supabase. O App NUNCA decide sessão, estado, desafio, bloqueio ou versão sozinho;
ele pede ao backend e obedece à resposta. Use SEMPRE o relógio do servidor (server_now), nunca o relógio local.

Dados de conexão:
- SUPABASE_URL: https://aifadvyxsefxfcgzgqol.supabase.co
- ANON KEY (pública, pode ir no bundle): eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFpZmFkdnl4c2VmeGZjZ3pncW9sIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMxNjc1NzksImV4cCI6MjA5ODc0MzU3OX0.7XNXZt4Q8G_12ajem2t242hzkP73_xJnNNEAmMD6wWk
- NUNCA embutir service_role no app.

Tabelas que já existem (fonte oficial): units, shifts, operators, operator_groups, devices,
operator_sessions, operator_states, operator_status_history, operational_events, categories, tracks,
playlists, playlist_tracks, playlist_permissions, operator_preferences, challenges, challenge_logs,
operator_blocks, call_sessions, app_versions, app_release_rules, admin_users, admin_audit_logs, system_settings.

O que o App PODE ler (após login do operador, respeitando RLS que criaremos p/ operador):
- sua própria sessão e estado (operator_sessions, operator_states)
- playlists/músicas permitidas (get_available_playlists / get_playlist_tracks)
- ocorrência de desafio própria, SEM a resposta correta
- config efetiva e decisão de versão

O que o App SÓ faz via RPC (a criar no Supabase — não escrever direto nas tabelas):
- start_operator_session / end_operator_session
- record_heartbeat
- change_operator_status (só transições permitidas, com expected_revision)
- register_operational_event
- get_pending_challenge / mark_challenge_viewed / submit_challenge_answer / resume_operator_challenge
- start_call_session / finish_call_session
- get_available_playlists / get_playlist_tracks / mutate_operator_playlist
- sync_operator_preferences / report_app_version / check_app_version_permission

Regras obrigatórias:
- Toda mutação repetível pela rede envia idempotency_key (uuid).
- Estado muda por revisão (revision), não por horário do cliente.
- Player (play/pause/volume/posição) é local, mas só toca conteúdo autorizado pelo backend.
- Se receber APP_VERSION_NOT_ALLOWED, SESSION_REVOKED ou OPERATOR_BLOCKED, parar o player e reconciliar.
- CSP: liberar connect-src e media-src apenas para o domínio do Supabase quando for integrar.

Primeira tarefa: implementar a tela de login do operador + start_operator_session + reconcile_operator_state,
e renderizar o estado oficial. Me diga quais RPCs você precisa que eu crie no Supabase primeiro.
```
