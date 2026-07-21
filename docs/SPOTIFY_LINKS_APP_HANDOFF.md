# Handoff — links do Spotify no App do Operador

O código do App do Operador não está neste checkout. O backend, o Admin e o
worker usam o contrato abaixo; o App deve importar/copiar a função central
`src/lib/music-url.ts` sem criar uma segunda regex permissiva.

## Tipos e validação

```ts
type SupportedMusicSource = "youtube" | "spotify";

type ParsedMusicUrl = {
  source: SupportedMusicSource;
  resourceType: "track" | "album" | "playlist" | "video";
  resourceId: string;
  originalUrl: string;
  normalizedUrl: string;
};
```

Antes do envio:

1. Chamar `parseMusicUrl(valorDigitado)`.
2. Se retornar `null`, não chamar o Supabase e mostrar:
   `Cole um link válido de música/playlist do YouTube ou de música, álbum ou playlist do Spotify.`
3. Enviar o texto digitado em `url`; o backend é a autoridade e guarda esse
   valor em `original_url`, enquanto normaliza e processa somente
   `normalized_url`. Não enviar `operator_id` nem os campos `source_*`.
4. Manter um único link por solicitação.

## Chamada existente

O App deve preservar a RPC atual e mudar apenas a validação/URL enviada:

```ts
const parsed = parseMusicUrl(link);
if (!parsed) throw new Error("INVALID_URL");

const payload = {
  request_id: crypto.randomUUID(),
  idempotency_key: crypto.randomUUID(),
  operation: "submit",
  type: playlistType,
  url: link,
  expected_revision: currentRevision,
};

const { data, error } = await supabase.rpc("manage_operator_playlist", {
  p_request: payload,
});
```

O backend repete a validação, normaliza novamente e continua resolvendo a
identidade do Operador por `auth.uid()`. O App não deve enviar `operator_id`,
consultar `playlist_requests` diretamente nem tratar Spotify como download de
áudio.

## Registro da solicitação

Cada envio cria/atualiza somente a estrutura existente `playlist_requests`.

## Status geral

O campo legado `status` continua representando somente a decisão administrativa:
`pending`, `approved` ou `rejected`. Não substitua esse campo no App.

A RPC `get_my_playlist_requests` também retorna `general_status`:

- `pending`: aguardando decisão do Admin;
- `approved`: aprovado e ainda não iniciado;
- `analyzing`: o resolver está analisando a origem;
- `waiting_review`: há correspondências que precisam de decisão;
- `processing`: faixas aprovadas estão sendo importadas;
- `partially_completed`: houve conclusão e também falha de faixa;
- `completed`: todos os itens aprovados terminaram;
- `rejected`: solicitação rejeitada;
- `failed`: falha técnica geral sem nenhuma faixa concluída.

O campo `lifecycle_status` anterior permanece na resposta por compatibilidade.

## Mensagens amigáveis e erros técnicos

Cada item retornado ao Admin possui `operator_message`, com texto seguro para
exibição. A solicitação retorna:

- `operator_messages`: lista de avisos amigáveis aplicáveis;
- `operator_message`: primeiro aviso da lista, para interfaces compactas;
- `failure_message`: compatibilidade com o App, preenchido em falha geral ou
  conclusão parcial;
- `technical_error`: disponível somente no detalhe autorizado do Admin, separado
  da mensagem amigável.

O App deve exibir `operator_message`/`failure_message` e nunca renderizar
`error_details`, comandos, caminhos, tokens ou respostas brutas do importador.
O Admin pode mostrar `technical_error` em uma área identificada como diagnóstico
técnico, sem misturá-lo ao texto apresentado ao Operador.

## Regras de segurança

- O App envia somente o link digitado para a RPC; não executa spotDL, yt-dlp,
  FFmpeg ou qualquer processo filho.
- O frontend usa apenas `VITE_SUPABASE_ANON_KEY`/publishable key. Nunca adicionar
  `service_role`, secret key, token do resolver ou credenciais do R2 em `VITE_*`.
- Não consultar `playlist_requests` ou `playlist_request_tracks` diretamente.
  Essas tabelas permanecem com RLS e acesso somente pelas RPCs autorizadas.
- O backend normaliza e valida novamente a URL. Validação visual no App não é
  autorização e não deve ser usada como única proteção.
- O Operador consulta `get_my_playlist_requests`; a identidade vem de
  `auth.uid()`, sem `operator_id` fornecido pelo cliente.
Além de `operator_id`, `playlist_id`, `status`, `created_at` e do motivo/erro
do fluxo de importação já existente, o backend registra:

- `original_url`: o link enviado pelo Operador;
- `normalized_url` e `source_url`: URL canônica usada no processo;
- `source_type`, `source_resource_type`, `source_resource_id`: origem, tipo e
  ID externo extraídos exclusivamente no servidor;
- `source_metadata`: espaço para metadados complementares da origem.

`source_url` foi mantido por compatibilidade com o Admin e o worker atuais.

## URLs aceitas

- `youtube.com`, `www.youtube.com`, `music.youtube.com`, `youtu.be`;
- `open.spotify.com/track/{id}`;
- `open.spotify.com/album/{id}`;
- `open.spotify.com/playlist/{id}`;
- parâmetros de compartilhamento são removidos na normalização.

Podcasts, episódios, shows, artistas, perfis, domínios parecidos e URLs inválidas
devem ser rejeitados antes do envio.
