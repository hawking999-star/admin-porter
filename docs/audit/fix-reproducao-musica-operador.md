# Correção — "Não é possível reproduzir a música" (App do Operador)

Data: 2026-07-08
Projeto Supabase: `porter music` (`aifadvyxsefxfcgzgqol`)
Escopo desta auditoria: backend Supabase + Storage R2 (verificados no remoto, **somente leitura**) e contrato do player.

> **Importante:** o código do **App do Operador (Electron) não está neste workspace.** Este repositório é o **PTM Admin** + migrations + worker Railway. Nada foi alterado no Supabase remoto, no Admin ou no App. Abaixo está a causa raiz comprovada no backend e o player de referência para o dev do App aplicar no repositório dele.

---

## 1. Causa raiz

**O backend, o dado, o Storage R2 e o formato estão 100% corretos.** A falha está na **camada de player do App**, por um destes dois motivos (ambos produzem exatamente a mensagem "não é possível reproduzir"):

1. **Campo errado** — o App usa como `src` do áudio um campo que **não existe** no contrato (`file_url`, `url`, `audio_url`) ou usa `storage_object_key` (chave interna do R2, ex. `tracks/oQk5HwZeTdU.mp3`, **não é URL**). Resultado: `<audio src="tracks/xxx.mp3">` → `MediaError` / `NotSupportedError`. **O campo tocável correto é `public_url`.**
2. **Caminho de query errado (RLS)** — o App lê `tracks` / `playlist_tracks` **direto** (`supabase.from('tracks').select()`). Essas tabelas **não têm policy de operador** (só `admin_all` / `is_admin()`), então o RLS devolve **lista vazia sem erro**. Sem faixas → nada toca. **O App deve usar a RPC `get_playlist_tracks`.**

Um terceiro fator só afeta quem usa Web Audio API / `crossorigin` (ver seção 5): **CORS**.

### Evidências (produção, verificadas em 2026-07-08)

| Verificação | Resultado |
|---|---|
| Total de faixas | 3, todas `status='available'` |
| `metadata.public_url` preenchido | **3/3** (não é o caso "public_url null") |
| `mime_type` | `audio/mpeg` nas 3 |
| HTTP na `public_url` | **206 Partial Content**, `Content-Type: audio/mpeg`, `Accept-Ranges: bytes`, tamanho real ~1,6 MB |
| Vínculo playlist→faixa | 3 faixas na principal **"Kadu"** do operador `karlos.belisario` (`playlist_id 3dff5e1b-8539-4f4a-9001-aeb152748694`) |
| RLS `tracks` / `playlist_tracks` | só `admin_all` → operador **não lê direto**; só via RPC |
| RPC `get_playlist_tracks` | retorna `tracks[]` com `public_url`, ordenado por `position` |
| 404 de chave inexistente | retorna `text/html` (se o App montar chave errada → HTML, não áudio) |

Classificação do problema: **URL/campo no App** (principal) e/ou **caminho de query bloqueado por RLS**. **Não é** problema de Storage/R2, formato, ou autoplay de origem, e **não é** RLS mal configurado no backend (está correto: leitura só via RPC por design).

---

## 2. Contrato correto que o App deve seguir

1. Login → `resolve-login-email` + `signInWithPassword` (JWT `authenticated`).
2. `get_my_playlists({ request_id })` → localizar `type='principal'` → pegar `playlist.id`.
3. `get_playlist_tracks({ request_id, playlist_id, limit, offset })` → `data.tracks[]`.
4. Para cada faixa, tocar **`track.public_url`**. Nunca `storage_object_key`, nunca leitura direta de `tracks`.

Formato de cada faixa retornada pela RPC:

```json
{
  "position": 1,
  "id": "fcc8f9e3-…",
  "title": "FESTA DO PENTE RALA (FMNZS)",
  "artist": "…",
  "duration_ms": 210000,
  "storage_object_key": "tracks/oQk5HwZeTdU.mp3",
  "public_url": "https://pub-cb01…r2.dev/tracks/oQk5HwZeTdU.mp3",
  "status": "available",
  "updated_at": "2026-07-…Z"
}
```

---

## 3. Player de referência (drop-in no App do Operador)

Usa tag `<audio>` simples (não exige CORS), lê `public_url`, loga o motivo técnico real, mostra mensagem amigável, pula faixa inválida e **nunca** derruba login/playlist. Sem `service_role`.

