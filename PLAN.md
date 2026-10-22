# PLAN.md — Execução das Fases 0 a 5 (9router + OpenCode)

**Servidor:** `${VENICE_STACK_SSH_HOST}` (`${VENICE_STACK_SSH_USER}`) · **Data:** 2026-10-22 (UTC) · **Fases:** 0 — Preparação/Hardening · 1 — OpenCode + provider 9router · 2 — oh-my-opencode-slim · 3 — Sondagem de modelos · 4 — Atribuição aos agentes · 5 — Verificação final
**Status da Fase 0:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 1:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 2:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 3:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 4:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 5:** ✅ CONCLUÍDA E VERIFICADA

---

## 0. Resumo executivo

A Fase 0 foi executada integralmente. O serviço já estava instalado e **rodando**, mas com **o túnel nativo caído** e **hardening incompleto**. Três defeitos foram encontrados e corrigidos:

| # | Defeito | Impacto | Correção |
|---|---------|---------|----------|
| B1 | `ensure-tunnel.sh` era gerado com escapes literais (`\$(...)`), quebrando o bash | Túnel **nunca** voltava após restart do serviço | Heredoc corrigido em `tools/9router-systemd.sh` |
| B2 | `INITIAL_PASSWORD` do `.env` **não correspondia** ao hash bcrypt do admin no banco | Senha inicial **não era a senha real** do dashboard | Rotação da senha no banco + `.env` sincronizado |
| B3 | `JWT_SECRET` nunca foi rotacionado (backup de 03:47 == valor em uso) | Segredo de assinatura de sessão reutilizado do dia da instalação | Rotação para 64 hex aleatórios |

Estado final: serviço `active`, túnel `running:true`, API key **obrigatória** em toda rota `/v1/*` via túnel, porta `20128` **não exposta**.

---

## 1. Fase 0.0 — Autenticação SSH não-interativa (local)

### O que foi feito

Reescrito `~/.zshenv` (backup em `~/.zshenv.bak.20261022-011932`) conforme o AGENTS.md, com o guard `VENICE_STACK_SSH_READY`:

- Askpass gerado pelo próprio `.zshenv` em `~/.ssh/askpass-venice.sh` (`chmod 700`).
  `~/.ssh/askpass.sh` virou **symlink** para o novo arquivo (compatibilidade, sem duplicar o segredo).
- Agente SSH com **socket fixo** (`~/.ssh/agent.sock`) + `flock`, em vez do arquivo `.env` de agente sugerido no AGENTS.md (motivo no §5, divergência D3).
- O guard é **por processo**: cada shell novo reexecuta o bloco e reergue o agente se ele morreu.

### Verificações

| Teste | Resultado |
|---|---|
| `ssh-add -l` | `256 SHA256:ePyRbJo861HCjz1QO9XaBK68N91E4T61Z3DrvB5+GH8 ... (ED25519)` ✅ |
| `ssh -o BatchMode=yes ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST} 'echo SSH_OK'` | `SSH_OK` ✅ |
| `zsh -c 'ssh -o BatchMode=yes ... "echo NONINTERACTIVE_OK"'` | `NONINTERACTIVE_OK` ✅ |
| Agente morto → novo shell reergue | `REVIVED_OK` ✅ |
| 5 shells em paralelo (corrida de `ssh-agent`) | 5/5 conexões ✅ |

---

## 2. Fase 0.1 — Diagnóstico do servidor

```
Linux ${VENICE_SERVER_HOSTNAME} 7.0.0-1013-oracle #13-Ubuntu SMP PREEMPT
node v22.22.1 · npm 9.2.0 · nproc 2 · Mem 951Mi · / 45G (9% usado)
```

- 9router **v0.5.104** instalado globalmente em `/usr/local/lib/node_modules/9router/app`.
- `DATA_DIR` = `/home/${VENICE_STACK_SSH_USER}/.9router` (⚠️ não é `~/9router` — ver divergência D1).
- `~/.9router/db/data.sqlite` · driver `better-sqlite3` · 5575 modelos / 24 providers no catálogo.
- 12 conexões de provider ativas (gemini-cli, github, antigravity).
- `sudo -n` funciona sem senha (NOPASSWD).

### Mapa de autenticação (extraído do `middleware.js` compilado)

| Grupo | Rotas | Regra |
|---|---|---|
| `aK` — API remota | `/v1`, `/v1beta`, `/api/v1`, `/api/v1beta`, `/codex`, `/responses` | Exige **API key** (ou token CLI / peer loopback) |
| `aM` — local-only | `/api/tunnel/enable`, `/api/tunnel/disable`, `/api/auth/reset-password`, `/api/mcp/`… | Exige **token CLI** (rota `/api/tunnel/enable` confirmou `403` externo) |
| `aL` — sensíveis | `/api/shutdown`, `/api/settings/database`, `/api/version/update`… | Exige token CLI **ou** sessão de dashboard |
| `aJ` — públicas | `/api/health`, `/api/version`, `/api/auth/login`… | Livre |

Peers **loopback** (`aN = {localhost, 127.0.0.1, ::1}`) são dispensados da API key — por isso `/v1/models` responde `200` de dentro do servidor, mas `401` de fora.

---

## 3. Fase 0.2 — Unidade systemd

A unit `9router.service` já existia e estava `active`. Foi **reinstalada** por `tools/9router-systemd.sh install` após a correção do helper (B1).

```
/etc/systemd/system/9router.service   (root:root 644, 1823 bytes)
enabled · active · NRestarts=0 · MemoryCurrent=151 MB (limite 600 MB)
```

Pontos relevantes da unit:

