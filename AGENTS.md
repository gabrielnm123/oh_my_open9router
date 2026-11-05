# AGENTS.md — Plano de Execução do 9router com OpenCode

## 0\. Contexto, Convenções e Regras Não-Negociáveis

- **Estado Atual:** 9router desligado no servidor, usuário e host lidos do `.env` do projeto. A chave SSH requer passphrase.  
- **Convenções de Shell:** Local em `zsh` (`~/.zshenv`), servidor em `bash`.  
- **Regras de Segurança:** O túnel nativo é intocável. Porta `20128` restrita ao túnel. Hardening obrigatório antes de expor o serviço.

> **Credenciais:** nenhuma credencial, host ou URL real vive neste repositório.
> A fonte da verdade é o `.env` da raiz (gitignored, `600`), documentado pelo
> `.env.example` (versionado, só placeholders). Ver **Fase 0.5**.

---

## Fase 0 — Preparação, Descoberta, Hardening e Partida

### 0.0 Autenticação SSH Não-Interativa (Local)

Adicionar o seguinte bloco no `~/.zshenv` local para configurar o `askpass`.
A passphrase **não** fica no `~/.zshenv`: o script de askpass a lê, em tempo de
execução, do arquivo canônico de segredos (`~/.config/venice-stack/9router.env`,
modo `600`), que por sua vez é gerado a partir do `.env` do projeto.

if \[\[ \-z \${VENICE\_STACK\_SSH\_READY-} \]\]; then

  export VENICE\_STACK\_SSH\_READY=1

  cat \> "\${HOME}/.ssh/askpass-venice.sh" \<\<'ASKPASS'

\#\!/usr/bin/env zsh

SECRETS="\${HOME}/.config/venice-stack/9router.env"

if \[\[ \! \-r "\$SECRETS" \]\]; then

  printf 'askpass: %s ausente ou ilegivel\\n' "\$SECRETS" \>&2

  exit 1

fi

grep \-m1 '\^SSH\_KEY\_PASSPHRASE=' "\$SECRETS" | cut \-d= \-f2\- | tr \-d "\\r" | sed \-E "s/^'//; s/'\$//"

ASKPASS

  chmod 700 "\${HOME}/.ssh/askpass-venice.sh"

  export SSH\_ASKPASS="\${HOME}/.ssh/askpass-venice.sh"

  export SSH\_ASKPASS\_REQUIRE=force

  export DISPLAY="\${DISPLAY:-:0}"

  \_vs\_agent\_env="\${HOME}/.ssh/venice-agent.env"

  \[\[ \-f "\${\_vs\_agent\_env}" \]\] && source "\${\_vs\_agent\_env}"

  if \! ssh-add \-l \>/dev/null 2\>&1; then

    ssh-agent \-s \> "\${\_vs\_agent\_env}"

    source "\${\_vs\_agent\_env}"

    ssh-add "\${HOME}/.ssh/id\_ed25519" \\

      \</dev/null \>/dev/null 2\>&1

  fi

  unset \_vs\_agent\_env

fi

Testar conexão:

ssh-add \-l

ssh \-o BatchMode=yes "\${VENICE\_STACK\_SSH\_USER}@\${VENICE\_STACK\_SSH\_HOST}" 'echo SSH\_OK'

zsh \-c 'ssh \-o BatchMode=yes "\${VENICE\_STACK\_SSH\_USER}@\${VENICE\_STACK\_SSH\_HOST}" "echo NONINTERACTIVE\_OK"'

### 0.1 Diagnóstico do Servidor

ssh "\${VENICE\_STACK\_SSH\_USER}@\${VENICE\_STACK\_SSH\_HOST}" 'bash \-lc "uname \-a; node \-v; npm \-v; nproc; free \-h; df \-h /"'

### 0.2 Iniciar o 9router sob systemd

Criar o serviço `/etc/systemd/system/9router.service` no servidor com `Restart=always` e `PORT=20128`. Ativar via `systemctl enable --now 9router`.

O gerador da unit está versionado em `tools/9router-systemd.sh` (usuário, grupo
e diretório de dados são resolvidos em tempo de execução no servidor — o
repositório não carrega nenhum identificador da máquina):

zsh tools/9router-systemd.sh install

zsh tools/9router-systemd.sh status

### 0.3 Hardening

Editar `~/.9router/.env` definindo `REQUIRE_API_KEY=true`, alterando `INITIAL_PASSWORD` e definindo `JWT_SECRET`. Reiniciar o serviço e validar que requisições sem chave retornam `401`.

### 0.4 Forçar e Aguardar o Túnel

