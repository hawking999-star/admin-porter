# Porter Music — Worker de download (Railway)

Este é o "robô" que baixa as músicas. Ele fica ligado 24h no Railway, de olho na
fila do Supabase. Quando você **aprova** uma playlist do YouTube no admin, o admin
coloca um pedido na fila (`download_jobs`) e este worker faz o resto sozinho:

1. Lê a playlist do YouTube (até **170** faixas).
2. Baixa cada música em mp3, garantindo **no máximo 15 MB** por faixa.
3. Sobe cada arquivo pro **Cloudflare R2**.
4. Grava tudo nas tabelas `tracks` e `playlist_tracks` do Supabase.

Você acompanha o progresso na própria tela **Músicas** (selo "Baixando 12/170",
"170 baixadas", etc.).

---

## O que você precisa me passar (as chaves)

Me mande estes valores e eu te ajudo a colar no Railway — ou você mesmo cola em
Variables. São 6 obrigatórios:

### Supabase (1 chave secreta)
1. `SUPABASE_SERVICE_ROLE_KEY` — no painel do Supabase:
   **Project Settings → API → Project API keys → `service_role` (secret) → Reveal/Copy**.
   ⚠️ É secreta. Só vive aqui no worker, nunca no app.

(`SUPABASE_URL` já está preenchido: `https://aifadvyxsefxfcgzgqol.supabase.co`)

### Cloudflare R2 (5 valores)
2. `R2_ACCOUNT_ID` — Cloudflare → **R2** → canto direito mostra o *Account ID*.
3. `R2_BUCKET` — crie um bucket (ex.: `porter-music`) e use o nome dele.
4. `R2_ACCESS_KEY_ID` e 5. `R2_SECRET_ACCESS_KEY` — em **R2 → Manage R2 API Tokens
   → Create API Token** (permissão *Object Read & Write*). Ele mostra os dois valores
   **uma vez só** — copie na hora.
6. `R2_PUBLIC_BASE_URL` *(opcional)* — se você ligar o acesso público do bucket
   (aba **Settings → Public access / r2.dev**), cole a URL (ex.: `https://pub-xxxx.r2.dev`).
   Serve pra guardar o link tocável de cada música. Pode deixar em branco por enquanto.

---

## Como subir no Railway (passo a passo)

Você **não precisa programar nada**. Só cliques:

1. **Suba este projeto pro GitHub** (se ainda não está). A pasta `railway-worker/`
   precisa ir junto.
2. Entre em **railway.app → New Project → Deploy from GitHub repo** e escolha o repo.
3. Abra o serviço criado → **Settings → Root Directory** e coloque:
   ```
   railway-worker
   ```
   (assim o Railway usa o `Dockerfile` daqui — ele já instala ffmpeg e o yt-dlp.)
4. Vá em **Variables** e adicione as 6 chaves acima (mais `SUPABASE_URL`).
   Dá pra colar tudo de uma vez usando o **Raw Editor** e o conteúdo do
   arquivo `.env.example` como modelo.
5. Clique em **Deploy**. Acompanhe em **Deploy Logs** — deve aparecer:
   ```
   Worker iniciado. Aguardando jobs...
   ```
6. Pronto. Não precisa de domínio nem porta — é um worker de fundo.

---

## Testando

1. No admin, aprove uma playlist do **YouTube**.
2. Em segundos os logs do Railway mostram `Job ... — playlist ...` e `✓ 1/NN ...`.
3. Na tela **Músicas**, o selo muda para **Baixando** e depois **N baixadas**.

## Ajustes rápidos (opcionais)

No `Variables` do Railway dá pra mudar sem tocar em código:

| Variável | Padrão | O que faz |
|---|---|---|
| `MAX_TRACKS` | 170 | Máx. de faixas por playlist |
| `MAX_FILE_MB` | 15 | Tamanho máximo de cada mp3 |
| `AUDIO_BITRATE` | 128 | Qualidade do mp3, em kbps |
| `POLL_SECONDS` | 10 | De quanto em quanto tempo checa a fila |
| `MAX_ATTEMPTS` | 3 | Tentativas antes de marcar erro |

## Como ele respeita os limites

- **170 faixas:** só lê as primeiras 170 da playlist (`playlistend`).
- **Qualidade 128 kbps:** todo mp3 sai em 128 kbps (mude em `AUDIO_BITRATE` se quiser).
- **15 MB/faixa:** por segurança, descarta qualquer arquivo que ainda passe de 15 MB
  (a 128 kbps isso só aconteceria em faixas com mais de ~15 min).
