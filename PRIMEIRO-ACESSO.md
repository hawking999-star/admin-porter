# Abrir o admin no seu computador — passo a passo

## Parte A — Preparar (só na primeira vez)

**1. Ter o Node instalado.**
Abra o terminal e digite:
```
node -v
```
- Se aparecer um número (ex.: `v20...` ou maior), está ok.
- Se der erro, baixe o Node em https://nodejs.org (versão **LTS**), instale e reabra o terminal.

**2. Abrir o terminal DENTRO da pasta do projeto.**
No Windows: abra a pasta `admin porter music`, clique na barra de endereço, digite `cmd` e Enter.
(ou botão direito na pasta → "Abrir no Terminal").

**3. Criar o arquivo de configuração `.env`.**
No terminal, dentro da pasta, rode:
```
copy .env.example .env
```
Ele já vem preenchido com o endereço e a chave do Supabase. Não precisa mexer.

**4. Instalar as dependências:**
```
npm install
```
(Baixa uns arquivos; na primeira vez demora um pouco. Se der algum erro estranho, apague a pasta
`node_modules` e rode `npm install` de novo.)

## Parte B — Rodar

**5. Ligar o admin:**
```
npm run dev
```

**6. Abrir no navegador** o endereço que aparecer no terminal — normalmente:
```
http://localhost:5173
```

Para desligar depois: volte no terminal e aperte `Ctrl + C`.

## Parte C — Primeiro acesso (login)

**7. Na tela de login:**
- E-mail: **ascendfittt@gmail.com**
- Senha: a que você definiu quando criou esse usuário no Supabase (04/07).
- *Não lembra a senha?* Me avisa que eu reseto em 10 segundos.

**8. Pronto.** Você entra como **superadmin**. As abas **Condomínios** e **Usuários** já funcionam
(criar, editar, listar). As outras aparecem como "em breve".

## Limpeza opcional

Pode apagar da pasta o arquivo de teste `_probe.txt` (e `src/_probe.txt` / `src/_probedir`, se existirem).
São inofensivos, sobraram de um diagnóstico.