- `EnvironmentFile=/home/${VENICE_STACK_SSH_USER}/.9router/.env` → **falha fechada**: `.env` ausente = serviço não sobe.
- `Environment=HOSTNAME=127.0.0.1` e `PORT=20128` → bind só em loopback.
- `ExecStartPost` chama `ensure-tunnel.sh` em background (nunca falha a unit).
- Sandbox: `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadWritePaths=/home/${VENICE_STACK_SSH_USER}/.9router`, `NoNewPrivileges`, `MemoryMax=600M`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`.

### B1 — Causa raiz do túnel caído

`tools/9router-systemd.sh` gerava o helper com um heredoc **quoted** (`<<'HELPER_EOF'`), onde `\$` **não** é interpretado. O arquivo gravado continha `\$` literal:

```
/home/${VENICE_STACK_SSH_USER}/.9router/bin/ensure-tunnel.sh: line 12: syntax error near unexpected token `('
/home/${VENICE_STACK_SSH_USER}/.9router/bin/ensure-tunnel.sh: line 12: `for _ in \$(seq 1 60); do'
```

Resultado: o helper morria antes de forçar o túnel → **todo restart do serviço deixava o túnel caído**.

**Correção:** removidos os escapes (o heredoc é quoted, então `$` literal é o que deve chegar ao arquivo) e acrescentado:
- espera pelo gateway ficar pronto antes de forçar o enable;
- polling do `/api/tunnel/status` até `"running":true` (máx. 90 s).

Validação: `bash -n` → OK · sem escapes literais → OK · log mostra `gateway pronto` → enable disparado.

---

## 4. Fase 0.3 — Hardening

Executado **antes** de forçar o túnel, conforme exigido.

### Backups (regra do AGENTS.md)

| Arquivo | Backup |
|---|---|
| `.env` | `~/.9router/.env.bak.20261022-042023` (600) |
| `jwt-secret` | `~/.9router/backups-jwt-secret.20261022-042023.bak` (600) |
| `auth/cli-secret` | `~/.9router/backups-cli-secret.20261022-042023.bak` (600) |
| `db/data.sqlite` | `~/.9router/db/backups/data.sqlite.20261022-042023.bak` (via API `.backup()` do SQLite, consistente com WAL) |

### Alterações aplicadas

| Item | Antes | Depois |
|---|---|---|
| `REQUIRE_API_KEY` | `true` | `true` (mantido — ver D4) |
| `INITIAL_PASSWORD` | 31 chars, **desincronizada do banco** | 32 chars aleatórios (`secrets.token_urlsafe(24)`), **idênticos** aos do banco |
| `JWT_SECRET` | `ad2f6427…e5626` (valor da instalação, 14/Out) | 64 hex aleatórios novos |
| `~/.9router/jwt-secret` | idem ao antigo | sincronizado com o novo (fallback do app) |
| `settings.data.password` (banco) | bcrypt `$2b$10$` desconhecido | bcrypt `$2b$10$` do novo segredo |

A senha do admin foi reescrita **no banco** (`bcrypt`, custo 10, prefixo `$2b$` — mesmo formato do app), com o serviço parado para evitar corrida de escrita. O `.env` e o banco ficaram consistentes.

### Verificações de hardening

| Teste | Esperado | Resultado |
|---|---|---|
| `GET /api/health` | 200 | `200` ✅ |
| `POST /api/auth/login` com a senha nova | 200 + cookie | `200` + `Set-Cookie: auth_token=<JWT>` ✅ |
| `POST /v1/chat/completions` **sem** key | 401 | `401` `Missing API key` ✅ |
| `POST /v1/chat/completions` com key **inválida** | 401 | `401` `Invalid API key` ✅ |
| `POST /v1/chat/completions` com key **válida** | passa do auth | chega ao provider (503 upstream — ver nota) ✅ |
| `GET /api/auth/status` | `requireLogin=true` | `requireLogin=True hasPassword=True authMode=password` ✅ |

> **Nota (não é falha da Fase 0):** com key válida, `gc/gemini-3.1-pro-preview` respondeu `503 [403] (reset after 10s)`. O 403 é do **provedor upstream** (cota/token do gemini-cli), não da camada de autenticação do 9router — a requisição atravessou o auth e chegou ao modelo. O mapeamento de providers/modelos é escopo da **Fase 3**.

### Segredos gerenciados

Gravados localmente **fora do repositório**, em `~/.config/venice-stack/9router.env` (`chmod 600`):

```
NINEROUTER_BASE_URL=https://${NINEROUTER_RELAY_HOST}
NINEROUTER_API_KEY=…
NINEROUTER_ADMIN_PASSWORD=…
NINEROUTER_JWT_SECRET=…
```

`~/.config/venice-stack/9router.env` foi adicionado ao `.gitignore` do repositório (junto de `*.env`, `*.bak`, `*.sqlite`, `probe.jsonl`).

---

## 5. Fase 0.4 — Túnel nativo

O túnel é **do 9router** e intocável: nada de `cloudflared`/`ngrok` paralelo. Só se usa a rota nativa `POST /api/tunnel/enable` (local-only, token CLI).

### `tools/wait-tunnel.sh`

Restaurado do histórico git (estava deletado na working tree — ver D5) e corrigido:

- **B6:** `code="$(curl … || echo 000)"` produzia `"000\n000"` em falha de rede, quebrando a comparação. Agora `code="${code:-000}"`.
- **Acrescentado:** `assert_tunnel_is_locked()` — valida que `/v1/models` **sem** key responde `401`/`403` pelo túnel público (detecta catálogo exposto).

### Execução

```
[wait-tunnel] forcando o tunel nativo em ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST} (POST /api/tunnel/enable) ...
[wait-tunnel] AVISO: a rota /api/tunnel/enable retornou: {"error":"Health check timeout after 60000ms"}
[wait-tunnel] AVISO: (falso negativo conhecido: propagacao do relay > 60s). Validando pelo status real...
[wait-tunnel] aguardando o tunel responder (timeout 240s, intervalo 3s)...
[wait-tunnel] tunel NOVO: https://${NINEROUTER_RELAY_HOST}
[wait-tunnel] resposta: HTTP 200  ->  tunel ativo
TUNNEL_URL=https://${NINEROUTER_RELAY_HOST}
TUNNEL_DIRECT_URL=https://${NINEROUTER_TUNNEL_HOST}
[wait-tunnel] seguranca OK: https://${NINEROUTER_RELAY_HOST}/v1/models sem key -> HTTP 401 (exige API key)
```

O `Health check timeout` da rota é um **falso negativo conhecido**: o relay `abc-tunnel.us` propaga o upstream em > 60 s. O script valida pelo `/api/tunnel/status` real, não pela resposta da rota.

### Estado do túnel

```
enabled=true  running=true  shortId=eislqu
publicUrl=https://${NINEROUTER_RELAY_HOST}        (relay estável)
tunnelUrl=https://${NINEROUTER_TUNNEL_HOST}   (quick tunnel, efêmero)
cloudflared: 1 processo ativo (/home/${VENICE_STACK_SSH_USER}/.9router/bin/cloudflared)
```

> O `tunnelUrl` do *quick tunnel* muda a cada `enable`; o `publicUrl` (`${NINEROUTER_RELAY_HOST}`) é o endpoint **estável** e é o que deve ser usado na Fase 1.

---

## 6. Verificação externa (a partir da máquina local, via túnel)

| Requisição | Status | Interpretação |
|---|---|---|
| `GET /api/health` | `200` | público por design ✅ |
| `GET /api/version` | `200` | público por design ✅ |
| `GET /v1/models` **sem** key | `401` | **exige API key** ✅ |
| `POST /v1/chat/completions` **sem** key | `401` | **exige API key** ✅ |
| `GET /v1/models` com key **válida** | `200` | key aceita ✅ |
| `GET /v1/models` com key **inválida** | `401` | key validada ✅ |
| `GET /dashboard` | `307` | redireciona para login ✅ |
| `POST /api/tunnel/enable` externo | `403` | rota local-only barrada ✅ |
| `http://${VENICE_STACK_SSH_HOST}:20128/api/health` | `000` | **porta 20128 não exposta** ✅ |
| `ss -ltnp` | `127.0.0.1:20128` | bind só em loopback ✅ |