```js
// player.js — App do Operador (Electron renderer)
// Requer: um <audio id="ptm-audio"> no DOM e o client supabase autenticado.

const audio = document.getElementById('ptm-audio');

const FRIENDLY_MSG =
  'Não foi possível reproduzir esta música. O arquivo pode estar indisponível ou sem permissão de acesso.';

// 1) Resolve o campo tocável de forma defensiva. O contrato é public_url;
//    os fallbacks só existem para diagnosticar dados antigos, nunca storage_object_key.
function resolveTrackUrl(track) {
  const url = track?.public_url ?? track?.metadata?.public_url ?? null;
  if (typeof url === 'string' && /^https?:\/\//i.test(url)) return url;
  return null; // null => faixa indisponível (não tentar tocar storage_object_key)
}

// 2) Carrega faixas SEMPRE pela RPC (RLS bloqueia leitura direta de tracks/playlist_tracks).
async function loadTracks(supabase, playlistId) {
  const { data, error } = await supabase.rpc('get_playlist_tracks', {
    p_request: { request_id: crypto.randomUUID(), playlist_id: playlistId, limit: 200, offset: 0 },
  });
  if (error) {
    console.error('[PTM][tracks] RPC get_playlist_tracks falhou:', { playlistId, error });
    return [];
  }
  if (!data?.success) {
    console.error('[PTM][tracks] RPC retornou erro de contrato:', { playlistId, error: data?.error });
    return [];
  }
  return data.data?.tracks ?? [];
}

// 3) Toca uma faixa. Retorna true/false; NUNCA lança (não quebra o resto do player).
async function playTrack(track, { onError } = {}) {
  const url = resolveTrackUrl(track);
  const ctx = {
    id: track?.id,
    title: track?.title,
    playlist_id: track?.playlist_id ?? null,
    url_field: url ? 'public_url' : '(ausente)',
    url,
  };

  if (!url) {
    console.error('[PTM][play] faixa sem URL tocável (public_url ausente/null):', ctx);
    onError?.(FRIENDLY_MSG, ctx);
    return false;
  }

  // Diagnóstico de rede opcional (HEAD/range) para diferenciar 401/403/404 de erro de player.
  try {
    const head = await fetch(url, { method: 'GET', headers: { Range: 'bytes=0-1' } });
    ctx.http_status = head.status; // 200/206 esperado
    if (head.status >= 400) {
      console.error('[PTM][play] URL retornou HTTP de erro:', ctx);
      onError?.(FRIENDLY_MSG, ctx);
      return false;
    }
  } catch (netErr) {
    // Em Electron pode dar CORS no fetch mesmo com a tag <audio> funcionando.
    // Não bloqueia: apenas registra e segue para a tag <audio>.
    console.warn('[PTM][play] checagem de rede falhou (seguindo para <audio>):', { ...ctx, netErr: String(netErr) });
  }

  return new Promise((resolve) => {
    const onErr = () => {
      const mediaErr = audio.error; // MediaError: 1 ABORTED,2 NETWORK,3 DECODE,4 SRC_NOT_SUPPORTED
      console.error('[PTM][play] falha no HTMLAudioElement:', {
        ...ctx,
        media_error_code: mediaErr?.code,
        media_error_message: mediaErr?.message,
        error_type: mediaErr?.code === 4 ? 'NotSupportedError/SRC_NOT_SUPPORTED'
                  : mediaErr?.code === 2 ? 'NetworkError'
                  : mediaErr?.code === 3 ? 'DecodeError' : 'AudioError',
      });
      cleanup();
      onError?.(FRIENDLY_MSG, ctx);
      resolve(false);
    };
    const onPlaying = () => { cleanup(); resolve(true); };
    const cleanup = () => {
      audio.removeEventListener('error', onErr);
      audio.removeEventListener('playing', onPlaying);
    };

    audio.addEventListener('error', onErr, { once: true });
    audio.addEventListener('playing', onPlaying, { once: true });

    // NÃO usar crossOrigin: o bucket r2.dev público não envia CORS; crossorigin quebraria.
    audio.removeAttribute('crossorigin');
    audio.src = url;
    audio.play().catch((playErr) => {
      // Autoplay bloqueado é diferente de arquivo inválido:
      if (playErr?.name === 'NotAllowedError') {
        console.warn('[PTM][play] autoplay bloqueado — exige clique do operador:', { ...ctx, playErr: String(playErr) });
        cleanup();
        onError?.('Toque em play para iniciar a reprodução.', ctx);
        resolve(false);
      } else {
        onErr();
      }
    });
  });
}

// 4) Pular faixa inválida e tentar a próxima, sem quebrar a lista.
async function playFromIndex(tracks, index, opts) {
  for (let i = index; i < tracks.length; i++) {
    const ok = await playTrack(tracks[i], opts);
    if (ok) return i;
  }
  console.error('[PTM][play] nenhuma faixa tocável a partir do índice', index);
  return -1;
}

export { loadTracks, playTrack, playFromIndex, resolveTrackUrl };
```

