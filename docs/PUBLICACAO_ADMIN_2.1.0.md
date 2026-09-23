# Publicação do Porter Admin 2.1.0

Preparação local concluída em 23/09/2026. Nenhum deploy, merge em `main` ou migração de banco foi executado nesta etapa.

## O que entra nesta versão

- Isolamento do cache entre contas, inclusive com consultas antigas em andamento; renovação de token da mesma conta preserva o cache.
- Recuperação de falhas de página e de carregamento após atualização, mantendo o menu quando possível.
- Limpeza dos filtros em uma operação de URL, preservando outros parâmetros e reiniciando a paginação.
- Exportação da auditoria em lotes, ordenados por data e ID. Teto de 5.000 registros com aviso quando houver mais resultados; falhas não geram um arquivo parcial.
- Atualização das dependências do frontend, ferramentas, funções Supabase e worker Python; adaptações de gráficos, calendário e ícones.
- Testes reunidos em `npm test`, incluindo CSV. CI do GitHub para admin e worker.
- Saúde do R2: quando o Worker está offline, mostra “Sem verificação” e separa o último resultado histórico da disponibilidade atual, tanto no menu quanto em Integrações. O Worker permanece desligado conforme planejado.
- Arquivos temporários do Supabase deixam de ser versionados, mas continuam no computador. Áudios e SQLs locais de distribuição ficam ignorados pelo Git.

`package.json` continua sendo a fonte única da versão exibida. O salto de 2.0.9 para 2.1.0 identifica a atualização ampla das dependências e as correções de estabilidade. As versões do app operador e seus registros de atualização não foram alterados.

## Dependências e compatibilidade

| Parte | Versões principais |
| --- | --- |
| Admin | React 19.3.0, React Router 7.18.4, React Query 5.103.2, Supabase JS 2.117.1 |
| Interface | Recharts 3.10.1, DayPicker 10.0.1 (`@daypicker/react`), Tailwind 4.3.3 |
| Build | Vite 8.3.0, TypeScript 7.0.2, Vitest 5.0.1 |
| Node | 24.x; mínimo 24.15.0; versão local fixada em `.nvmrc`: 24.19.0 |
| Funções Supabase | Supabase JS 2.117.0; AWS SDK 3.1137.0; lockfiles atualizados |
| Worker | yt-dlp 2026.8.19, SpotipyFree 1.9.14, redis 8.1.0, boto3 1.43.100, supabase 2.31.0, bgutil 2.0.0 |
| Container do worker | Python 3.12 slim e Deno 2.9.6 |