---

## 7. Divergências entre o AGENTS.md e a realidade (documentadas, não "corrigidas" no plano)

| ID | AGENTS.md diz | Realidade | Tratamento |
|---|---|---|---|
| **D1** | Hardening em `~/9router/.env` | O app usa `DATA_DIR=/home/${VENICE_STACK_SSH_USER}/.9router` → `.env` em `~/.9router/.env`. Não existe `~/9router` | Hardening aplicado no caminho **real** (`~/.9router/.env`), o mesmo lido pelo `EnvironmentFile=` da unit |
| **D2** | Bloco `.zshenv` usa `ssh-add "${HOME}/ssh/id_ed25519"` | Falta o ponto: `~/.ssh/id_ed25519` — o `ssh-add` falharia em silêncio e a chave não subiria | Corrigido para `${HOME}/.ssh/id_ed25519` |
| **D3** | Agente via `ssh-agent -s > ~/.ssh/venice-agent.env` | `.env` de agente fica obsoleto e há corrida entre shells concorrentes | Mantido o socket fixo `~/.ssh/agent.sock` + `flock` (já testado contra race) |
| **D4** | `REQUIRE_API_KEY=true` no `.env` | A variável **não existe** no 9router v0.5.104 — a exigência de API key é **incondicional** em `/v1/*` | Mantida no `.env` (compatibilidade com o plano); a segurança não depende dela |
| **D5** | "9router desligado" | Estava **instalado e rodando**; o que caía era o **túnel** (B1) e o hardening estava incompleto (B2/B3) | Diagnóstico corrigido pelo estado real |
| **D6** | `tools/wait-tunnel.sh` a criar | O arquivo **existia no histórico git** (`85af592`) e havia sido removido da working tree | Restaurado do git e corrigido (B6), em vez de reescrito do zero |

---

## 8. Estado final

```
Servidor   9router.service  enabled / active   (NRestarts=0)
Túnel      running=true   https://${NINEROUTER_RELAY_HOST}
Auth       API key obrigatória em /v1/* (externo) · admin com senha rotacionada
Rede       20128 em 127.0.0.1 apenas · acesso externo só pelo túnel
Backups    .env / jwt-secret / cli-secret / data.sqlite  (20261022-042023)
Segredos   ~/.config/venice-stack/9router.env  (chmod 600, fora do repo)
Local      ~/.zshenv com askpass + agente SSH resiliente
```

---

## 9. Próximos passos (Fase 1+)

1. **Fase 1** — exportar `NINEROUTER_API_KEY` no `~/.zshenv` e apontar `~/.config/opencode/opencode.json` para `https://${NINEROUTER_RELAY_HOST}`.
2. **Fase 3** — sondar modelos com `tools/probe-models.sh`; observar o `503 [403]` do `gemini-cli` (cota dos providers) e priorizar providers saudáveis.
3. Manter `zsh tools/wait-tunnel.sh` no start do OpenCode (idempotente) para garantir o túnel em caso de restart do serviço.

---

## 10. Log de execução

```
2026-10-22 01:19  ~/.zshenv reescrito + askpass-venice.sh criado (700) + symlink askpass.sh
2026-10-22 01:19  ssh-add -l / SSH_OK / NONINTERACTIVE_OK / revivida + 5x concorrência  ✅
2026-10-22 01:17  tools/ restaurados do git (85af592) e corrigidos (B1, B6)
2026-10-22 04:20  BACKUP .env + jwt-secret + cli-secret + data.sqlite (20261022-042023)
2026-10-22 04:20  rotação: INITIAL_PASSWORD (32) + JWT_SECRET (64 hex) + bcrypt no banco
2026-10-22 04:21  service start → active; login com senha nova → 200
2026-10-22 04:21  V3/V4: sem key → 401 | key inválida → 401 | key válida → chega ao provider
2026-10-22 04:23  systemctl stop/start → ensure-tunnel.sh regenerado CORRETO (bash -n OK)
2026-10-22 04:24  ensure-tunnel: gateway pronto → POST /api/tunnel/enable → running=true
2026-10-22 04:25  zsh tools/wait-tunnel.sh → relay público HTTP 200 + /v1/models 401  ✅
2026-10-22 04:26  verificação externa completa (401s, 403 local-only, porta 20128 fechada)
2026-10-22 04:27  ~/.config/venice-stack/9router.env gravado (600) + .gitignore criado
2026-10-22 04:31  FASE 1: NINEROUTER_BASE_URL + NINEROUTER_API_KEY no ~/.zshenv (600); .zshrc intocado
2026-10-22 04:32  FASE 1: validação do relay — streaming SSE ✅ + tool_call get_weather{"city":"Paris"} ✅
2026-10-22 04:33  FASE 1: opencode.json — provider 9router (providers, V2) com 103 modelos do catálogo vivo
2026-10-22 04:34  FASE 1: migração da chave depreciada `provider` → `providers` (schema V2)
2026-10-22 04:34  FASE 2: install --no-tui --background-subagents=yes --background-subagents-target=~/.zshenv ✅
2026-10-22 04:34  FASE 2: bloco background-subagents nas linhas 83-86 do ~/.zshenv; .zshrc NÃO tocado
2026-10-22 04:35  FASE 2: doctor → ok: true (preset "openai") ✅
2026-10-22 04:36  FASE 2: opencode models → 103 modelos 9router/* ✅
2026-10-22 04:37  B4: daemon (pid 8777,started 23:49) sem NINEROUTER_API_KEY → opencode run falha
2026-10-22 04:37  B4: --standalone (servidor privado) responde OK → configuração OK, env do processo que não
2026-10-22 04:38  B4: tools/opencode-service.sh criado (reconcilia service.json env + sobe o daemon)
2026-10-22 04:39  B4: opencode service set env <KEY> <VALUE> — env persistido no service.json (mode 600)
2026-10-22 04:40  B4: daemon novo (pid 8777 → 124894) com env completo → opencode run responde OK ✅
2026-10-22 04:41  VERIFICAÇÃO FINAL: doctor ok · 103 modelos 9router/* · opencode run OK
2026-10-22 04:42  VERIFICAÇÃO FINAL: tool calling real (shell → FASE2_TOOL_OK) pelo loop do agente ✅
2026-10-22 04:43  tools/opencode-service.sh --check → HEALTHY, idempotente (exit 0)
```

