# Prompt para o dev do app dos operadores — bloquear link de música única

## Problema observado

Um operador conseguiu **enviar um link de UMA música só** (vídeo único do YouTube)
como playlist **Principal**. Exemplo real enviado:

```
https://youtu.be/hQf7MeBTR2E?si=M9czPSSDTqb6e7xC
```

Isso **não pode acontecer**. A Principal (e as Secundárias por link) devem receber
uma **playlist do YouTube**, não um vídeo avulso. Quando o operador manda um vídeo
único, o importador trata como playlist de 1 faixa e ainda pode falhar por outros
motivos, poluindo a fila de aprovação.

## O que precisa mudar NO APP (antes de enviar via RPC)

Validar o link **na tela**, antes de chamar `manage_operator_playlist` (operação
`submit`). Só habilitar o botão de enviar quando o link for uma **playlist** válida.

### Regra de validação (YouTube)

Aceitar **apenas** URLs que contenham o parâmetro de playlist `list=`:

- ✅ `https://www.youtube.com/playlist?list=PLxxxxxxxx`
- ✅ `https://www.youtube.com/watch?v=VIDEO&list=PLxxxxxxxx` (vídeo dentro de uma playlist — o `list=` é o que vale)
- ❌ `https://youtu.be/hQf7MeBTR2E` (vídeo único — **rejeitar**)
- ❌ `https://www.youtube.com/watch?v=hQf7MeBTR2E` (vídeo único — **rejeitar**)

Sugestão de checagem simples (extrair o `list=`):

```ts
function getYoutubePlaylistId(raw: string): string | null {
  try {
    const u = new URL(raw.trim());
    const host = u.hostname.replace(/^www\./, "");
    if (!["youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].includes(host)) {
      return null; // plataforma não suportada
    }
    const list = u.searchParams.get("list");
    // Rejeita playlists automáticas do YouTube (mix/rádio), que não são estáveis.
    if (!list || /^(RD|UL|LL|WL)/.test(list)) return null;
    return list;
  } catch {
    return null;
  }
}

// No submit:
const listId = getYoutubePlaylistId(url);
if (!listId) {
  showError("Envie o link de uma PLAYLIST do YouTube (precisa ter 'list=' na URL), não de uma música única.");
  return; // não chama a RPC
}
```

### UX

- Mensagem clara quando o link for de vídeo único: *"Esse é o link de uma música. Cole
  o link da **playlist** do YouTube (o endereço tem `list=`)."*
- Manter o botão **desabilitado** enquanto o link não passar na validação.
- Ao colar um `watch?v=...&list=...`, aceitar (o `list=` é suficiente).

## Reforço no backend — JÁ APLICADO ✅

A trava definitiva já está no banco (migration `20260710103000_enforce_playlist_url_on_submit.sql`).
A RPC `manage_operator_playlist` (operação `submit`) agora, para links do YouTube,
exige `list=` e rejeita mix/rádio (`list=RD/UL/LL/WL`), devolvendo:

```json
{ "success": false, "error": { "code": "URL_NOT_A_PLAYLIST" } }
```

O app deve **tratar esse código** e mostrar a mensagem amigável (vídeo único não é
playlist). A validação no cliente (acima) continua importante para dar feedback antes
de gastar a chamada. Links de outras plataformas (ex.: Spotify) não são afetados por
esta trava.

## Resumo do que o dev do app entrega

1. Validar o link antes do `submit`: exigir playlist do YouTube (`list=`), rejeitar
   vídeo único e plataformas não suportadas.
2. Mensagens de erro claras + botão desabilitado até o link ser válido.
3. Nada muda nos campos já enviados à RPC (`request_id`, `idempotency_key`,
   `operation`, `expected_revision`, etc.) — é só a validação de entrada.
