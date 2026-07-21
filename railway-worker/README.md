# Porter Music — Worker de download (Railway)

Este é o "robô" que baixa as músicas. Ele fica ligado 24h no Railway, de olho na
fila do Supabase. Quando você **aprova** um link do YouTube ou Spotify no admin, o admin
coloca um pedido na fila (`download_jobs`) e este worker faz o resto sozinho:

1. Lê o link do YouTube ou os metadados do Spotify (até **170** faixas).
2. Para Spotify, usa o spotDL apenas para localizar a faixa correspondente no YouTube.
3. Encaminha a URL canônica resolvida para o mesmo downloader do YouTube usado por links diretos.
4. Baixa cada música do YouTube em mp3, garantindo **no máximo 15 MB** por faixa.
5. Sobe cada arquivo pro **Cloudflare R2**.
6. Grava tudo nas tabelas `tracks` e `playlist_tracks` do Supabase.
6. Processa a fila backend de exclusões R2; só remove o registro global depois
   de o banco confirmar que a faixa continua sem referências.

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
6. `R2_PUBLIC_BASE_URL` *(obrigatorio para tocar no app)* - se voce ligar o acesso publico do bucket
   (aba **Settings -> Public access / r2.dev**), cole a URL (ex.: `https://pub-xxxx.r2.dev`).
   Serve pra guardar o link tocavel de cada musica em `tracks.metadata.public_url`.

### CORS do R2 para o player

Alem do acesso publico, configure CORS no bucket R2. Sem isso, o arquivo pode abrir
via URL direta, mas o app Electron/browser pode falhar ao carregar o audio se usar
`fetch`, blob, Web Audio ou validacao de cabecalhos antes de tocar.

Configuracao recomendada do bucket:

```json
[
  {
    "AllowedOrigins": ["*"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedHeaders": ["Range", "Content-Type"],
    "ExposeHeaders": [
      "Accept-Ranges",
      "Content-Length",
      "Content-Range",
      "Content-Type"
    ],
    "MaxAgeSeconds": 86400
  }
]
```

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
| `MAX_TRACK_DURATION_SECONDS` | 960 | Duração máxima de cada faixa, em segundos |
| `MAX_FILE_MB` | 15 | Tamanho máximo de cada mp3 |
| `AUDIO_BITRATE` | 128 | Qualidade do mp3, em kbps |
| `POLL_SECONDS` | 10 | De quanto em quanto tempo checa a fila |
| `MAX_ATTEMPTS` | 3 | Tentativas do job antes de marcar erro |
| `MAX_CONCURRENT_JOBS` | 1 | Limite global de jobs ativos entre todas as réplicas |
| `TRACK_CONCURRENCY` | 2 | Faixas processadas simultaneamente dentro do mesmo job |
| `TRACK_MAX_ATTEMPTS` | 2 | Máximo de claims/tentativas por faixa |
| `STALE_JOB_SECONDS` | 1800 | Recupera jobs abandonados após 30 minutos sem progresso |
| `STALE_JOB_CHECK_SECONDS` | 60 | Intervalo da verificação de jobs abandonados |
| `GLOBAL_FAILURE_ABORT_THRESHOLD` | 3 | Encerra cedo após erros globais consecutivos do YouTube |
| `SPOTDL_RESOLVE_TIMEOUT_SECONDS` | 600 | Tempo para ler Spotify e localizar as faixas no YouTube |
| `REQUEST_TIMEOUT_SECONDS` | 3600 | Tempo máximo da solicitação inteira |
| `SPOTIFY_RESOLVER_URL` | vazio | URL de um resolver interno separado; vazio usa spotDL neste worker Docker |
| `SPOTIFY_RESOLVER_TOKEN` | vazio | Token secreto do resolver interno; obrigatório somente com a URL preenchida |
| `SPOTIFY_RESOLVER_ALLOW_PRIVATE` | false | Permite endpoint privado apenas quando explicitamente necessário |

### Segurança do importador

- somente hosts oficiais do YouTube e Spotify entram no downloader;
- toda URL é normalizada e validada novamente no backend;
- processos recebem listas de argumentos, sem `shell=True`;
- o resolver HTTP não segue redirects e limita o tamanho da resposta;
- tokens, cookies e chaves são removidos de logs e erros persistidos;
- o claim da fila é atômico, usa `SKIP LOCKED` e respeita o limite global;
- `SUPABASE_SERVICE_ROLE_KEY`, R2 e token do resolver existem somente no Worker.

## Como ele respeita os limites

- **170 faixas:** processa no máximo as primeiras 170; as demais são contabilizadas no relatório.
- **960 segundos/faixa:** descarta faixas sem duração confirmada ou acima desse teto.
- **Spotify sem áudio:** o spotDL fornece metadados e a correspondência; todo MP3 continua vindo do YouTube.
- **Um só importador:** Spotify e YouTube usam a mesma validação de duração, conversão MP3,
  deduplicação, upload R2, cadastro em `tracks` e vínculo em `playlist_tracks`.
- **Confiança não bloqueia:** uma correspondência encontrada não é rejeitada apenas por pontuação automática.
- **Revisão por sinais:** termos como `live`, `remix`, `cover`, `karaoke`, `instrumental`,
  `sped up`, `slowed`, `nightcore`, `acoustic`, `reverb` e `remastered`, ou uma diferença
  relevante de duração, marcam `review_recommended`; a faixa continua elegível para importação.

## Acompanhamento por faixa

Um álbum ou playlist continua sendo uma única solicitação. O worker registra em
`playlist_request_tracks` uma linha por faixa encontrada, com estados como
`resolved`, `processing`, `completed`, `not_found`, `duration_exceeded` e
`playlist_limit_exceeded`. Se houver mais de 170 faixas, somente as primeiras
170 entram no download; as demais ficam registradas como fora do limite e o
relatório exibido no Admin informa a quantidade excluída. Isso não falha a
solicitação inteira.
- **Qualidade 128 kbps:** todo mp3 sai em 128 kbps (mude em `AUDIO_BITRATE` se quiser).
- **15 MB/faixa:** por segurança, descarta qualquer arquivo que ainda passe de 15 MB
  (a 128 kbps isso só aconteceria em faixas com mais de ~15 min).

## Processamento assíncrono e retomada

- A aprovação apenas cria um registro em `download_jobs` e retorna; nenhuma
  requisição HTTP permanece aberta durante a importação.
- O Worker consulta a fila em segundo plano e faz claim atômico com
  `FOR UPDATE SKIP LOCKED`.
- Cada faixa também possui claim, contador de tentativas e lock próprios.
- Faixas concluídas não são apagadas quando o Worker reinicia. Um job abandonado
  volta para a fila e continua somente nos itens ainda processáveis.
- `TRACK_CONCURRENCY` controla o pequeno pool interno de downloads e
  `TRACK_MAX_ATTEMPTS` limita as tentativas individuais.

Limitação atual: a fila usa polling no Postgres, portanto a latência para começar
um job pode chegar a `POLL_SECONDS`. O desenho prioriza simplicidade e a
infraestrutura já utilizada pelo projeto; não requer Redis, RabbitMQ ou outro
serviço de filas.