### Estado do repositório

| Arquivo | Mudança |
|---|---|
| `tools/9router-systemd.sh` | restaurado + B1 corrigido (heredoc) + polling `running:true` |
| `tools/wait-tunnel.sh` | restaurado + B6 corrigido + `assert_tunnel_is_locked()` |
| `PLAN.md` | este documento |
| `.gitignore` | novo — impede versionar segredos/artefatos |
| `AGENTS.md` | ⚠️ modificação **pré-existente** à esta sessão (reescrita condensada) — deixada sem commit para revisão do responsável |

---

## 11. Fase 1 — OpenCode apontado para o provider 9router

### 11.1 Variáveis de ambiente — `~/.zshenv` (nunca `~/.zshrc`)

A regra do AGENTS.md é estrutural, não cosmeticamente: o OpenCode é executado como
`zsh -c` (não-interativo), e `~/.zshrc` **só** é lido por shells interativos. Um
export em `.zshrc` seria invisível para o servidor do OpenCode.

| Variável | Valor | Origem |
|---|---|---|
| `NINEROUTER_BASE_URL` | `https://${NINEROUTER_RELAY_HOST}/v1` | relay **estável** do túnel nativo |
| `NINEROUTER_API_KEY` | chave de 35 chars | `~/.config/venice-stack/9router.env` (mode 600) |

> O relay `abc-tunnel.us` é o endereço duradouro. A URL `trycloudflare` que o
> 9router imprime a cada `POST /api/tunnel/enable` **muda** a cada enable e
> nunca deve ser gravada em config.

Verificações:

```
zsh -c 'echo $NINEROUTER_BASE_URL'      → https://${NINEROUTER_RELAY_HOST}/v1
zsh -c 'echo ${#NINEROUTER_API_KEY}'    → 35
grep -c NINEROUTER ~/.zshrc             → 0        (mtime 2025-03-20, intocado)
stat -c %a ~/.zshenv                    → 600
```

### 11.2 `~/.config/opencode/opencode.json` (mode 600)

| Campo | Valor | Motivo |
|---|---|---|
| `providers` (plural) | objeto de providers | chave correta no schema V2 |
| `providers.9router.package` | `@opencode/ai/providers/openai-compatible` | runtime OpenAI-compatible |
| `providers.9router.settings.baseURL` | `https://${NINEROUTER_RELAY_HOST}/v1` | relay público |
| `providers.9router.settings.apiKey` | `{env:NINEROUTER_API_KEY}` | **segredo só no `~/.zshenv`** |
| `providers.9router.env` | `["NINEROUTER_API_KEY"]` | fallback de resolução do credential |
| `providers.9router.models` | **103** modelos | gerados do catálogo vivo `/v1/models` |
| `settings.chunkTimeout` / `headerTimeout` | `600000` ms | relays LLM demoram; o default (5s) corta o stream |
| `model` (raiz) | `9router/ag/claude-sonnet-4-6` | default verificado com tool calling |

Os 103 modelos foram **gerados programaticamente** do catálogo vivo (via relay,
com a API key), com `limit` (context/output) e `capabilities` reais — sem
digitação manual, sem erro de transcrição. Todos os 103 declaram `tools: true`.
Chaves de topo do arquivo: `$schema`, `model`, `providers`, `plugin`, `lsp`.

### 11.3 Validação do endpoint antes de configurar (streaming + tools)

Feita direto contra o relay público, com `stream:true` e uma função `get_weather`:

```
tool_calls[0].function.name      → get_weather
tool_calls[0].function.arguments → {"city":"Paris"}
finish_reason                    → tool_calls
```

Sem isso, uma configuração de provider pode parecer correta e falhar só quando
o agente tenta usar uma ferramenta.

### 11.4 Migração `provider` → `providers` (V2)

O arquivo pré-existente continha `{"provider": {}}`. O schema V2
(`https://opencode.ai/config.json`) marca `provider` (singular) como
`deprecated: true` e `providers` (plural) como o campo correto:

```
root keys: ..., plugin, plugins, provider, providers, ...
--- provider  → deprecated: True
--- providers → deprecated: None
```

A chave depreciada foi **removida** e o conteúdo migrado para `providers`.

---

## 12. Fase 2 — `oh-my-opencode-slim`

### 12.1 Comando executado

```bash
npx oh-my-opencode-slim@latest install \
  --no-tui \
  --background-subagents=yes \
  --background-subagents-target=${HOME}/.zshenv
```

`--background-subagents-target` **não** está no comando do AGENTS.md — foi
adicionado por causa da divergência **D7** (ver §13). O instalador, sem esse
flag, escreve em `~/.zshrc` (o próprio instalador sugere `source ~/.zshrc` no
passo 4 do "Next steps"), o que violaria a regra do próprio AGENTS.md.

### 12.2 O que o instalador escreveu

| Arquivo | Conteúdo |
|---|---|
| `~/.config/opencode/opencode.json` | `plugin: ["oh-my-opencode-slim"]` + `lsp: true` (merge preservou `providers`) |
| `~/.config/opencode/tui.json` | `plugin: ["oh-my-opencode-slim"]` (badge de versão no TUI) |
| `~/.config/opencode/cli.json` | settings de CLI |
| `~/.config/opencode/oh-my-opencode-slim.json` | `preset: "openai"` + 2 presets gerados |
| `~/.zshenv` (linhas 83–86) | `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` + `OPENCODE_ENABLE_EXA=1` |