`npm outdated` não apontou dependências diretas desatualizadas na checagem final. Nas funções, Supabase JS 2.117.1 e AWS SDK 3.1138.0 ainda estavam dentro da janela de 24 horas bloqueada pela política padrão do Deno. Foram usadas as versões estáveis imediatamente anteriores, sem desativar essa proteção. [Política do Deno](https://docs.deno.com/go/minimum-dependency-age).

A divisão manual antiga dos bundles provocou uma falha de execução nos gráficos com Vite 8. A divisão agora é automática, preservando o carregamento das páginas sob demanda. O build exibe um aviso de tamanho do arquivo principal (aproximadamente 712 kB, 212 kB gzip); isso não impede publicação, mas é uma oportunidade futura de otimização.

## Validação concluída

- Instalação limpa com `npm ci`.
- **41 testes do admin**: 14 testes Node, incluindo CSV, e 27 testes de estabilidade/calendário/status do R2.
- Build de produção e TypeScript aprovados.
- Auditoria npm completa: **zero vulnerabilidades conhecidas reportadas**.
- **62 testes do worker** aprovados e `pip check` sem conflitos, usando Python 3.13 local.
- `deno check --frozen` aprovado nas quatro funções.
- Navegação autenticada na prévia local; Visão Geral e Relatórios carregaram dados reais, incluindo gráficos. Auditoria retornou os registros e a limpeza de dois filtros restaurou a URL e a primeira página.
- Fluxos de troca de conta, respostas atrasadas, falha de página/chunk e exportação vazia, paginada, acima do teto e com erro intermediário cobertos por testes automatizados.

Os testes do worker usam serviços simulados. O container Linux não foi construído localmente porque Docker não está instalado. A CI foi adicionada, mas só executará no GitHub após o envio da branch. Importação de música, escrita administrativa, permissões com duas contas reais e atualização do app operador ainda exigem teste controlado no ambiente de publicação.

## O que você precisa fazer manualmente

### 1. Enviar e revisar a branch

Na pasta do projeto:

```powershell
git push -u origin codex/admin-2.1.0
```

Abra a comparação dessa branch com `main` no GitHub e confira os dois jobs da CI. Se o projeto tiver deploy automático por Git, use primeiro a prévia da branch. O documento local de instruções do outro desenvolvedor, os áudios e o SQL da versão do operador não pertencem a este pacote.

### 2. Configurar e publicar a prévia na Vercel

A CLI da Vercel estava sem login nesta sessão. O projeto local já está vinculado a `admin-porter-music`.

No painel da Vercel, configure Node **24.x**, comando de instalação `npm ci`, build `npm run build` e saída `dist`. Verifique estas duas variáveis em **Preview e Production**:

- `VITE_SUPABASE_URL`: URL do projeto Supabase correto.
- `VITE_SUPABASE_ANON_KEY`: chave pública anon/publishable. Nunca usar `service_role` ou uma chave secreta no frontend.

Existe `.env.example` para instalações locais. Variáveis Vite são incorporadas durante o build; após corrigi-las, gere um novo deploy.

Se não usar o deploy automático por Git:

```powershell
npx vercel login
npx vercel
```

Na prévia, entre com uma conta administrativa e confira Relatórios, calendário, filtros, exportação CSV e uma saída seguida de entrada com outra conta. Verifique que não aparecem dados da primeira conta. Teste uma conta com permissões menores. Não use registros reais para operações destrutivas de teste.

### 3. Publicar as funções atualizadas do Supabase

A CLI Supabase estava autenticada e o projeto foi localizado. As funções foram preparadas e checadas localmente; o deploy deve acompanhar o teste final da versão.

```powershell
npx supabase functions deploy music-upload --project-ref aifadvyxsefxfcgzgqol
npx supabase functions deploy provision-operator --project-ref aifadvyxsefxfcgzgqol
npx supabase functions deploy resolve-login-email --project-ref aifadvyxsefxfcgzgqol
npx supabase functions deploy get-current-app-release --project-ref aifadvyxsefxfcgzgqol
```

Preserve as configurações JWT existentes em `supabase/config.toml` e os secrets já cadastrados. Esta versão não exige executar `db push` nem rodar SQL. Confira login por identificador, consulta de versão do operador e upload de uma faixa de teste autorizada.

### 4. Publicar o worker no Railway

No serviço existente, confira a origem Git e a pasta `railway-worker`, faça o rebuild e acompanhe os logs. As variáveis existentes continuam válidas; não as copie para o frontend. Teste uma importação pequena autorizada e a reprodução resultante.

Se `POT_PROVIDER_BASE_URL` estiver configurada, atualize também o serviço externo bgutil para **2.0.0** antes do teste. Atualizar o pacote Python não atualiza esse servidor. Essa versão corrige uma vulnerabilidade no servidor antigo e altera o endereço de escuta padrão; mantenha o acesso pela rede privada e siga as instruções oficiais de migração. [Release bgutil 2.0.0](https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/tag/2.0.0).

### 5. Liberar o admin

Com a prévia e o backend conferidos, faça o merge da branch em `main` para o fluxo de deploy por Git. Se o projeto usa CLI em vez de deploy por Git, publique a revisão validada com `npx vercel --prod`.

Abra o endereço de produção, confira **v2.1.0** no menu e repita um teste rápido de login, relatórios e exportação. A tela “Atualizações” continua cuidando do app operador; não cadastre a versão 2.1.0 do admin ali.

Se precisar reverter o frontend, use o deploy anterior da Vercel. Para worker e funções, publique a revisão anterior dos respectivos componentes. Não há migração nova para desfazer.
