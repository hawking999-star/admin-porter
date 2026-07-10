# Importação de playlist falhando ("playlist privada ou indisponível")

## O que está acontecendo

A playlist é **lida** normalmente (o worker acha as músicas), mas o **download** de cada faixa falha em TODAS as playlists. Isso não é playlist privada de verdade: o YouTube trata o IP do servidor (Railway) como "robô" e recusa o download, mesmo de vídeos públicos.

O yt-dlp já está atualizado, então o problema não é versão velha.

## A correção que destrava de vez: cookies

Colar no Railway os cookies de uma conta YouTube logada. Passo a passo:

1. No Chrome, instale a extensão **"Get cookies.txt LOCALLY"**.
2. Faça login em **youtube.com** (use uma conta secundária/descartável — os cookies dão acesso a essa conta).
3. Com o youtube.com aberto, clique na extensão → **Export** → salva um `cookies.txt`.
4. Abra o `cookies.txt` e **copie todo o conteúdo**.
5. No **Railway** → serviço do **worker** → aba **Variables** → crie a variável:
   - Nome: `YOUTUBE_COOKIES`
   - Valor: cole todo o conteúdo do `cookies.txt`
6. Salve e deixe o worker **redeployar**. Reprocesse a playlist (botão "Tentar importar novamente").

## Manutenção

- Cookies **expiram** de tempos em tempos. Quando isso acontecer, o worker agora avisa com a mensagem "o YouTube recusou os cookies atuais (podem ter expirado)". É só repetir os passos e atualizar a variável.
- Se um dia quiser, dá para ajustar a ordem dos "player clients" pela variável `YT_PLAYER_CLIENTS` (padrão `tv,ios,android,web`) sem mexer no código.

## O que já melhorei no código do worker

- **Cascata de player clients**: cada faixa é tentada em vários clients do YouTube (tv → ios → android → web) e, se houver cookies, com e sem cookie. Isso sozinho já resolve parte dos bloqueios intermitentes.
- **Mensagens de erro honestas**: em vez de dizer "playlist privada", agora aponta a causa provável (falta de cookies / cookies expirados), que é o que realmente destrava.

> Importante: essas mudanças precisam ir para o Railway (deploy do worker) para valer. E o teste real só dá pra fazer lá — do meu ambiente o YouTube fica bloqueado.