O merge foi verificado: as chaves `providers` (escritas antes da instalação) e
`plugin`/`lsp` (escritas pelo instalador) coexistem no mesmo arquivo.

### 12.3 `doctor`

```
$ npx oh-my-opencode-slim@latest doctor
Project: ${HOME}/wp/venice-stack
[user] ${HOME}/.config/opencode/oh-my-opencode-slim.json ✓
[project] No config file found
[preset] openai ✓

$ npx oh-my-opencode-slim@latest doctor --json
{ "ok": true, "configs": [...], "presetCheck": { "preset": "openai", "ok": true } }
```

> **Limite do `doctor`** (divergência **D9**): ele valida apenas *presença* do
> arquivo de config e do preset. Ele **não** checa se o provider resolve, se a
> API key está no ambiente do processo, nem se o modelo responde. Por isso a
> Fase 1 foi validada separadamente (seção 13).

---

## 13. Defeito B4 — o serviço em background do OpenCode herda env obsoleto

### 13.1 Diagnóstico

O OpenCode V2 é cliente-servidor: um daemon compartilhado (`opencode serve
--service`) responde por sessão, plugins e providers. Esse daemon é
**daemonizado** (`PPID=1`) e **herda o ambiente do processo que o iniciou** —
que é congelado no `exec`.

```
pid 8777  ppid 1     started Wed Oct 21 23:49:22  opencode.exe serve --service
pid 118637 ppid 103509 started Thu Oct 22 01:31:21  opencode   (TUI, OPENCODE_CALLER=vscode)
~/.zshenv modificado em: 2026-10-22 01:34:28
```

O daemon nasceu às **23:49**, quase duas horas **antes** do `~/.zshenv` receber
o export. Consequência observada:

```
$ opencode run --model 9router/ag/claude-sonnet-4-6 "Responda APENAS: OK"
> orchestrator · ag/claude-sonnet-4-6
Error: API key required for remote API access
```

O mesmo comando com um servidor privado (`--standalone`, que **não** usa o
daemon) responde normalmente — o que isola a causa no ambiente do processo, e
não na configuração:

```
$ opencode run --standalone --model 9router/ag/claude-sonnet-4-6 "..."
> orchestrator · ag/claude-sonnet-4-6
OK
```

### 13.2 Correção — persistir o env **no próprio serviço**

Reiniciar o daemon a partir de um shell com o `~/.zshenv` carregado resolveria
**uma vez**, mas não é robusto: o daemon pode ser iniciado por qualquer
processo — e observamos a extensão do VS Code (`OPENCODE_CALLER=vscode`) que
o inicia com env mínimo. O próprio binário do OpenCode expõe a solução certa:

```
opencode service set env <KEY> <VALUE>     # persiste no service.json (mode 600)
opencode service get env <KEY>             # leitura
```

O `set env` para o daemon atual; o start seguinte o recolhe com essas
variáveis, **independente de quem o iniciou**. O `~/.zshenv` continua sendo a
fonte canônica (regra do AGENTS.md); o `~/.config/opencode/service.json`
(mode 600, fora do repo) é a cópia de trabalho do daemon.

Para tornar isso **idempotente e auto-healing** (regra do AGENTS.md), foi criado
`tools/opencode-service.sh`, que detecta o daemon com env obsoleto, reconcilia
o `service.json` com o `~/.zshenv` e sobe o daemon:

```bash
zsh tools/opencode-service.sh          # reconcilia + garante env + service healthy
zsh tools/opencode-service.sh --check  # só diagnostica (exit != 0 se unhealthy)
zsh tools/opencode-service.sh --probe  # diagnostica + inferência real no provider
```

> ⚠️ O daemon herda o ambiente de quem o iniciou. Se ele for iniciado por um
> processo **sem** `~/.zshenv` no ambiente (ex.: a extensão do VS Code, que
> observamos com `OPENCODE_CALLER=vscode` e env mínimo), ele nasce sem a chave.
> Rodar o OpenCode a partir de um terminal `zsh` resolve; o
> `tools/opencode-service.sh` é a rede de segurança.

---

## 14. Divergências D7–D9 (Fases 1 e 2)

| ID | AGENTS.md / docs dizem | Realidade | Tratamento |
|---|---|---|---|
| **D7** | Fase 2: `install --no-tui --background-subagents=yes` | O instalador escreve o bloco de env em **`~/.zshrc`** por padrão (e sugere `source ~/.zshrc`), contrariando a regra do **próprio** AGENTS.md ("exports no `.zshenv`") | Adicionado `--background-subagents-target=${HOME}/.zshenv`. O bloco foi confirmado nas linhas 83–86 do `.zshenv`; `.zshrc` ficou intocado |
| **D8** | O plano cita `~/.config/opencode/opencode.json` sem especificar a forma do provider | O arquivo pré-existente usava `provider` (singular), **depreciado** no schema V2; a forma correta é `providers` (plural) | Migrado para `providers`; a chave depreciada foi removida |
| **D9** | Fase 2: "rodar o `doctor` para validar" | O `doctor` valida só *presença de config* e *preset*; não valida provider, credencial nem resposta do modelo | `doctor` executado (`ok: true`) **e** validação real acrescentada: streaming + tool calling via relay, `opencode models` (103 modelos), `opencode run` real |

---

## 15. Estado final (Fases 0–2)

```
Servidor   9router.service  enabled / active   (NRestarts=0)
Túnel      running=true   https://${NINEROUTER_RELAY_HOST}
Auth       API key obrigatória em /v1/* (externo) · admin com senha rotacionada
Rede       20128 em 127.0.0.1 apenas · acesso externo só pelo túnel
Backups    .env / jwt-secret / cli-secret / data.sqlite  (20261022-042023)
Segredos   ~/.config/venice-stack/9router.env  (chmod 600, fora do repo)

Local      ~/.zshenv (600)  askpass + agente SSH + NINEROUTER_* + OPENCODE_*
           ~/.zshrc  INTOCADO (mtime 2025-03-20, 0 ocorrências)
           ~/.config/opencode/opencode.json (600)  providers.9router + plugin + lsp
           ~/.config/opencode/oh-my-opencode-slim.json  preset "openai"
Provider   9router → @opencode/ai/providers/openai-compatible
           baseURL https://${NINEROUTER_RELAY_HOST}/v1 · apiKey {env:NINEROUTER_API_KEY}
           103 modelos declarados (todos com tools:true)
Plugin     oh-my-opencode-slim v3.0.5 (plugin + tui + lsp + presets)
Doctor     ok: true
Daemon     opencode serve --service  pid 124894  http://127.0.0.1:49374
           env: NINEROUTER_API_KEY + OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
           persistido em ~/.config/opencode/service.json (mode 600)
Inferencia opencode run --model 9router/ag/claude-sonnet-4-6 → OK
Tool call  opencode run → agente chamou a tool `shell` → FASE2_TOOL_OK ✅
```

