# venice-stack

Infraestrutura de gateway de IA: **[9router](https://github.com/)** rodando
headless num servidor, exposto por **túnel nativo**, integrado ao
**[OpenCode](https://opencode.ai)** como provider OpenAI-compatível, com
**oh-my-opencode-slim** orquestrando os agentes.

Este repositório é **infraestrutura-agnóstico**: não contém nenhum host,
usuário, senha ou URL real. Tudo isso vive num `.env` local (gitignored,
mode `600`), описunto por um `.env.example` versionado com placeholders.

```
   OpenCode ──► provider "9router" ──► relay do túnel ──► 127.0.0.1:20128 (9router)
                                                    ▲
   oh-my-opencode-slim ──► 7 papéis de agente ───────┘
```

---

## Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Preparar o repositório](#2-preparar-o-repositório)
3. [Fase 0 — Servidor: 9router headless e endurecido](#3-fase-0--servidor-9router-headless-e-endurecido)
4. [Fase 0 — Local: SSH não interativo](#4-fase-0--local-ssh-não-interativo)
5. [Fase 0 — Túnel nativo](#5-fase-0--túnel-nativo)
6. [Fase 1 — OpenCode como cliente do 9router](#6-fase-1--opencode-como-cliente-do-9router)
7. [Fase 2 — oh-my-opencode-slim](#7-fase-2--oh-my-opencode-slim)
8. [Fase 3 — Sondagem dos modelos](#8-fase-3--sondagem-dos-modelos)
9. [Fase 4 — Atribuição dos modelos aos papéis](#9-fase-4--atribuição-dos-modelos-aos-papéis)
10. [Fase 5 — Verificação final](#10-fase-5--verificação-final)
11. [Rotação de credenciais](#11-rotação-de-credenciais)
12. [Referência da API do 9router](#12-referência-da-api-do-9router)
13. [Referência dos scripts](#13-referência-dos-scripts)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Pré-requisitos

**Servidor (Ubuntu):**

| Item | Versão / observação |
| :--- | :--- |
| Node.js | ≥ 20 (o app usa `node:sqlite` e `sql.js`) |
| 9router | instalado globalmente (`/usr/local/lib/node_modules/9router`) |
| systemd | para o serviço headless |
| `sudo` | **NOPASSWD** para o usuário de serviço (o script usa `sudo -n`) |
| `python3` | usado pelos scripts de parsing de JSON |

**Local:**

| Item | Versão / observação |
| :--- | :--- |
| OpenCode | v2.x (cliente–servidor) |
| zsh | `~/.zshenv` é lido por shells **não interativos** (`zsh -c`) |
| ssh | com `ssh-agent` + `SSH_ASKPASS` |
| curl, jq, python3 | — |

> ⚠️ **Nunca exponha a porta `20128`.** O acesso externo é **exclusivamente**
> pelo túnel nativo do 9router. Não crie `cloudflared`/`ngrok` paralelos e não
> troque a URL do túnel.

---

## 2. Preparar o repositório

```bash
cp .env.example .env
chmod 600 .env
```

Preencha o `.env` com os valores reais. O `.env.example` documenta **cada**
variável e diz de onde obtê-la:

| Variável | Para que serve |
| :--- | :--- |
| `VENICE_STACK_SSH_HOST` | host/IP do servidor (SSH) |
| `VENICE_STACK_SSH_USER` | usuário SSH do servidor |
| `VENICE_SERVER_HOSTNAME` | hostname do servidor (só diagnóstico) |
| `SSH_KEY_PASSPHRASE` | passphrase da **chave SSH** (não é a senha do 9router) |
| `NINEROUTER_BASE_URL` | URL base da API — **precisa do sufixo `/v1`** |
| `NINEROUTER_RELAY_HOST` | host do relay estável (sem esquema, sem `/v1`) |
| `NINEROUTER_TUNNEL_HOST` | host do quick tunnel (efêmero) |
| `NINEROUTER_API_KEY` | chave de cliente das rotas `/v1` |
| `NINEROUTER_ADMIN_PASSWORD` | senha de **admin** do dashboard |
| `NINEROUTER_JWT_SECRET` | segredo de assinatura JWT (64 hex) |

Regras invioláveis:

- `.env` **nunca** é versionado (já coberto pelo `.gitignore`), mode `600`.
- `.env.example` **é** versionado e só tem placeholders.
- No shell local, as variáveis vão em `~/.zshenv` — **nunca** em `~/.zshrc`
  (que só é lido em shell interativo, e o OpenCode roda `zsh -c`).

---

## 3. Fase 0 — Servidor: 9router headless e endurecido

### 3.1 Instalação do app

```bash
ssh "${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}" 'bash -lc "npm i -g 9router && node -v"'
```

### 3.2 Hardening do `.env` do servidor

O diretório de dados do app **não** é `~/9router` — é `~/.9router` (divergência
D1 do `PLAN.md`). O `EnvironmentFile=` da unit aponta para lá.

```bash
ssh "${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}" 'bash -lc "
  set -e
  install -d -m 700 ~/.9router
  cp ~/.9router/.env ~/.9router/.env.bak.\$(date +%s) 2>/dev/null || true
  chmod 600 ~/.9router/.env
"'
```

No `~/.9router/.env` do servidor, defina:

```ini
REQUIRE_API_KEY=true
INITIAL_PASSWORD=<senha de admin de 40+ chars>
JWT_SECRET=<64 caracteres hexadecimais>
PORT=20128
HOSTNAME=127.0.0.1
```

> `INITIAL_PASSWORD` é apenas o **fallback de bootstrap**. A senha que
> realmente vale é o hash bcrypt em `settings.data.password`, dentro de
> `~/.9router/db/data.sqlite`. Trocar só o `INITIAL_PASSWORD` **não** rotaciona
> nada — veja [§11](#11-rotação-de-credenciais).

### 3.3 Gerar a unit systemd

O gerador está versionado. Ele resolve **usuário, grupo e diretório de dados
em tempo de execução no servidor** — o repositório não carrega identificador
de máquina algum (a unit é montada com placeholders `@SERVICE_USER@`,
`@SERVICE_GROUP@` e `@DATA_DIR@`, substituídos por `sed` antes da instalação).

```bash
zsh tools/9router-systemd.sh install
zsh tools/9router-systemd.sh status
```

O que a unit faz:

| Aspecto | Valor |
| :--- | :--- |
| Restart | `always`, `RestartSec=5` |
| Ambiente | `NODE_ENV=production`, `PORT=20128`, `HOSTNAME=127.0.0.1` |
| Segredos | `EnvironmentFile=~/.9router/.env` — **falha fechada** (sem `.env`, não sobe) |
| Sandbox | `ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges`, `MemoryMax=600M` |
| Rede | `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` |
| `ExecStartPost` | retoma o túnel nativo em background |

Comandos úteis:

```bash
zsh tools/9router-systemd.sh uninstall
ssh "$VENICE_STACK_SSH_USER@$VENICE_STACK_SSH_HOST" 'sudo -n systemctl restart 9router'
```

### 3.4 Validar o hardening

```bash
# sem chave -> 401 (a porta e local-only, entao via SSH)
ssh "$VENICE_STACK_SSH_USER@$VENICE_STACK_SSH_HOST" \
  'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:20128/v1/models'

# com chave -> 200
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $NINEROUTER_API_KEY" "$NINEROUTER_BASE_URL/models"
```

---

## 4. Fase 0 — Local: SSH não interativo

O agente OpenCode roda `zsh -c`, que **não** é interativo: não há prompt para
digitar a passphrase da chave. A solução é um `askpass` que lê a passphrase do
arquivo canônico de segredos **em tempo de execução**.

Bloco para o `~/.zshenv` (mode `600`):

```zsh
if [[ -z ${VENICE_STACK_SSH_READY-} ]]; then
  export VENICE_STACK_SSH_READY=1

  # --- askpass -------------------------------------------------------------
  # O script NAO contem a passphrase: ele a le do arquivo canonico de
  # segredos (600, fora do git). Nenhum segredo vive no shell ou no repo.
  cat > "${HOME}/.ssh/askpass-venice.sh" <<'ASKPASS'
#!/usr/bin/env zsh
SECRETS="${HOME}/.config/venice-stack/9router.env"
if [[ ! -r "$SECRETS" ]]; then
  printf 'askpass: %s ausente ou ilegivel\n' "$SECRETS" >&2
  exit 1
fi
grep -m1 '^SSH_KEY_PASSPHRASE=' "$SECRETS" | cut -d= -f2- | tr -d "\r" | sed -E "s/^'//; s/'$//"
ASKPASS
  chmod 700 "${HOME}/.ssh/askpass-venice.sh"

  export SSH_ASKPASS="${HOME}/.ssh/askpass-venice.sh"
  export SSH_ASKPASS_REQUIRE=force
  export DISPLAY="${DISPLAY:-:0}"

  # --- agente SSH ----------------------------------------------------------
  export SSH_AUTH_SOCK="${HOME}/.ssh/agent.sock"
  if ! ssh-add -l >/dev/null 2>&1; then
    ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1 \
      || { rm -f "$SSH_AUTH_SOCK"; ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1; }
  fi
  if ! ssh-add -l >/dev/null 2>&1; then
    ssh-add "${HOME}/.ssh/id_ed25519" </dev/null >/dev/null 2>&1
  fi
fi

# --- contexto do servidor e do provider (Fase 0.5) ---------------------------
# Host, usuario e URL base sao lidos do arquivo canonico de segredos em tempo
# de execucao. Nenhum valor literal aqui: o .env do projeto e a fonte da
# verdade, e este arquivo e a copia canonica local dele.
_vs_secrets="${HOME}/.config/venice-stack/9router.env"
if [[ -r "$_vs_secrets" ]]; then
  _vs_get() {
    grep -m1 "^$1=" "$_vs_secrets" | cut -d= -f2- | tr -d "\r" | sed -E "s/^'//; s/'$//"
  }
  export VENICE_STACK_SSH_HOST="$(_vs_get VENICE_STACK_SSH_HOST)"
  export VENICE_STACK_SSH_USER="$(_vs_get VENICE_STACK_SSH_USER)"
  export NINEROUTER_BASE_URL="$(_vs_get NINEROUTER_BASE_URL)"
  unset -f _vs_get
fi
unset _vs_secrets

# --- provider 9router -------------------------------------------------------
export NINEROUTER_API_KEY="<chave-de-cliente-do-9router>"
```

E o arquivo canônico de segredos:

```bash
install -d -m 700 ~/.config/venice-stack
cp .env ~/.config/venice-stack/9router.env
chmod 600 ~/.config/venice-stack/9router.env
```

> O guard `VENICE_STACK_SSH_READY` é **por processo**: cada shell novo
> reexecuta o bloco, e se o agente morreu ele é reerguido. É idempotente e
> seguro para execução concorrente.
>
> O `~/.zshenv` fica **mode `600`** e nunca é versionado. Ele não guarda
> host, usuário ou URL literais: lê tudo do arquivo canônico em tempo de
> execução.

Teste:

```bash
ssh-add -l
ssh -o BatchMode=yes "${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}" 'echo SSH_OK'
zsh -c 'ssh -o BatchMode=yes "${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}" "echo NONINTERACTIVE_OK"'
```

> O segundo comando é o que importa: prova que funciona **sem TTY**.

---

## 5. Fase 0 — Túnel nativo

O 9router gerencia o próprio túnel (relay estável + quick tunnel direto). O
script abaixo **força** o `POST /api/tunnel/enable` e espera o endpoint
público responder.

```bash
zsh tools/wait-tunnel.sh --status   # só consulta
zsh tools/wait-tunnel.sh enable      # força e aguarda
zsh tools/wait-tunnel.sh wait        # só aguarda
```

Fluxo interno:

1. Deriva o token CLI no servidor:
   `sha256(machine-id + "9r-cli-auth" + cli-secret)[:16]`.
2. `GET /api/tunnel/status` → `tunnel.publicUrl` (relay) e `tunnel.tunnelUrl`
   (quick tunnel direto).
3. Testa os dois hosts; aceita `200` **ou** `401` como "túnel no ar".
4. Se o `publicUrl` vier vazio, faz fallback lendo
   `~/.9router/tunnel/state.json` no servidor.

> **O relay é o endereço canônico.** A URL `trycloudflare` muda a cada
> `enable` — nunca a coloque como `baseURL` do provider.
>
> O `Health check timeout` da rota é um **falso negativo conhecido**: o relay
> propaga o upstream em mais de 60 s. O script valida pelo
> `/api/tunnel/status` real, não pela resposta da rota.

Depois do túnel no ar, copie o relay para o `.env`:

```bash
NINEROUTER_RELAY_HOST='<host-do-relay>'
NINEROUTER_BASE_URL="https://${NINEROUTER_RELAY_HOST}/v1"
```

---

## 6. Fase 1 — OpenCode como cliente do 9router

### 6.1 Provider no `~/.config/opencode/opencode.json`

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "9router/ag/claude-sonnet-4-6",
  "providers": {
    "9router": {
      "name": "9Router",
      "package": "@opencode/ai/providers/openai-compatible",
      "env": ["NINEROUTER_API_KEY", "NINEROUTER_BASE_URL"],
      "settings": {
        "baseURL": "{env:NINEROUTER_BASE_URL}",
        "apiKey": "{env:NINEROUTER_API_KEY}",
        "chunkTimeout": 600000,
        "headerTimeout": 600000
      },
      "models": {
        "<modelo>": {
          "name": "<modelo>",
          "capabilities": {
            "tools": true,
            "input": ["text", "image", "pdf"],
            "output": ["text"],
            "reasoning": { "supported": true }
          },
          "limit": { "context": 200000, "output": 64000 }
        }
      }
    }
  }
}
```

Pontos críticos:

- `baseURL` **inclui `/v1`**. Sem ele, `/models` devolve `404`.
- A chave vem por **`{env:NINEROUTER_API_KEY}`** — nunca literal no arquivo.
- A URL também vem por **`{env:NINEROUTER_BASE_URL}`**: o `opencode.json`
  fica **sem nenhum valor real** (nem host, nem chave). Quem carrega o valor
  é o `~/.zshenv`, que o lê do arquivo canônico de segredos em tempo de
  execução. Se preferir o literal (`https://<relay>/v1`), funciona igual —
  mas o arquivo passa a carregar um identificador de infraestrutura.
- `chunkTimeout` / `headerTimeout` altos: o relay propaga devagar e models
  "thinking" podem ficar minutos sem primeiro token.

### 6.2 Catálogo de modelos

O 9router expõe o catálogo em `GET /v1/models`. Prefixos de família:

| Família | Origem |
| :--- | :--- |
| `ag/` | Antigravity (Claude, Gemini) |
| `cx/` | Codex (GPT) |
| `oc/` | OpenCode / free tier |
| `gh/` | GitHub Copilot |
| `gc/` | Google |
| `kimi/` | Kimi |
| `mmf/` | — |
| `nous/` | Nous (modelos `:free`) |
| `xai/` | xAI (Grok) |
| `gcli/` | Google CLI (Grok) |
| `qd/` | Qoder (`dfmodel`/`qfmodel` funcionam; o resto pede assinatura) |
| `kc/` | Kilocode (exige créditos — hoje só `402`) |

> ⚠️ **O catálogo é pouco confiável.** Nem todo ID listado funciona. Sempre
> valide com a [sonda](#8-fase-3--sondagem-dos-modelos) antes de atribuir um
> modelo a um papel.

### 6.3 O daemon precisa do env

O OpenCode v2 é **cliente–servidor**. O daemon compartilhado
(`opencode serve --service`) é daemonizado (PPID=1) e **congela o ambiente
no exec**: se ele nasceu antes do `~/.zshenv` receber o export, toda chamada
falha com `Error: API key required for remote API access` — mesmo com a
configuração correta.

A correção é persistir o env **no próprio serviço**:

```bash
zsh tools/opencode-service.sh            # garante env + serviço healthy
zsh tools/opencode-service.sh --check    # só diagnostica
zsh tools/opencode-service.sh --probe    # diagnostica + inferência real
```

Ele usa `opencode service set env <KEY> <VALUE>`, para que o daemon nasça com
as variáveis independente de quem o iniciou.

> **Atenção ao diagnóstico.** O `--check` valida o **processo vivo**
> (`/proc/<pid>/environ`). Um daemon pode estar saudável *e* ter as
> variáveis apenas por **herança** do shell que o iniciou — nesse caso o
> `service.json` fica incompleto e o próximo restart quebra o provider.
> Por isso o `ensure` grava o env no `service.json` sempre que o valor
> persistido diverge do valor do shell, independentemente do health check.

Variáveis obrigatórias do daemon (lista `REQUIRED_VARS` do script):

| Variável | Por quê |
| :--- | :--- |
| `NINEROUTER_API_KEY` | autenticação no `/v1` |
| `NINEROUTER_BASE_URL` | o `opencode.json` referencia `{env:NINEROUTER_BASE_URL}` — sem ela no daemon, o provider fica **sem baseURL** e toda chamada falha |
| `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS` | habilita subagentes em background |

> Depois de qualquer mudança no `opencode.json` ou no
> `oh-my-opencode-slim.json`, reinicie: `opencode service restart`.
> O daemon carrega a config na inicialização — editar o arquivo não basta.

### 6.4 Comando global `/refresh_models_9router`

O `opencode.json` lista os modelos **um a um** em
`providers.9router.models` — o OpenCode não descobre modelos de um provedor
custom chamando `/v1/models` (descoberta automática existe só para Ollama, LM
Studio, vLLM, Copilot e Azure). Quando o 9router ganha uma conexão nova, os
modelos dela simplesmente não aparecem no `/models` do TUI até a config ser
regravada.

Para não depender de entrar neste repositório toda vez, existe um comando
**global** do OpenCode:

```
zsh tools/install-command.sh        # instala/atualiza (idempotente)
zsh tools/install-command.sh status
zsh tools/install-command.sh uninstall
```

Depois disso, em **qualquer** projeto, dentro do TUI:

```
/refresh_models_9router                 # aplica (com backup antes)
/refresh_models_9router --dry-run       # só mostra o que mudaria
/refresh_models_9router --prune         # remove o que sumiu do catálogo
/refresh_models_9router --refresh       # reescreve limits/capabilities
/refresh_models_9router --only=qd/      # só uma família
```

O que o instalador deixa na máquina:

| Caminho | Papel |
| :--- | :--- |
| `~/.local/share/9router-tools/sync-catalog.sh` + `lib/venice-env.sh` | cópia do sincronizador, para rodar fora do repo |
| `~/.local/bin/refresh-9router-models` | wrapper que valida as flags e chama o script |
| `~/.config/opencode/commands/refresh_models_9router.md` | o comando de barra em si (descoberto globalmente) |

O comando usa um bloco de shell (`` !`…` ``) que roda o wrapper e injeta a
saída no prompt; o agente só resume o resultado. Caminhos são absolutos, então
funciona com qualquer diretório de trabalho.

> **Em outra máquina:** rode `zsh tools/install-command.sh` de dentro do repo e
> garanta que a cópia canônica `~/.config/venice-stack/9router.env` (600)
> exista — é dela que o script instalado tira `NINEROUTER_BASE_URL` e
> `NINEROUTER_API_KEY` quando não há `.env` por perto. Ver
> [§11](#11-rotação-de-credenciais) e `tools/lib/venice-env.sh`.

### 6.5 Comando global `/auto_select_models_oh_my_opencode_slim`

O catálogo lista **IDs**, não garantias: um modelo pode aparecer no `/models` e
responder `403`/`402`/`503` no upstream, ou não suportar tool calling. Atribuir
um desses a um agente quebra o fluxo. Este comando sonda antes de escolher.

```
/auto_select_models_oh_my_opencode_slim                 # sonda tudo e aplica
/auto_select_models_oh_my_opencode_slim --dry-run       # só mostra a atribuição
/auto_select_models_oh_my_opencode_slim --quick         # sonda reduzida (mais rápido)
/auto_select_models_oh_my_opencode_slim --only-native   # ignora o 9router
/auto_select_models_oh_my_opencode_slim --no-restart    # grava sem reiniciar o daemon
```

O mesmo instalador (`zsh tools/install-command.sh`) cria:

| Caminho | Papel |
| :--- | :--- |
| `~/.local/share/9router-tools/select-models.sh` | motor de seleção |
| `~/.local/share/9router-tools/probe-models.sh` | sonda de latência + tool calling |
| `~/.local/bin/auto-select-9router-models` | wrapper que valida as flags |
| `~/.config/opencode/commands/auto_select_models_oh_my_opencode_slim.md` | o comando de barra |

Como ele decide:

1. sonda o 9router (`probe-models.sh`) e os modelos **nativos** do OpenCode
   (`opencode/*`, `gh/*`, `cx/*`, …) com o mesmo teste de `get_weather`;
2. considera aprovado só `HTTP 200` **e** tool call devolvido;
3. classifica por papel (`werkzeug`, `rapido`, `raciocinio`, `visao`,
   `nao_critico`) e escolhe até 3 referências por agente (principal +
   fallbacks), mais os quatro `council/*`;
4. prefere o 9router (tier 0); se não houver nenhum aprovado, usa os nativos
   como plano B — se só existirem os free do OpenCode, são eles que entram;
5. grava `~/.config/opencode/oh-my-opencode-slim.json` com backup em
   `~/.config/opencode/backups/` e reinicia o daemon (salvo `--no-restart`).

Os arquivos de sonda (`probe.jsonl`, `probe-native.jsonl`) ficam ao lado dos
scripts instalados (`~/.local/share/9router-tools/`) quando o comando roda fora
do repo, e na raiz do projeto quando roda de dentro dele.

> Modelos `:free`/`-free` recebem penalidade na pontuação: são o último recurso,
> nunca a primeira escolha quando há um equivalente pago aprovado.

> **Restart do daemon:** o comando de barra usa `--no-restart` por padrão.
> `opencode service restart` derruba a própria sessão do TUI, e o comando seria
> cancelado antes de responder. Depois de aplicar, rode
> `opencode service restart` (ou reabra o app) para o daemon carregar a nova
> atribuição. Fora do TUI, `--restart` faz isso na mesma execução.

---

## 7. Fase 2 — oh-my-opencode-slim

```bash
npx oh-my-opencode-slim@latest install --no-tui --background-subagents=yes
npx oh-my-opencode-slim@latest doctor
```

> ⚠️ **Armadilha do instalador:** por padrão ele escreve o bloco de env em
> **`~/.zshrc`** e sugere `source ~/.zshrc` — contrariando a regra do
> `AGENTS.md` (exports no `~/.zshenv`). Passe
> `--background-subagents-target=<caminho-do-zshenv>` para corrigir na
> instalação, e confira que o `~/.zshrc` ficou intocado.

O `doctor` deve reportar `ok: true`.

---

## 8. Fase 3 — Sondagem dos modelos

O script mede, para cada modelo do catálogo: **latência** (ttfb e total),
**código HTTP** e **suporte a tool calling** (função `get_weather` com
`tool_choice=auto`).

```bash
zsh tools/probe-models.sh                          # sonda tudo
zsh tools/probe-models.sh --filter 'ag/'           # só uma família
zsh tools/probe-models.sh --concurrency 6          # mais paralelismo
zsh tools/probe-models.sh --repeat 2               # 2 requisições por modelo
zsh tools/probe-models.sh --models lista.txt       # lista própria
zsh tools/probe-models.sh --out probe.jsonl        # caminho de saída
```

Saída: uma linha JSON por modelo em `probe.jsonl` (gitignored) + relatório
tabular no stdout.

Regras: a sonda fala **sempre pelo relay público**, nunca direto na porta
`20128`. `NINEROUTER_BASE_URL` e `NINEROUTER_API_KEY` são obrigatórios —
vêm do `.env` (carregado por `tools/lib/venice-env.sh`) ou do ambiente.

---

## 9. Fase 4 — Atribuição dos modelos aos papéis

Configure `~/.config/opencode/oh-my-opencode-slim.json`:

```json
{
  "$schema": "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json",
  "preset": "9router",
  "image_routing": "auto",
  "presets": {
    "9router": {
      "orchestrator": { "model": ["9router/ag/claude-sonnet-4-6", "…"] },
      "oracle":       { "model": ["9router/ag/claude-opus-4-6-thinking", "…"] },
      "explorer":     { "model": ["9router/ag/gpt-oss-120b-medium", "…"] },
      "designer":     { "model": ["9router/cx/gpt-5.6-luna", "…"] },
      "fixer":        { "model": ["9router/cx/gpt-6-luna", "…"] },
      "observer":     { "model": ["9router/ag/gemini-3.8-flash", "…"] },
      "council":      { "model": ["9router/ag/claude-sonnet-4-6", "…"] }
    }
  },
  "council": {
    "default_preset": "default",
    "presets": {
      "default": {
        "architect": { "model": "9router/ag/claude-opus-4-6-thinking",
                       "prompt": "Focus on maintainability, boundaries, and long-term design." },
        "reviewer":  { "model": "9router/cx/gpt-5.6-luna",
                       "prompt": "Focus on bugs, edge cases, and failure modes." },
        "optimiser": { "model": "9router/oc/deepseek-v4.1-flash-free",
                       "prompt": "Focus on performance, latency, and resource usage." },
        "visual":    { "model": "9router/ag/gemini-3.8-flash",
                       "prompt": "Focus on UI/UX correctness, accessibility, and visual details." }
      }
    }
  }
}
```

Princípios da atribuição:

- **Só modelos aprovados pela sonda** (HTTP 200 **e** tool calling OK).
- **Diversidade de família** no `council` — assentos com a mesma família
  reduzem a diversidade do consenso; assentos com famílias diferentes somam
  visões realmente independentes.
- `observer` precisa de um modelo **capaz de visão**.
- `oracle` e o `architect` do council são os de **raciocínio** mais forte.

Depois de editar a config:

```bash
opencode service restart
```

> O OpenCode é cliente–servidor: editar a config **sem** reiniciar o serviço
> não muda nada (divergência D10).

---

## 10. Fase 5 — Verificação final

```bash
npx oh-my-opencode-slim@latest doctor
opencode models
zsh tools/opencode-service.sh --probe
```

O `--probe` faz uma inferência **real** no provider — não só checa config.
O `PLAN.md` tem o registro completo das Fases 0 a 5, com todas as divergências
encontradas (D1–D12).

---

## 11. Rotação de credenciais

### 11.1 O que precisa ser mudado junto

| Onde | O quê |
| :--- | :--- |
| `~/.9router/db/data.sqlite` | `settings.data.password` (bcrypt) — **fonte autoritativa** |
| `~/.9router/.env` (servidor) | `INITIAL_PASSWORD` (fallback de bootstrap) |
| `.env` (local) | `NINEROUTER_ADMIN_PASSWORD` |
| `~/.config/venice-stack/9router.env` | `NINEROUTER_ADMIN_PASSWORD` |

> ⚠️ O login do 9router tem **lockout** (4 tentativas falhas). Um teste com
> senha vazia já consumiu uma delas. Não repita.

### 11.2 Procedimento

```bash
# 1) login -> cookie auth_token
curl -sS -X POST http://127.0.0.1:20128/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"password":"<ATUAL>"}' -c /tmp/9r-cookies.txt

# 2) rotaciona (PATCH, nao PUT — PUT devolve 405)
curl -sS -X PATCH http://127.0.0.1:20128/api/settings \
  -H 'Content-Type: application/json' \
  -b /tmp/9r-cookies.txt \
  -d '{"currentPassword":"<ATUAL>","newPassword":"<NOVA>"}'

# 3) confirma: login novo -> 200, login antigo -> 401
```

A rotação é feita **pela API da aplicação**, nunca editando o banco
diretamente: o hash bcrypt é gerado com o custo certo e o `INITIAL_PASSWORD`
do servidor fica sincronizado.

### 11.3 Depois de rotacionar

1. Atualize `INITIAL_PASSWORD` no `~/.9router/.env` do servidor (faça backup
   antes) e reinicie o serviço.
2. Atualize `NINEROUTER_ADMIN_PASSWORD` no `.env` local **e** em
   `~/.config/venice-stack/9router.env`.
3. Valide que `/v1` não foi afetado: `GET /v1/models` autenticado → 200,
   sem chave → 401.

> `POST /api/auth/reset-password` **não** rotaciona: ele apenas apaga o hash
> guardado e volta ao valor default. É um *reset*, não uma rotação.

### 11.4 Regra de ouro

**A senha de admin já foi rotacionada.** Ao provisionar outra máquina,
**copie** o valor — não rotacione de novo, ou você invalida as credenciais
já distribuídas.

---

## 12. Referência da API do 9router

Rotas *local-only* (`127.0.0.1:20128`, acessíveis por SSH):

| Método | Rota | Descrição |
| :--- | :--- | :--- |
| `GET` | `/api/health` | liveness |
| `GET` | `/api/version` | versão instalada |
| `GET` | `/api/providers` | conexões configuradas |
| `GET` | `/api/models` | catálogo roteável |
| `GET` | `/api/keys` | API keys de cliente |
| `GET` | `/api/settings` | settings (exige `auth_token`) |
| `PATCH` | `/api/settings` | **rotaciona a senha** (`PUT` → 405) |
| `POST` | `/api/tunnel/enable` | força o túnel |
| `POST` | `/api/tunnel/disable` | derruba o túnel |
| `GET` | `/api/tunnel/status` | estado do túnel (relay + quick tunnel) |
| `POST` | `/api/auth/login` | `{password}` → cookie `auth_token` |
| `POST` | `/api/auth/reset-password` | **apaga** o hash (reset, não rotação) |

Contrato de autenticação:

- `POST /api/auth/login` com `{"password":"…"}` → `set-cookie: auth_token=<JWT>`.
- `GET`/`PATCH /api/settings` exigem o cookie `auth_token`.
- As rotas `/v1/*` exigem `Authorization: Bearer <NINEROUTER_API_KEY>`.

---

## 13. Referência dos scripts

| Script | O que faz |
| :--- | :--- |
| `tools/lib/venice-env.sh` | carregador compartilhado do `.env` (`set -a; source`) + `strip_quotes` |
| `tools/9router-systemd.sh` | gera/instala/remove a unit systemd (`install` \| `status` \| `uninstall`) |
| `tools/wait-tunnel.sh` | força e aguarda o túnel nativo (`enable` \| `wait` \| `--status`) |
| `tools/probe-models.sh` | sonda latência + HTTP + tool calling do catálogo |
| `tools/sync-catalog.sh` | sincroniza `providers.9router.models` do `opencode.json` com o catálogo vivo (`--apply`, `--only`, `--refresh`, `--prune`) |
| `tools/install-command.sh` | instala/remove os comandos globais `/refresh_models_9router` e `/auto_select_models_oh_my_opencode_slim` |
| `tools/sync-models.sh` | distribui os modelos aprovados pela sonda entre os agentes do `oh-my-opencode-slim` |
| `tools/opencode-service.sh` | garante o daemon do OpenCode com o env do provider |

Todos são **zsh**, idempotentes, e leem a configuração do `.env` — nenhum
host, usuário ou URL real está hardcoded.

---

## 14. Troubleshooting

| Sintoma | Causa provável | Solução |
| :--- | :--- | :--- |
| `Error: API key required for remote API access` | daemon nasceu sem o env | `zsh tools/opencode-service.sh` |
| `404` em `/v1/models` | `baseURL` sem `/v1` | corrija `NINEROUTER_BASE_URL` |
| `401` em `/v1/*` | chave ausente/errada | confira `NINEROUTER_API_KEY` |
| provider responde agora mas quebra após um restart | o env estava só **herdado** do shell, não gravado no `service.json` | `zsh tools/opencode-service.sh` (o `--check` só valida o processo vivo) |
| `403`/`503` no tunnel após `enable` | relay ainda propagando | `zsh tools/wait-tunnel.sh wait` |
| `ssh` pedindo passphrase em shell não interativo | askpass não configurado | refaça a [Fase 0 local](#4-fase-0--local-ssh-não-interativo) |
| `Permit denied` no `sudo -n` | sem sudo NOPASSWD | ajuste as sudoers no servidor |
| lockout no login do 9router | 4 tentativas falhas | aguarde o cooldown; não repita |
| Editou o config e nada muda | daemon não reiniciado | `opencode service restart` |
| `unit` não sobe | `.env` do servidor ausente | `EnvironmentFile` falha fechada — recrie o `~/.9router/.env` |
| modelo existe no `/v1/models` mas não em `/models` | `providers.9router.models` desatualizado (o OpenCode não descobre modelos de provedor custom) | `/refresh_models_9router` (ou `zsh tools/sync-catalog.sh --apply`) |
| `/refresh_models_9router` ou `/auto_select_models_oh_my_opencode_slim` não aparecem no TUI | comando não instalado/descoberto | `zsh tools/install-command.sh` e confirme os `.md` em `~/.config/opencode/commands/` |
| `/refresh_models_9router` falha com "chave ausente" | sem `.env` e sem a cópia canônica | recrie `~/.config/venice-stack/9router.env` (600) |

---

## Repositório

```
.env.example                        # placeholders + instruções (versionado)
.gitignore
AGENTS.md                           # runbook: fases, regras não-negociáveis
PLAN.md                             # registro de execução (divergências D1–D12)
README.md                           # este arquivo
tools/lib/venice-env.sh             # carregador do .env
tools/9router-systemd.sh            # gerador da unit systemd
tools/wait-tunnel.sh                # controle do túnel nativo
tools/probe-models.sh               # sonda de modelos
tools/sync-catalog.sh               # opencode.json <- catálogo vivo do 9router
tools/install-command.sh            # comandos globais (refresh + auto-select)
tools/sync-models.sh                # distribui modelos aprovados entre os agentes
tools/opencode-service.sh           # env do daemon do OpenCode
```

Gitignored: `.env` (mode `600`), `probe.jsonl`, `*.log`, `*.bak`, `*.sqlite`.

> **Antes de qualquer push para um remoto público**, rode a varredura de
> segredos: nenhum host, usuário, senha ou URL real pode existir no repositório
> **nem no histórico**.