Criar o script local `tools/wait-tunnel.sh` para forçar o POST em `/api/tunnel/enable` até que o endpoint público responda `200` ou `401`.

### 0.5 Convenção de Credenciais (`.env` / `.env.example`)

Este repositório vai para um remoto **público**. Nenhum valor real — senha, IP,
hostname, usuário SSH ou URL de túnel — pode existir no repositório, nem no
histórico do git.

**Onde vive cada coisa:**

| Arquivo | Versionado? | Perm. | Conteúdo |
| :--- | :--- | :--- | :--- |
| `.env` (raiz do projeto) | ❌ não (`gitignore`) | `600` | Valores **reais** |
| `.env.example` (raiz do projeto) | ✅ sim | `644` | Só **placeholders** + instruções |
| `~/.config/venice-stack/9router.env` | ❌ fora do repo | `600` | Cópia canônica local dos segredos |
| `~/.zshenv` | ❌ fora do repo | — | Só `export`; **nunca** segredos literais |

**Regras:**

1. Todo script em `tools/` carrega o `.env` via `tools/lib/venice-env.sh`
   (`set -a; source`). Nenhum host, usuário ou URL fica hardcoded.
2. O `.env` real tem permissão `600` e **nunca** é commitado.
3. Ao provisionar outra máquina: `cp .env.example .env`, preencher com os
   valores reais, `chmod 600 .env`.
4. **Senha de admin do 9router já rotacionada.** Copie o valor real
   (`NINEROUTER_ADMIN_PASSWORD`); **não rotacione de novo** — isso invalidaria
   as credenciais já distribuídas.
5. A passphrase da chave SSH **não** é senha do 9router. Ela nunca é
   digitada em lugar nenhum: o `askpass` a lê do arquivo canônico de segredos
   em tempo de execução.

**Rotacionar a senha de admin (só se quiser invalidar a atual):**

A fonte autoritativa é o hash bcrypt em `settings.data.password` do
`~/.9router/db/data.sqlite`. O `INITIAL_PASSWORD` do `.env` do servidor é
apenas o fallback de bootstrap — trocar só ele **não** rotaciona nada.

A rotação correta é pela API da própria aplicação (rota local-only, exige o
cookie `auth_token`):

curl \-sS \-X PATCH http://127.0.0.1:20128/api/settings \\
  \-H 'Content-Type: application/json' \\
  \-b "auth_token=$JWT" \\
  \-d '{"currentPassword":"<ATUAL>","newPassword":"<NOVA>"}'

`PUT` nessa rota retorna `405` — o verbo aceito é `PATCH`. Depois de rotacionar,
atualize `INITIAL_PASSWORD` em `~/.9router/.env` (servidor) **e**
`NINEROUTER_ADMIN_PASSWORD` no `.env` local + em
`~/.config/venice-stack/9router.env`, sempre em conjunto.

---

## Fase 1 — Configuração do OpenCode

- Adicionar `NINEROUTER_API_KEY` no `~/.zshenv` (export puro; o valor vem do `.env` do projeto).  
- Criar `~/.config/opencode/opencode.json` apontando para o provedor `9router` com a baseURL do túnel.
- A `baseURL` é `NINEROUTER_BASE_URL` **com o sufixo `/v1`** — é a rota OpenAI-compatível. O host puro fica em `NINEROUTER_RELAY_HOST`.
- A chave de API entra no **ambiente do serviço** do OpenCode (`zsh tools/opencode-service.sh`), não no arquivo de config versionado.

---

## Fase 2 — Instalação do Framework

npx oh-my-opencode-slim@latest install \--no-tui \--background-subagents=yes

npx oh-my-opencode-slim@latest doctor

---

## Fase 3 — Sondagem de Modelos (`tools/probe-models.sh`)

Criar o script de teste de latência e suporte a tool calling (`get_weather`) salvando em `probe.jsonl`.

A sonda é **sempre completa**: catálogo inteiro do 9router + todos os nativos do
OpenCode, sem filtro e sem `--quick`. Nenhum resultado antigo é reaproveitado.

---

## Fase 4 — Atribuição aos Agentes

Configurar os melhores modelos aprovados em `~/.config/opencode/oh-my-opencode-slim.json` para cada papel (orchestrator, oracle, explorer, designer, fixer, observer, council).

Só entra no pool quem foi pingado **e** aprovado (`HTTP 200` + tool call), nas
duas pontas. Nativo sem sonda válida fica de fora, mesmo presente no catálogo do
OpenCode. Se a sonda falhar, nada é gravado.

---

## Fase 5 — Verificação Final

Validar a integração com `npx oh-my-opencode-slim doctor` e `opencode models`.