---

## 16. Fase 3 — Sondagem de modelos (`tools/probe-models.sh`)

### 16.1 O script

Local, em `zsh`, mode 755, idempotente. Mede **latência** (ttfb e total), **código
HTTP** e **suporte a tool calling** (função `get_weather`) de cada modelo do
catálogo, gravando **uma linha JSON por modelo** em `probe.jsonl` (JSON Lines).

```
tools/probe-models.sh [--concurrency N] [--timeout S] [--repeat N]
                       [--out ARQUIVO] [--models LISTA] [--filter PADRÃO] [--append]
```

| Variável | Default | Papel |
|---|---|---|
| `NINEROUTER_BASE_URL` | `https://${NINEROUTER_RELAY_HOST}/v1` | relay público (**nunca** a porta 20128) |
| `NINEROUTER_API_KEY` | fallback `~/.config/venice-stack/9router.env` | credencial |
| `PROBE_CONCURRENCY` / `PROBE_TIMEOUT` / `PROBE_REPEAT` | 4 / 120 / 1 | ritmo da sonda |

Decisões de projeto:

- **`tool_choice: "auto"`**, conforme o AGENTS.md. Se o gateway responder
  HTTP 400 citando `tool_choice`, o script refaz a requisição **sem** ele e
  marca `tool_choice_dropped: true` — o que se mede é o *tool calling*, não o
  parâmetro.
- Cada worker grava num arquivo próprio em `$WORKDIR`; a concatenação final é
  feita em ordem de catálogo. Isso elimina interleaving de escrita entre
  processos paralelos.
- O `probe.jsonl` já está no `.gitignore` (regra de segredo/artefato).

### 16.2 Execução da sonda completa

```
zsh tools/probe-models.sh --concurrency 4 --timeout 120 --out probe.jsonl
```

103 modelos · latência mediana dos aprovados **2859 ms** · relatório tabular em
`/tmp/opencode/probe-full.log`.

| Métrica | Valor |
|---|---|
| Modelos sondados | 103 |
| **HTTP 200 + tool calling OK** | **36 (35,0 %)** |
| HTTP 200 (sem tool calling) | 0 — quem respondeu 200, respondeu com tool call |
| Latência mediana dos aprovados | 2859 ms (faixa 754 ms – 12,3 s) |

### 16.3 Cobertura por família

| Família | Prontos | Total | Leitura |
|---|---|---|---|
| `ag` (antigravity) | 7 | 25 | Claude 4.6 + Gemini 3.8 Flash + GPT-OSS |
| `cx` (codex) | 10 | 19 | GPT-5.6 Luna/Terra, GPT-6 Luna, auto-review, reserve |
| `gh` (github copilot) | 13 | 28 | GPT-4o/4.1/5.4-nano — **lentos** (5–12 s) |
| `oc` (free pool) | 6 | 12 | Mimo, Nemotron, DeepSeek, Big Pickle |
| `gc` (gemini-cli) | **0** | 7 | **morto** — cota/quota upstream (403) |
| `kimi` | **0** | 10 | **sem assinatura** (403 "current subscription does not…") |
| `mmf` | 0 | 1 | `mimo-auto` → 400 upstream |
| `teste` | 0 | 1 | `model_not_supported` (integrator `vscode-chat`) |

### 16.4 Taxonomia das 67 falhas

| Padrão | Qtd | Modelos (exemplos) | Causa real |
|---|---|---|---|
| `404 Requested entity was not found` | 18 | `ag/claude-opus-5-5*`, `ag/claude-sonnet-5-5*`, `ag/gemini-3.7-*`, `ag/gemini-4-argon-high` | **Não existem upstream** — o catálogo do 9router os anuncia, mas o provedor não os tem |
| `model_not_supported` / `not available for integrator` | 16 | `gh/claude-haiku-4.5`, `gh/gpt-6-luna`, `gh/kimi-k3-*`, `teste` | Recusados pelo provedor de destino |
| `403 (reset after …)` | 7 | `gc/*` | **Cota/quota** do gemini-cli (já observada na Fase 2) |
| `model is not supported` (codex) | 5 | `cx/gpt-6-astra*`, `cx/gpt-6-sol*`, `cx/gpt-5.6-sol*` | O codex não expõe esses nomes |
| `410 ModelDeprecated` | 2 | `oc/muse-spark-1.2/1.3-contributor-free` | Modelo aposentado |
| `403` (kimi) | 8 | `kimi/*` | Plano kimi sem assinatura ativa |

> **Conclusão central:** o catálogo de 103 modelos é **publicitário**, não
> operacional. Só 36 IDs respondem de fato. Toda atribuição de modelo nas
> fases seguintes **tem** que vir da sonda, não do catálogo.

### 16.5 Modelos aprovados (HTTP 200 + tool calling)

Os 11 que entraram na Fase 4, com latência medida:

| Modelo | Latência | ctx | Visão | Reasoning |
|---|---|---|---|---|
| `ag/claude-sonnet-4-6` | 1873 ms | 1 000 000 | ✅ | ✅ |
| `ag/claude-opus-4-6-thinking` | 2859 ms | 200 000 | ✅ | ✅ |
| `ag/gpt-oss-120b-medium` | 1063 ms | 128 000 | — | ✅ |
| `ag/gemini-3.8-flash` | 3878 ms | 1 048 576 | ✅ (+áudio/vídeo) | ✅ |
| `cx/gpt-5.6-luna` | 1507 ms | 272 000 | ✅ | ✅ |
| `cx/gpt-6-luna` | 2774 ms | 272 000 | ✅ | ✅ |
| `cx/gpt-5.6-terra` | 2749 ms | 272 000 | ✅ | ✅ |
| `oc/deepseek-v4.1-flash-free` | 1474 ms | 1 000 000 | ✅ | ✅ |
| `oc/nemotron-3.5-lightning-free` | 947 ms | 128 000 | — | ✅ |
| `oc/mimo-v2.6-flash-free` | 2846 ms | 1 048 576 | ✅ (+áudio/vídeo) | ✅ |
| `oc/nemotron-3.5-super-vl-free` | 2609 ms | 128 000 | ✅ | ✅ |