Regras aplicadas:
- **Login nunca quebra:** carregamento/reprodução de música é isolado; erros são capturados, nunca propagados.
- **Playlist inteira não cai** se uma faixa falhar: `playFromIndex` pula a inválida.
- **Console tem o motivo real** (id, título, `playlist_id`, campo de URL, status HTTP, `MediaError.code`, tipo do erro, mensagem original); **UI mostra só a mensagem amigável**.
- **Autoplay** (`NotAllowedError`) é diferenciado de arquivo inválido.
- **Sem `service_role`**, sem tornar bucket público novo, sem remover RLS.

---

## 4. Como testar

1. Logar no App como `karlos.belisario` (principal "Kadu", 3 faixas).
2. Confirmar no DevTools que a lista vem de `rpc('get_playlist_tracks')` e cada item tem `public_url` (`https://pub-cb01…r2.dev/...mp3`).
3. Clicar numa faixa → deve tocar. Console deve logar `playing`.
4. Teste de falha: apontar temporariamente uma faixa para uma chave inexistente → UI mostra a mensagem amigável, console mostra `HTTP 404` / `SRC_NOT_SUPPORTED`, e o player pula para a próxima.
5. Confirmar que a URL abre direto no navegador (retorna 206, `audio/mpeg`).

---

## 5. Migrations/ajustes recomendados (NÃO aplicados)

Nenhuma migration é necessária para o caso atual (dados e RLS já corretos). Recomendações condicionais:

- **Se o App precisar usar Web Audio API / `crossorigin` / `fetch` do áudio:** o bucket `r2.dev` público **não envia CORS**. Configurar CORS no bucket R2 (`AllowedOrigins`, `AllowedMethods: [GET, HEAD]`, `AllowedHeaders: [Range]`) — é config do R2 no Cloudflare, **não** é migration de banco. Enquanto isso, usar a tag `<audio src>` simples (não exige CORS) resolve.
- **Se algum dia o bucket R2 virar privado** (`public_url = null`): criar uma Edge Function de **signed URL** (`sign-track-url`) que valida `auth.uid()` + propriedade da playlist e devolve URL assinada temporária. **Não existe hoje** e **não deve** ser criada com `service_role` no frontend. Só implementar se a decisão for bucket privado.
- **Hardening (pré-existente, opcional):** revogar grant `anon` das RPCs `get_my_playlists` / `submit_playlist` / `submit_feedback`, deixando só `authenticated`.

---

## 6. Entrega (resumo)

- **Causa raiz:** falha na camada de player do App — uso de campo errado (não `public_url`) e/ou leitura direta de `tracks`/`playlist_tracks` bloqueada por RLS. Backend, dado, R2 e formato corretos.
- **Arquivos alterados neste repo:** nenhum de produção — só este handoff (`docs/audit/fix-reproducao-musica-operador.md`). O código do App está em outro repositório.
- **Campos/tabelas envolvidos:** `tracks.metadata.public_url` (campo tocável), `playlist_tracks`, `playlists`, RPC `get_playlist_tracks`, RLS `admin_all`.
- **Tipo do problema:** URL/campo + query/RLS no App. Não é Storage/R2, formato nem autoplay.
- **Solução:** player de referência da seção 3 (usa RPC + `public_url` + `<audio>` + logs técnicos + mensagem amigável + skip de faixa inválida).
- **Migration recomendada:** nenhuma obrigatória; CORS no R2 e signed-URL só se mudar o modelo (seção 5).