---

## 17. Fase 4 — Atribuição dos modelos aos papéis

### 17.1 Semântica do plugin (confirmada no schema, não na intuição)

Lida a partir do pacote instalado (`oh-my-opencode-slim` 3.0.5):
`oh-my-opencode-slim.schema.json` + `dist/config/constants.d.ts` +
`docs/council.md` + `docs/configuration.md`.

| Fato | Origem |
|---|---|
| `ALL_AGENT_NAMES = [orchestrator, explorer, oracle, designer, fixer, observer, council, councillor]` | `dist/config/constants.d.ts` |
| Formato **plano** `presets.<preset>.<role>` é válido (`oneOf` com 3 variantes; a flat não tem `required`) | schema JSON |
| `disabled_agents` default `["observer"]` — para habilitar o Observer: `disabled_agents: []` **+** modelo com visão | schema + README |
| `image_routing`: omitido resolve para `"auto"` se o Observer estiver habilitado, senão `"direct"` | `docs/configuration.md` |
| O **sintetizador** do council é um role normal: `presets.<preset>.council.model` | `docs/council.md` |
| Os **assentos** do council são separados: `council.presets.<preset>.<assento>.model` | `docs/council.md` + `src/config/council-schema.ts` |
| `model` de agente/assento aceita **string ou array** = cadeia de fallback ordenada | schema |
| `variant` = "reasoning effort: low/medium/high/max (provider-specific)" | `docs/configuration.md` |
| `fallback.maxRetries` (default 3) + `fallback.enabled` (default true) = switch para o próximo modelo da cadeia | `docs/configuration.md` |
| O assento `master` foi **removido** do schema | `src/config/council-schema.ts` |

### 17.2 Atribuição

`~/.config/opencode/oh-my-opencode-slim.json` → preset ativo **`9router`**
(antes: `openai`, que apontava para `openai/gpt-6-*` e `opencode-go/*` —
modelos **inexistentes** nesta conta).

| Papel | Primário | Fallback | Por quê |
|---|---|---|---|
| `orchestrator` | `ag/claude-sonnet-4-6` | `cx/gpt-5.6-luna` → `ag/gpt-oss-120b-medium` | Cérebro: 1,9 s, 1 M de ctx, visão+reasoning, e já é o `model` raiz do `opencode.json` |
| `oracle` | `ag/claude-opus-4-6-thinking` | `cx/gpt-6-luna` → `ag/gemini-3.8-flash` | **Único Opus** aprovado — melhor raciocínio medido; é consultivo, então a latência não pesa |
| `explorer` | `ag/gpt-oss-120b-medium` | `oc/nemotron-3.5-lightning-free` → `cx/gpt-5.6-luna` | Busca é o gargalo: 1,06 s, open-weights afinado para código |
| `designer` | `cx/gpt-5.6-luna` | `ag/gemini-3.8-flash` → `oc/deepseek-v4.1-flash-free` | Iteração de UI precisa de visão + resposta rápida (1,5 s) |
| `fixer` | `cx/gpt-6-luna` | `ag/claude-sonnet-4-6` → `ag/gpt-oss-120b-medium` | Cavalo de batalha de implementação: reasoning + visão, 272 k de ctx |
| `observer` | `ag/gemini-3.8-flash` | `oc/mimo-v2.6-flash-free` → `oc/nemotron-3.5-super-vl-free` | Leitor multimodal dedicado: `input` = text, **image, audio, video**, 1,048 M de ctx |
| `council` | `ag/claude-sonnet-4-6` | `cx/gpt-5.6-terra` → `ag/gemini-3.8-flash` | **Sintetizador**: precisa de 1 M de ctx para fundir as respostas dos 4 assentos |

Skills: `orchestrator` → `["*"]`; `oracle` → `["simplify"]`; demais → `[]`
(o council não tem tools).

### 17.3 Assentos do council (diversidade de família é o ponto)

4 assentos, um por família de modelo — Claude, GPT, DeepSeek, Gemini:

| Assento | Modelo | Prompt de papel |
|---|---|---|
| `architect` | `ag/claude-opus-4-6-thinking` | manutenibilidade, fronteiras, desenho de longo prazo |
| `reviewer` | `cx/gpt-5.6-luna` | bugs, casos de borda, modos de falha |
| `optimiser` | `oc/deepseek-v4.1-flash-free` | performance, latência, uso de recursos |
| `visual` | `ag/gemini-3.8-flash` | correção de UI/UX, acessibilidade, detalhe visual |

`council.default_preset: "default"`.

### 17.4 Decisões de robustez

- **Cadeias de fallback em todos os papéis.** A Fase 3 provou que o 9router é
  instável por naturezas diferentes (404 de catálogo, 403 de cota, 503 de
  upstream, timeout). O `model` como array é a cadeia de failover nativa do
  plugin (`fallback.maxRetries` = 3, compartilhado na cadeia). Um único modelo
  por papel transformaria qualquer 503 upstream em turno perdido.
- **Nenhum `variant` declarado.** O catálogo do 9router **não expõe níveis de
  reasoning effort**; o `variant` seria um valor inventado enviado ao
  upstream. Onde o nível importa, ele já está no ID do modelo
  (`ag/gemini-3.8-flash-high` vs `-medium` vs `-low`).
- **`disabled_agents: []`** para habilitar o Observer, e **`image_routing: "auto"`**.
- **Presets antigos removidos** (`openai`, `opencode-go`): apontavam para modelos
  inexistentes nesta conta e ficariam quebrados se alguém os selecionasse.
- **Backup** de `opencode.json` e `oh-my-opencode-slim.json` em
  `~/.config/opencode/backups/*.20261022-091707.bak` (mode 600) antes da
  escrita.

---

## 18. Fase 5 — Verificação final

### 18.1 Verificações exigidas

```
npx oh-my-opencode-slim@latest doctor
opencode models
```

| Verificação | Resultado |
|---|---|
| `doctor` (texto) | `[preset] 9router ✓` · exit 0 |
| `doctor --json` | `{"ok": true, …, "presetCheck": {"preset": "9router", "ok": true}}` |
| `opencode models` | **113** modelos: 103 do `9router` + 10 do `opencode` |
| Modelos atribuídos presentes em `opencode models` | **11 / 11** ✅ |
| JSON Schema do plugin (draft 2020-12) sobre o config | **VÁLIDO** |
| Validação estrutural própria (roles, assentos, refs, visão do observer) | **OK** |

### 18.2 Verificação funcional real (não só configuração)

Cada papel foi exercitado de verdade e o **modelo efetivo de cada sessão** foi
lido de volta pela API (`GET /api/session/{id}/message`):

| Agente | Modelo efetivamente usado | Teste |
|---|---|---|
| `orchestrator` | `9router/ag/claude-sonnet-4-6` | turno real → `ORCH_OK` |
| `explorer` | `9router/ag/gpt-oss-120b-medium` | delegação: listar `.sh` em `tools/` → `EXPLORER_OK` |
| `oracle` | `9router/ag/claude-opus-4-6-thinking` | sessão registrada pela delegação do council |
| `designer` | `9router/cx/gpt-5.6-luna` | proposta de paleta + hierarquia de layout |
| `fixer` | `9router/cx/gpt-6-luna` | criou script, aplicou `chmod +x`, validou com `bash -n` ✅ |
| `observer` | `9router/ag/gemini-3.8-flash` | **leu de verdade um PNG** e devolveu `OBSERVER_42_OK` |
| `council` | `9router/ag/claude-sonnet-4-6` | síntese final do conselho |
| `councillor-architect` | `9router/ag/claude-opus-4-6-thinking` | assento dispatched |
| `councillor-reviewer` | `9router/cx/gpt-5.6-luna` | assento dispatched |
| `councillor-optimiser` | `9router/oc/deepseek-v4.1-flash-free` | assento dispatched |
| `councillor-visual` | `9router/ag/gemini-3.8-flash` | assento dispatched |

**Council end-to-end:** as 4 assentos foram despachados em paralelo
(`✓ Council seat … [Councillor-Architect|Reviewer|Optimiser|Visual Agent]`) e o
sintetizador respondeu com **consenso unânime**.

### 18.3 Estado do serviço

```
Daemon     opencode serve --service  pid 41619  http://127.0.0.1:49374
           env: NINEROUTER_API_KEY + OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
Túnel      running=true   https://${NINEROUTER_RELAY_HOST}
Auth       /v1/models sem key → HTTP 401 ✅
```

---

## 19. Divergências D10–D12 (Fases 3–5)

| ID | O que se esperava | Realidade | Tratamento |
|---|---|---|---|
| **D10** | Editar `oh-my-opencode-slim.json` e o efeito valer na hora | O **daemon serve config obsoleta**: o roster de subagentes continuava sem `observer` e sem `council` até o serviço ser reiniciado | `opencode service restart` após editar o config do plugin. Diagnóstico: o roster vinha do preset antigo (`openai`, sem `council`) — leitura de `dist/config/constants.d.ts` + do `docs/configuration.md` confirmou que o preset ativo é re-resolvido no start do servidor |
| **D11** | `opencode run --file img.png` anexa a imagem | O `--file` **não** anexa arquivo binário: a mensagem chegou sem parte de arquivo (`--format json` mostrou só `part=text`) | O Observer consome imagens pela **tool `read`** (não por anexo de mensagem). O teste correto é delegar ao observer com um caminho **dentro do projeto** — fora dele o OpenCode pede permissão `external_directory` e o `run` auto-rejeita |
| **D12** | `opencode run --session <nome>` cria a sessão | O flag exige um ID no formato `ses_…` (`Expected a string starting with "ses"`) | Usar `--continue` para o segundo turno da mesma sessão |

### Observações para quem for mexer no `9router` depois

1. **Não confie no catálogo.** 67 dos 103 modelos são catálogo morto — 18 nem
   existem upstream, 16 são recusados pelo provedor, 15 estão sem cota ou
   assinatura. Re-sonda (`tools/probe-models.sh`) antes de trocar qualquer
   atribuição.
2. **`gc/*` e `kimi/*` estão mortos** por cota/assinatura — foram confirmados
   também na Fase 2. Não usar em nenhum papel.
3. **O `gh/*` (copilot) é lento** (5–12 s por chamada). Ruim para papéis de
   latência; serve como último recurso.
4. **A sonda é barata e rápida** (~3 min para 103 modelos com `conc=4`) —
   reexecute-a após qualquer mudança no servidor ou nas assinaturas.

---

## 20. Estado final (Fases 0–5)

```
Servidor   9router.service  enabled / active   (NRestarts=0)
Túnel      running=true   https://${NINEROUTER_RELAY_HOST}
Auth       API key obrigatória em /v1/* (externo) · admin com senha rotacionada
Rede       20128 em 127.0.0.1 apenas · acesso externo só pelo túnel
Backups    .env / jwt-secret / cli-secret / data.sqlite  (20261022-042023)
           opencode.json + oh-my-opencode-slim.json     (20261022-091707)
Segredos   ~/.config/venice-stack/9router.env  (chmod 600, fora do repo)

Local      ~/.zshenv (600)  askpass + agente SSH + NINEROUTER_* + OPENCODE_*
           ~/.zshrc  INTOCADO
           ~/.config/opencode/opencode.json (600)  providers.9router (103 modelos)
           ~/.config/opencode/oh-my-opencode-slim.json  preset "9router"  (7 papéis + 4 assentos)
Sonda      tools/probe-models.sh (zsh, 755)  →  probe.jsonl (103 linhas, gitignored)
           36/103 aprovados (35,0 %)  ·  latência mediana 2859 ms
Plugin     oh-my-opencode-slim v3.0.5
Doctor     ok: true
Daemon     opencode serve --service  pid 41619  http://127.0.0.1:49374
Inferencia orchestrator/explorer/designer/fixer/observer/council + 4 assentos
           todos verificados com o modelo efetivo lido da API ✅
```

### Artefato do repositório

```
tools/probe-models.sh   (novo, 755)  — sonda de latência/HTTP/tool calling
tools/opencode-service.sh            — rede de segurança do env do daemon
tools/wait-tunnel.sh                  — garante o túnel nativo
PLAN.md                              — este registro
probe.jsonl                          — saída da sonda (gitignored)
```
