# PLAN.md — Execução das Fases 0 a 5 (9router + OpenCode)

**Servidor:** `${VENICE_STACK_SSH_HOST}` (`${VENICE_STACK_SSH_USER}`) · **Data:** 2026-10-22 (UTC) · **Fases:** 0 — Preparação/Hardening · 1 — OpenCode + provider 9router · 2 — oh-my-opencode-slim · 3 — Sondagem de modelos · 4 — Atribuição aos agentes · 5 — Verificação final
**Status da Fase 0:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 1:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 2:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 3:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 4:** ✅ CONCLUÍDA E VERIFICADA
**Status da Fase 5:** ✅ CONCLUÍDA E VERIFICADA

> **Nota de redação (Fase 0.5).** Este repositório vai para um remoto público.
> Todo identificador real de infraestrutura e toda credencial foram substituídos
> pelo **nome da variável** que os carrega no `.env` (gitignored, `600`):
>
> | Token neste documento | Variável no `.env` |
> | :--- | :--- |
> | `${VENICE_STACK_SSH_HOST}` | host/IP do servidor |
> | `${VENICE_STACK_SSH_USER}` | usuário SSH do servidor |
> | `${VENICE_SERVER_HOSTNAME}` | hostname do servidor |
> | `${NINEROUTER_RELAY_HOST}` | host do relay estável do túnel |
> | `${NINEROUTER_TUNNEL_HOST}` | host do quick tunnel (efêmero) |
> | `${HOME}` | home local |
>
> Os valores reais estão no `.env` da raiz e em
> `~/.config/venice-stack/9router.env` (`600`, fora do repositório).
> O `.env.example` versionado traz os mesmos campos com placeholders.

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
| **D13** | `tools/opencode-service.sh` garante que o daemon tenha o env do provider | O atalho "daemon já HEALTHY ⇒ nada a fazer" **pulava a gravação** no `service.json`. O daemon vivo ficava com as variáveis só por **herança do shell** que o iniciou, e o `service.json` ficava incompleto — um restart fora daquele shell recriava o daemon sem elas | A persistência passou a ser uma condição **independente** do health check: `needs_persist` compara o valor gravado com o do shell e força o `opencode service set env` quando divergem (inclusive quando o valor gravado está **errado**, não só ausente). Ver regressão na [seção 22.3](#223-regressão-do-d13) |

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

---

# 21. Fase 0.5 — Rotação de credenciais, saneamento do repositório e
#     reescrita do histórico (preparação para remoto público)

**Data:** 2026-10-22 · **Escopo:** repositório **e** histórico do git.

O objetivo desta rodada é duplo:

1. **Rotacionar** a senha de admin do 9router e fixar a credencial correta
   num `.env` do projeto, para que a mesma configuração possa ser replicada
   em outra máquina **sem rotacionar de novo**.
2. **Remover todo vestígio** de credenciais e de identificadores de
   infraestrutura (host, usuário, URLs de túnel) do repositório **e do
   histórico do git**, antes do push para um remoto **público**.

## 21.1 Rotação da senha de admin do 9router

**Onde a senha realmente vive.** A fonte autoritativa é o hash bcrypt em
`settings.data.password` (60 chars, `$2b$10$…`) dentro de
`~/.9router/db/data.sqlite`. O `INITIAL_PASSWORD` do `~/.9router/.env` é
apenas o **fallback de bootstrap** — trocar só ele **não** rotaciona nada.

**Como rotacionar.** Pela API da própria aplicação (rota local-only, exige o
cookie `auth_token`):

```
PATCH http://127.0.0.1:20128/api/settings
  {"currentPassword": "<ATUAL>", "newPassword": "<NOVA>"}
```

> `PUT` nessa rota devolve **405** — o verbo aceito é `PATCH`.
> `POST /api/auth/reset-password` **não** rotaciona: ele apenas **apaga** o
> hash guardado, voltando ao valor default. É um reset, não uma rotação.

**Procedimento executado:**

1. Backup de `~/.9router/.env` → `~/.9router/.env.bak.<timestamp>`.
2. Senha nova gerada **localmente** (40 chars, 4 classes de caracteres),
   escrita direto num arquivo `600` — nunca passa por `argv`, histórico de
   shell ou log.
3. `PATCH /api/settings` → **HTTP 200**.
4. Login com a senha nova → **HTTP 200** `{"success":true,…}`.
5. Login com a senha antiga → **HTTP 401** (confirma a invalidação).
6. `INITIAL_PASSWORD` do `~/.9router/.env` sincronizado com o novo valor.
7. `/v1` **não** foi afetado pela rotação: `GET /v1/models` autenticado → 200
   (1,63 s); sem chave → 401.

> ⚠️ O 9router tem **lockout** de login (4 tentativas falhas). Uma
> verificação com senha vazia consumiu uma dessas tentativas durante a
> primeira tentativa de rotação — daí o cuidado de não repetir o erro.

## 21.2 Convenção de credenciais (`.env` / `.env.example`)

| Arquivo | Versionado | Perm. | Conteúdo |
| :--- | :--- | :--- | :--- |
| `.env` (raiz do projeto) | ❌ | `600` | Valores **reais** |
| `.env.example` (raiz) | ✅ | `644` | **Placeholders** + instruções |
| `~/.config/venice-stack/9router.env` | ❌ (fora) | `600` | Cópia canônica local |
| `~/.zshenv` | ❌ (fora) | `600` | Só `export`; nenhum segredo literal |

Regras consolidadas (detalhe em **AGENTS.md → Fase 0.5**):

- Todo script em `tools/` carrega o `.env` via `tools/lib/venice-env.sh`
  (`set -a; source`). **Nenhum** host, usuário ou URL real fica hardcoded.
- O `.env` real tem permissão `600` e **nunca** é versionado.
- **A senha de admin já foi rotacionada.** Em outra máquina, copie o valor
  real; **não rotacione de novo** — isso invalidaria as credenciais já
  distribuídas.
- A passphrase da chave SSH **não** é senha do 9router. O `askpass` a lê do
  arquivo canônico de segredos em tempo de execução; ela não aparece no
  `~/.zshenv`, no repositório nem no histórico.

## 21.3 Saneamento do repositório

**Identificadores removidos** (considerados credenciais, por serem
infraestrutura exclusiva desta implantação):

| Identificador | O que é |
| :--- | :--- |
| `${VENICE_STACK_SSH_HOST}` | IP do servidor |
| `${VENICE_STACK_SSH_USER}` | usuário SSH do servidor |
| `${VENICE_SERVER_HOSTNAME}` | hostname do servidor |
| `${NINEROUTER_RELAY_HOST}` | host do relay estável do túnel |
| `${NINEROUTER_TUNNEL_HOST}` | host do quick tunnel (efêmero) |
| `${HOME}` | home local do dono |

**Mantidos** (não identificam o dono — são domínio de serviço compartilhado
ou nome de ferramenta): `abc-tunnel.us`, `trycloudflare`, `cloudflared`,
`13-Ubuntu` (string do kernel, capitalizada — não é o usuário SSH).

**Refatorações nos scripts** (para que o repositório funcione em outra
máquina sem carregar identificadores):

- `tools/lib/venice-env.sh` (novo) — carregador compartilhado do `.env`.
- `tools/9router-systemd.sh` — destino SSH vem do `.env`; o diretório de
  dados remoto passa a ser o `$HOME` do usuário; a unit systemd usa os
  placeholders `@SERVICE_USER@` / `@SERVICE_GROUP@` / `@DATA_DIR@`,
  resolvidos por `sed` **em tempo de execução**, com checagem de sanidade
  (nenhum placeholder pode sobrar na unit gerada).
- `tools/wait-tunnel.sh` — idem; e correção de um **bug latente**: o
  fallback do `state.json` chamava `remote "cmd"`, mas a função `remote()`
  ignora argumentos e lia o `stdin` — o comando nunca era executado. Nova
  função `tunnel_state_url_remote`.
- `tools/probe-models.sh` — `NINEROUTER_BASE_URL` virou **obrigatório**
  (antes tinha um default real hardcoded).
- `tools/opencode-service.sh` — passou a usar o `.env` como *fallback*; o
  ambiente do shell (via `~/.zshenv`) continua com precedência.

**Bug de configuração encontrado e corrigido:** o `NINEROUTER_BASE_URL` do
`.env` estava **sem o sufixo `/v1`**. `GET <base>/models` devolvia **404**;
`GET <base>/v1/models` devolvia **200**. Corrigido — e a sonda passou a
responder 100 % com tool calling depois do ajuste.

## 21.4 Reescrita do histórico do git

O `git filter-repo` **não** está instalado e o `git filter-branch` cria
`refs/original/*` (cópias do histórico sensível). A reescrita foi feita com
**plumbing puro do git**:

```
git ls-tree -r -z      → enumera os blobs do commit
git cat-file blob      → lê o conteúdo
git hash-object -w     → grava o blob reescrito
git update-index       → reconstrói a árvore
git write-tree         → grava a árvore
git commit-tree        → recria o commit
git update-ref         → move a branch
```

**O que foi preservado:** topologia (linear, 8 commits), datas de autor e
committer (ao segundo), mensagens **byte a byte** (exceto a substituição
textual), estrutura de árvores e modos de arquivo.

**O que foi substituído**, em *todo* blob de *todo* commit **e** nas
mensagens: os identificadores da tabela 21.3 e as credenciais.

**O que foi normalizado:** autor e committer de todos os commits. O
histórico carregava nome e **e-mail pessoal** do dono — para um remoto
público isso é um vazamento. Todos os commits passaram a usar a identidade
neutra `venice-stack <noreply@localhost>`.

**Limpeza física:** `git reflog expire --expire=now --expire-unreachable=now
--all` + `git gc --prune=now --aggressive`. Os 8 commits antigos e seus blobs
foram **removidos do object store** — verificado com `git cat-file -e` e por
busca binária em todo o diretório `.git`.

**Verificação final:** varredura automatizada sobre a árvore de trabalho, o
índice, **todos** os blobs de **todos** os commits, as mensagens, os headers
dos commits e os reflogs — **zero** ocorrências de qualquer padrão de
credencial ou identificador. O único lugar do disco que contém os valores
reais é o `.env` gitignored (mode `600`).

## 21.5 Como provisionar outra máquina

```bash
cp .env.example .env        # preencha com os valores reais
chmod 600 .env              # obrigatório
zsh tools/9router-systemd.sh install
zsh tools/wait-tunnel.sh enable
zsh tools/opencode-service.sh
zsh tools/probe-models.sh
```

E **não** rotacione a senha de admin de novo: copie o valor de
`NINEROUTER_ADMIN_PASSWORD`.

## 21.6 Estado do repositório após a rodada

```
Commits   8 (reescritos; identidades neutras; datas preservadas)
Trackeados  .env.example  AGENTS.md  PLAN.md  .gitignore
            tools/{9router-systemd,opencode-service,probe-models,wait-tunnel}.sh
            tools/lib/venice-env.sh
Gitignored .env (600)  probe.jsonl
Histórico  sem credenciais e sem identificadores de infraestrutura ✅
```

---

# 22. Rodada de consolidação — config sem literais e correção do D13

Objetivo desta rodada: eliminar o **último literal de infraestrutura** que
ainda vivia em arquivo de configuração (`opencode.json`) e garantir que o
env do daemon do OpenCode sobrevivesse a um restart.

## 22.1 `baseURL` do provider via `{env:...}`

O `~/.config/opencode/opencode.json` carregava a URL do relay como literal:

```json
"baseURL": "https://<relay>/v1"
```

Trocado por:

```json
"baseURL": "{env:NINEROUTER_BASE_URL}"
```

O arquivo de configuração do OpenCode passou a **não conter nenhum valor
real** — nem host, nem chave, nem URL. A chave já usava
`{env:NINEROUTER_API_KEY}`; agora a URL usa o mesmo mecanismo.

### Consequência: `NINEROUTER_BASE_URL` virou variável obrigatória

Com a URL referenciada por ambiente, um daemon que nasça sem essa variável
fica **sem baseURL** e toda chamada falha. Por isso ela entrou na lista
`REQUIRED_VARS` de `tools/opencode-service.sh`:

```
REQUIRED_VARS=(NINEROUTER_API_KEY NINEROUTER_BASE_URL OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS)
```

## 22.2 `~/.zshenv` passa a ser livre de literais

O `~/.zshenv` exportava `NINEROUTER_BASE_URL` como literal. Agora exporta
**três** variáveis lidas do arquivo canônico de segredos em **tempo de
execução**:

```zsh
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
```

O único literal que permanece é a **chave de API**, que precisa estar no
ambiente do daemon e é referenciada por `{env:NINEROUTER_API_KEY}`.

Efeito colateral útil: o teste SSH não-interativo do `AGENTS.md` agora
funciona **literalmente**, porque `VENICE_STACK_SSH_HOST` e
`VENICE_STACK_SSH_USER` passam a existir no ambiente de um `zsh -c` limpo:

```
$ zsh -c 'ssh -o BatchMode=yes "${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}" "echo NONINTERACTIVE_OK"'
NONINTERACTIVE_OK
```

## 22.3 Regressão do D13

O bug do D13 (o atalho "já HEALTHY ⇒ nada a fazer" pulava a gravação no
`service.json`) foi reproduzido de propósito e corrigido.

**Reprodução**: com o daemon vivo e saudável, o valor persistido foi apagado:

```
$ opencode service set env NINEROUTER_BASE_URL ""
$ opencode service get env
{ "NINEROUTER_API_KEY": "...", "NINEROUTER_BASE_URL": "" }
```

O daemon **continuava funcionando** (tinha a variável por herança do shell),
e o `service.json` ficava com o valor **errado** — um restart viria e
quebraria o provider.

**Correção**: `needs_persist` passou a ser uma condição independente do
health check, comparando o valor **gravado** com o valor **do shell**:

```zsh
needs_persist=false
for v in "${REQUIRED_VARS[@]}"; do
  want="$(printenv "$v" 2>/dev/null)"
  have="$(persisted_env_value "$v" || true)"
  if [[ "$want" != "$have" ]]; then
    needs_persist=true
    log "env persistido de $v divergente do shell - precisa gravar"
  fi
done

if [[ "$healthy" == "true" && "$needs_restart" == "false" && "$needs_persist" == "false" ]]; then
  log "servico ja HEALTHY com o env completo (pid ${pid}) - nada a fazer"
else
  ... persiste e sobe ...
fi
```

A comparação é por **divergência**, não por ausência: um valor gravado
**errado** (vazio, antigo, de outra máquina) também dispara a gravação.

**Verificação** (com o valor persistido deliberadamente apagado):

```
[opencode-service] env persistido de NINEROUTER_BASE_URL divergente do shell - precisa gravar
[opencode-service] env persistido de NINEROUTER_API_KEY ja esta atualizado
[opencode-service] persistindo NINEROUTER_BASE_URL no service.json do OpenCode...
```

Depois:

```
$ opencode service get env
{ "NINEROUTER_API_KEY": "...", "NINEROUTER_BASE_URL": "https://<relay>/v1" }
```

E a inferência real continuou respondendo:

```
$ zsh tools/opencode-service.sh --probe
> orchestrator · ag/claude-sonnet-4-6
OK
[opencode-service] probe: provider respondeu
```

## 22.4 Higiene do ambiente local

| Arquivo | Antes | Depois |
|---|---|---|
| `~/.config/opencode/opencode.json` | URL do relay literal | só `{env:...}` — **zero** valores reais |
| `~/.config/opencode/opencode.json.bak` (e `.bak.2026…`) | cópias com o literal | removidos (config atual verificado e funcional) |
| `~/.config/opencode/backups/opencode.json.2026….bak` | idem | removido |
| `~/.zshenv` | URL do relay literal | lê do arquivo canônico em tempo de execução |
| `~/.config/venice-stack/9router.env` | fonte de verdade (600) | mantido — **é** o ponto legítimo |
| `~/.config/opencode/service.json` | env persistido do daemon | mantido (600) — ponto legítimo |
| `~/.ssh/known_hosts` | host do servidor | mantido — SSH exige a chave de host |

## 22.5 Identidade do git

O `~/.gitconfig` **global** traz o nome e o e-mail pessoais do dono da
máquina. Um commit novo em **qualquer** repositório carrega essa identidade —
inclusive num repositório público.

Para este repositório a identidade foi fixada **localmente**, sem tocar no
global:

```
git config --local user.name  "venice-stack"
git config --local user.email "noreply@localhost"
```

> O valor global **não** é reproduzido aqui de propósito: citá-lo no
> repositório o reintroduziria no histórico. Para inspecioná-lo localmente:
>
> ```bash
> git config --global user.name
> git config --global user.email
> ```

O commit que vazou a identidade pessoal foi **recriado** com `commit-tree`
(árvore, mensagem, datas e topologia preservadas; só autor e committer
normalizados).



---

# 23. Deriva do catálogo — `qd/*` e `kc/*` ausentes do `opencode.json`

Sintoma relatado: o modelo `qd/dfmodel` não aparecia entre os modelos
disponíveis do 9router.

## 23.1 Diagnóstico

O `GET /v1/models` **devolvia** `qd/dfmodel` (141 modelos no total), então o
problema não estava no 9router: estava no `opencode.json`, que lista os
modelos **um a um** em `providers.9router.models`. Esse bloco foi gerado
quando o catálogo tinha 121 modelos; depois disso o 9router ganhou duas
conexões novas — `qd/*` (qoder, 12 modelos) e `kc/*` (kilocode, 8 modelos) —
e a config ficou velha.

| Onde | `qd/dfmodel` existe? |
|---|---|
| `GET {relay}/v1/models` (catálogo do 9router) | sim |
| `~/.config/opencode/opencode.json` (`providers.9router.models`) | **não** (121 de 141) |
| `opencode models` / seletor do TUI | **não** (reflexo do arquivo acima) |

Ou seja: 121 modelos na config, 141 no catálogo, e a diferença era exatamente
`qd/*` (12) + `kc/*` (8). Nada de cache, nada de túnel.

## 23.2 Sondagem das duas famílias novas

`tools/probe-models.sh --filter 'qd/'` e `--filter 'kc/'`:

| Família | HTTP 200 + tool calling | Diagnóstico |
|---|---|---|
| `qd/*` | 2 de 12 (`qd/qfmodel`, `qd/dfmodel`) | os outros 10 devolvem `503` com `[qoder/<model>] [403] code 112` apontando `https://qoder.com/pricing` — falta assinatura no upstream |
| `kc/*` | 0 de 8 | `503` com `[kilocode/...] [402] Paid Model - Credits Required` — sem créditos |

`qd/dfmodel` e `qd/qfmodel` respondem em ~2,4–2,9 s e chamam ferramenta
corretamente (`finish_reason: tool_calls`), então são utilizáveis.

## 23.3 Correção: `tools/sync-catalog.sh`

Script novo, idempotente, que casa o `opencode.json` com o catálogo vivo:

```
zsh tools/sync-catalog.sh                  # dry-run (diff)
zsh tools/sync-catalog.sh --apply          # grava, com backup antes
zsh tools/sync-catalog.sh --only 'qd/'     # restringe a prefixos
zsh tools/sync-catalog.sh --refresh        # reescreve limits/caps
zsh tools/sync-catalog.sh --prune          # remove os que sumiram
```

- lê URL/chave do `.env` (via `tools/lib/venice-env.sh`), nada hardcoded;
- monta a entrada a partir dos metadados reais do catálogo
  (`context_length`, `max_completion_tokens`, `capabilities.vision/pdf/tools`);
- só mexe em `providers.9router.models` — `$schema`, `model`, `plugin` e
  `lsp` ficam intactos;
- backup em `~/.config/opencode/backups/opencode.json.<stamp>.bak`;
- preserva modo `600`; a segunda execução é no-op (verificado).

Aplicado: **141 modelos** no `providers.9router.models`, incluindo `qd/dfmodel`.
`opencode models | grep '9router/qd/'` passou a listar as 12 entradas.

> Próximo passo natural, quando/se o upstream for pago: rodar
> `zsh tools/sync-models.sh` para que os agentes do `oh-my-opencode-slim`
> também considerem `qd/*` (o `probe.jsonl` da raiz está vazio, então a sonda
> precisa rodar antes — `zsh tools/probe-models.sh --concurrency 6`).

---

# 24. Comando global `/refresh_models_9router`

Objetivo: atualizar o catálogo do 9router no OpenCode **sem** depender de estar
dentro deste repositório.

## 24.1 Por que um comando e não só o script

O `opencode.json` lista os modelos um a um (§23). Enquanto o operador trabalha
em qualquer outro projeto, o catálogo continua mudando — e o modelo novo só
aparece depois de alguém rodar o sincronizador no diretório certo. Daí o
comando de barra global.

## 24.2 `tools/install-command.sh`

Instalador idempotente (`install` | `status` | `uninstall` | `--print`).
Copia o sincronizador para fora do repo e escreve o comando global:

| Caminho gerado | Modo | Papel |
|---|---|---|
| `${XDG_DATA_HOME:-~/.local/share}/9router-tools/sync-catalog.sh` | `755` | cópia do sincronizador |
| `…/9router-tools/lib/venice-env.sh` | `644` | carregador de ambiente da cópia |
| `${XDG_BIN_HOME:-~/.local/bin}/refresh-9router-models` | `755` | wrapper: valida flags e chama o script |
| `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/refresh_models_9router.md` | `644` | o comando de barra |

O `.md` usa um bloco de shell (`` !`…` ``) com **caminho absoluto** para o
wrapper — o comando funciona de qualquer diretório de trabalho. O wrapper só
aceita `--apply`, `--dry-run`, `--refresh`, `--prune` e `--only=`; qualquer
outro texto é ignorado com aviso, e nada dele vai para o shell (o bloco de shell
do OpenCode é executado fora do fluxo de permissões de ferramenta — regra da doc
de commands).

Sem argumentos o comando **aplica**; `--dry-run` só mostra o diff.

## 24.3 `tools/lib/venice-env.sh` fora do repo

Para rodar longe do repositório, o carregador ganhou dois ajustes:

1. `VENICE_ENV_FILE` e `VENICE_CANONICAL_ENV` passam a ser *overridable*
   (`: "${VAR:=default}"`), preservando o comportamento anterior por padrão;
2. o fallback canônico (`~/.config/venice-stack/9router.env`) passou a ser
   **lido** — antes o caminho existia no comentário, mas nada era carregado.
   Ele só preenche variável vazia (nunca sobrescreve o `.env` nem o ambiente),
   aceita só o formato `KEY='valor'` de uma linha, e usa `${(P)name-}` para não
   quebrar sob `set -u`.

Resultado: o comando instalado funciona fora do repo sem nenhuma credencial
duplicada — a fonte continua sendo o arquivo `600`.

## 24.4 Verificação

```
$ cd /tmp && ~/.local/bin/refresh-9router-models --dry-run
[catalog] catalogo: 141 modelos · config: 141 · escopo: 141
[catalog] nada a fazer: config ja esta em sincronia.
```

`opencode api get /api/command` lista `refresh_models_9router` entre os comandos
(8 no total). Exercitado também por `POST /api/session/{id}/command`, que
executou o bloco de shell, injetou a saída do sincronizador no prompt e
entregou a mensagem ao agente — o comando está funcional de ponta a ponta.

> A execução no teste ficou presa não por causa do comando, mas porque o modelo
> de teste (`ag/claude-sonnet-4-6`) estava indisponível no upstream
> (`antigravity/... Unavailable`). O comando em si já tinha feito o trabalho.

## 24.5 Provisionar outra máquina

```
git clone <repo> && cd <repo>
cp .env.example .env && chmod 600 .env     # preencher os valores reais
zsh tools/install-command.sh               # instala o comando global
```

Se preferir não manter o `.env` do projeto na máquina, basta a cópia canônica
`~/.config/venice-stack/9router.env` (`600`): é dela que o comando instalado
tira `NINEROUTER_BASE_URL` e `NINEROUTER_API_KEY`.

---

# 25. Comando global `/auto_select_models_oh_my_opencode_slim`

Objetivo: escolher, para cada papel do `oh-my-opencode-slim`, o melhor modelo
que **realmente responde** — não o que apenas aparece no catálogo. O catálogo
lista IDs; um ID pode retornar `403`/`402`/`503` no upstream ou não suportar
tool calling.

## 25.1 O que o motor faz

`tools/select-models.sh`:

1. sonda o 9router com `tools/probe-models.sh` (latência + `get_weather`);
2. sonda os modelos nativos do OpenCode com o mesmo payload, direto no
   endpoint público do provedor (`/api/model` fornece os metadados);
3. considera aprovado só `HTTP 200` **e** tool call presente;
4. pontua por papel (`werkzeug`, `rapido`, `raciocinio`, `visao`,
   `nao_critico`): contexto, saída máxima, reasoning, visão e latência;
5. escolhe até 3 referências por agente (principal + fallbacks) e os quatro
   `council/*`;
6. grava `~/.config/opencode/oh-my-opencode-slim.json` com backup e reinicia o
   daemon (salvo `--no-restart`).

Preferência: 9router (tier 0) → nativos do OpenCode (tier 1). Se o 9router não
tiver nenhum aprovado, os agentes continuam funcionais com os nativos; se só
existirem os free do OpenCode, são eles que entram. IDs `:free`/`-free` levam
penalidade — são último recurso, não primeira escolha.

## 25.2 Instalação e layout

O mesmo `tools/install-command.sh` instala os dois comandos e copia os quatro
arquivos de apoio para `~/.local/share/9router-tools/`:

| Origem | Destino |
|---|---|
| `tools/sync-catalog.sh` | `…/9router-tools/sync-catalog.sh` |
| `tools/select-models.sh` | `…/9router-tools/select-models.sh` |
| `tools/probe-models.sh` | `…/9router-tools/probe-models.sh` |
| `tools/lib/venice-env.sh` | `…/9router-tools/lib/venice-env.sh` |
| — (gerado) | `~/.local/bin/{refresh,auto-select}-9router-models` |
| — (gerado) | `~/.config/opencode/commands/{refresh,auto_select}*.md` |

## 25.3 Dois bugs corrigidos depois do primeiro teste

1. **`parameter not set` no wrapper do refresh.** A linha
   `(( $# == 0 || $have_apply ))` colocava a string `false` em contexto
   aritmético; sob `set -u` o zsh tentava ler a variável `false`. Troca por
   `if (( $# == 0 )) || [[ "$have_apply" == true ]]`.
2. **Cópias instaladas procuravam `ROOT/tools/…`.** Os scripts calculavam
   `ROOT="${0:A:h:h}"`, que dentro do repo é a raiz do projeto mas, instalados
   em `~/.local/share/9router-tools/`, apontava para `~/.local/share` —
   daí `can't open input file: ~/.local/share/tools/probe-models.sh` e
   “sonda ausente”. Agora cada script resolve a própria pasta (`TOOLS_DIR`) e
   usa a raiz do repo **só** quando `${TOOLS_DIR:h}/.git` existe; fora do repo,
   dados (`probe.jsonl`, `probe-native.jsonl`) ficam ao lado do próprio script.
   O `venice-env.sh` faz a mesma detecção para achar o `.env`.

## 25.4 Verificação

```
$ cd /tmp && ~/.local/bin/refresh-9router-models --dry-run
[catalog] catalogo: 170 modelos · config: 170 · escopo: 170
[catalog] nada a fazer: config ja esta em sincronia.

$ cd /tmp && ~/.local/bin/auto-select-9router-models --dry-run
[select] aprovados: 54 no 9router · 9 nativos do OpenCode
```

Sonda de 2026-10-22 (catálogo de 170 modelos, concorrência 10): 54 aprovaram
(HTTP 200 **e** tool calling) — `cx` 10/19, `gh` 13/28, `kc` 10/22, `oc` 9/15,
`nous` 5/8, `ag` 4/25, `qd` 2/12; famílias `cbai`, `gc`, `kimi`, `xai` e
`teste` não tinham nenhum modelo funcional no momento. A atribuição aplicada
ficou toda no 9router (`9router/cx/gpt-5.6-luna[1m]` como principal, com
`9router/cx/gpt-6-luna[1m]` e `9router/cx/gpt-5.6-terra[1m]` de fallback;
`explorer` em `9router/gh/gpt-4o-2024-11-20`).

A prova de ponta a ponta do comando de barra é
`POST /api/session/{id}/command` (o `opencode run "/comando"` não expande
comandos). O caminho instalado é exercitado rodando o wrapper a partir de
`/tmp`, que é o que o bloco de shell do `.md` faz.

## 25.5 Restart do daemon dentro do TUI

Nas duas primeiras execuções reais, `--apply` gravou a config e então chamou
`opencode service restart` — que derrubou o daemon que hospedava a própria
sessão, cancelando o comando antes da resposta. O arquivo já estava correto
(backup e nova atribuição confirmados), mas o usuário não recebia o resumo.

Decisão: o comando `.md` chama o seletor com `--no-restart` e instrui o agente
a avisar que o restart ficou pendente. Fora do TUI, `--restart` continua
disponível e reinicia na mesma execução.

## 26. Sonda sempre completa no comando `/auto_select_models_oh_my_opencode_slim`

A execução de 2026-11-05 provou o defeito: o pool tinha **16 modelos** (só a
família `openrouter/*`) porque o `probe.jsonl` era reaproveitado, enquanto o
catálogo vivo tinha **201**. Os 10 "nativos aprovados" vinham de metadados do
OpenCode, sem ping — nunca foram testados. Resultado: atribuição "idempotente"
sobre um universo velho e estreito.

Decisões:

1. `tools/select-models.sh` sonda **sempre** (`RUN_PROBE=true` por padrão);
   `--quick` virou no-op com aviso. Não existe caminho que aplique a partir de
   `probe.jsonl` antigo.
2. O wrapper `auto-select-9router-models` força `--probe` e **recusa**
   `--quick`, `--only-native` e `--probe-filter` (universo reduzido = defeito).
   O loop de argumentos virou `while`, corrigindo o `shift` dentro do `for` que
   quebrava `--server`.
3. Nativo só entra no pool se foi pingado e aprovado. O `add` incondicional via
   `native_meta` foi removido; modelos sem sonda válida são listados como aviso.
4. Sonda do 9router que falha agora **aborta** (`die`) em vez de seguir com
   dados velhos. Zero aprovados no total também aborta (não grava config vazia).
5. `probe_native` mandava `opencode/<id>` no campo `model`; o endpoint do
   provedor espera o ID **sem** prefixo. Corrigido (`split("/",1)[-1]`). Efeito
   colateral conhecido: com a cota free esgotada (`429 FreeUsageLimitError`),
   nenhum nativo é aprovado e a atribuição fica só no 9router.
6. O log do seletor passou a imprimir `testados:` além de `aprovados:` — antes
   não dava para distinguir pool grande de pool velho.

Custo aceito: a varredura completa leva dezenas de minutos (201 modelos,
`--max-time 120`, concorrência 8). É o preço de não escolher no escuro.

## 27. Histórico por papel + pesquisa web no seletor

Problema: a sonda só sabe o que respondeu **agora**. Um modelo pode estar fora
do ar numa rodada (503, cota, relay) e ainda ser a melhor escolha para um papel;
e a nota de qualidade medida não sabe se ele é bom em planejar, revisar ou
chamar ferramenta. Cada execução começava do zero.

Decisões:

1. Novo `tools/model-history.sh` com histórico cumulativo em JSON
   (`model-history.json`, modo `600`, gitignored). Comandos: `record`, `merge`,
   `score`, `ranking`, `assignment`, `show`, `path`. Escrita atômica
   (`tmp` + `os.replace`), leitura tolerante a arquivo ausente.
2. A pesquisa web é feita pelo **agente que roda o comando de barra** (depois da
   sonda, `websearch`), e gravada via `record --role ... --score ... --source`.
   O bloco `!` do `.md` roda antes de o modelo responder, então a pesquisa
   alimenta a execução **seguinte** — o histórico existe justamente para isso.
3. O seletor soma `1000 * research + 5 * assigned` à pontuação da categoria.
   Pesquisa nova pode rebaixar quem estava bem; a última nota por papel vence e
   o `research_log` guarda até 50 registros com fonte e data.
4. Modelo com histórico forte (`research >= 0.7` ou 2+ aprovações) que **não**
   respondeu na rodada é anexado como fallback extra e marcado `[histórico]`.
   Não é promovido a principal: sem prova de vida nesta rodada, ele só cobre o
   caso de o principal falhar.
5. `merge` identifica a origem pelo **arquivo** (`--probe` = 9router,
   `--native` = nativo), não pelo formato do ID — `cbai/minimax-m3` tem barra e
   era classificado como nativo quando o arquivo nativo existia vazio.
6. `merge` é idempotente por `ts`: reimportar a mesma sonda (mesmo `ts`) não
   duplica `ok`/`fail`; e um `last_probe_run` guarda a rodada inteira.
7. `--dry-run` **não** escreve no histórico. `merge` e `assignment` só rodam com
   `--apply`, senão o histórico registraria uma atribuição que nunca foi gravada.
8. `install-command.sh` instala `model-history.sh`, semeia o histórico do repo
   quando o instalado ainda não existe e **preserva** o arquivo no `uninstall`
   (o `rm -rf` do diretório de dados apagaria anos de ranking).

Custo: cada execução real escreve duas vezes (merge da sonda + assignment por
agente/councillor) num arquivo pequeno; nada de rede.

# 28. Retomada em máquina nova: o que faltava e a rede filtrada

Estado encontrado: o repositório estava completo, mas a **máquina** não. O
`.env` real tinha só cinco valores preenchidos (host, usuário e passphrase do
SSH, `NINEROUTER_BASE_URL` e `NINEROUTER_RELAY_HOST`); as três credenciais
(`NINEROUTER_API_KEY`, `NINEROUTER_ADMIN_PASSWORD`, `NINEROUTER_JWT_SECRET`)
ainda eram placeholders, e nada da Fase 0 local / Fase 1 existia fora do repo.

## 28.1 Divergências corrigidas

| # | Divergência | Correção |
| :--- | :--- | :--- |
| D14 | `NINEROUTER_RELAY_HOST` gravado com esquema (`https://host`); o contrato do README é host puro | normalizado para `host`; `NINEROUTER_BASE_URL` já é a forma com esquema e `/v1` |
| D15 | `.env` estava `644` | `chmod 600` |
| D16 | `~/.zshrc` recebeu o bloco `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS` do instalador (contra a regra do AGENTS.md) | bloco movido para `~/.zshenv`; `~/.zshrc` limpo |
| D17 | README §4 exportava `NINEROUTER_API_KEY` **literal** no `~/.zshenv`, contradizendo "nenhum segredo fora do arquivo canônico" | o `~/.zshenv` lê a chave do arquivo canônico e **descarta placeholders** (exportar `sk-xxxx…` é pior que não exportar: vira 401 em vez de "chave ausente") |
| D18 | `~/.local/bin` não estava no `PATH`, então os wrappers do `install-command.sh` não eram encontráveis | export no `~/.zshenv` |

## 28.2 O que foi aplicado

1. `~/.config/venice-stack/9router.env` (700/600) criado como cópia canônica do `.env`.
2. `~/.zshenv` (600) criado com: askpass + ssh-agent (Fase 0.0), leitura do
   arquivo canônico (Fase 0.5), `PATH` e os exports do oh-my-opencode-slim.
3. `~/.config/opencode/opencode.json` ganhou `providers.9router` com
   `baseURL`/`apiKey` por `{env:…}` e `models` **vazio** — o catálogo é
   preenchido por `tools/sync-catalog.sh` quando a API key existir. Config
   validada: `opencode models` continua saindo com `0`.
4. `tools/install-command.sh install`: 6 scripts em `~/.local/share/9router-tools/`,
   3 wrappers em `~/.local/bin/`, 3 comandos de barra em `~/.config/opencode/commands/`.
5. `npx oh-my-opencode-slim doctor` → exit `0` (`[preset] opencode-free ✓`).

## 28.3 A rede desta máquina (WSL2 atrás de resolver corporativo)

Descoberta que explica "o túnel só funciona com VPN": o resolver local
(`10.255.255.254`, domínio `seas.local`) **filtra** o domínio do relay e
devolve o IP da block page do FortiGuard (cert
`CN=Fortiguard SDNS Blocked Page`). O host real é Cloudflare
(obtido por DoH) e responde `401` em
`/v1/models` — ou seja, **o túnel está no ar e alcançável sem VPN**; só o nome
é que mente. A porta 22 do servidor está bloqueada fora da VPN (firewall), por
isso a Fase 0/5 continua exigindo VPN.

Ferramentas novas (ambas zsh, sem host hardcoded, lendo o `.env`):

- `tools/net-diag.sh` — separa DNS / TCP / TLS / HTTP por host, compara a
  resolução local com a real (DoH) e dá um veredito (`DNS_FILTRADO`,
  `TCP_BLOQUEADO`, `TLS_INTERCEPTADO`, `OK (HTTP 401)`…). Só leitura.
- `tools/pin-host.sh` — fixa o IP real do relay em `/etc/hosts` num bloco
  marcado (`--status`/`--dry-run`/`--refresh`/`--undo`), sem trocar o resolver
  da máquina (o que quebraria `seas.local`). Detecta WSL e avisa que
  `/etc/hosts` é regenerado sem `generateHosts = false` em `/etc/wsl.conf`.

Decisão: **não** trocar o resolver global nem usar `--resolve` no provider —
o primeiro quebra nomes internos, o segundo não é suportado pelo OpenCode.

## 28.4 Por que a VPN derruba os modelos (medido)

A VPN é o **ProtonVPN rodando no Windows**, com o WSL2 em NAT. Com ela ligada,
o `opencode.ai` resolve e conecta normalmente, mas a requisição volta com
`Free usage limit reached. Free models work in OpenCode`. Não é DNS nem
firewall: a cota do free tier do OpenCode Zen é contada por **IP de saída**, e
o IP compartilhado do túnel VPN já está estourado. Nenhum ajuste local no
cliente muda isso.

Consequência de desenho: o caminho certo não é "fazer o free tier funcionar
com VPN", é **parar de depender dele**. Com os papéis apontando para modelos do
9router, os agentes não tocam em `opencode.ai` e o estado da VPN deixa de
importar (o relay é Cloudflare na 443 e atravessa o túnel VPN normalmente).

## 28.5 `tools/vpn-window.sh` — servidor em uma janela de VPN

O SSH (porta 22) continua bloqueado fora da VPN, e a VPN derruba o agente.
Para não exigir troca de contexto manual, o script faz **toda** a coleta de
servidor em uma execução não interativa:

1. deriva o token CLI (`sha256(machine-id + "9r-cli-auth" + cli-secret)[:16]`);
2. `GET /api/keys` com o token CLI; se não vier `200`, faz login com
   `INITIAL_PASSWORD` e repete com o cookie `auth_token`;
3. `GET /api/tunnel/status` → `publicUrl` (relay canônico) e `tunnelUrl`;
4. lê `JWT_SECRET` e `INITIAL_PASSWORD` de `~/.9router/.env`, e `hostname`;
5. grava **só** o que está vazio/placeholder (`.env` + cópia canônica, 600),
   reportando `SKIP` para valor real divergente (a menos que `--force`);
6. roda `sync-catalog.sh --apply` para preencher `providers.9router.models`.

Decisão: o script **não** roda a sonda nem a atribuição. Essas não precisam de
VPN (o relay responde direto depois do pin) e levam dezenas de minutos; rodar
tudo dentro da janela de VPN aumentaria o tempo em que o agente fica fora do ar.

## 28.6 Execução (sem VPN, pela API pública do túnel)

A janela de VPN não foi necessária: com o pin do §15.1, o túnel responde na 443
e as rotas autenticadas funcionaram pelo relay.

| Passo | Resultado |
| :--- | :--- |
| `GET /v1/models` com a API key do cliente | `200`, 216 modelos |
| `POST /api/auth/login` (cookie `auth_token`) | `200` |
| `GET /api/keys` | 1 chave ativa, `access.restricted=false` |
| `GET /api/tunnel/status` | `publicUrl` = o mesmo relay do `.env`; `tunnelUrl` novo |
| `GET /api/settings` | `requireApiKey=true`, `requireLogin=true`, `tunnelProvider=cloudflare` |
| `GET /api/version` | `0.5.112` (existe `0.5.116`) |
| `sync-catalog.sh --apply` | `providers.9router.models` = 216; `opencode models` → 228 (216 + 12 nativos) |

Descoberta de configuração (D19): o plugin resolve
`oh-my-opencode-slim.jsonc` **antes** de `.json`, mas `select-models.sh`,
`select-models-uncensored.sh` e `sync-models.sh` apontavam para `.json` por
padrão. Numa máquina cujo instalador criou `.jsonc`, isso gravaria a atribuição
num arquivo que o plugin ignora. Corrigido: os três scripts agora preferem
`.jsonc` quando ele existe.

Descoberta de operação (D20): `opencode service start` **não substitui** um
daemon já em execução (o daemon costuma ter sido subido pela extensão do VS
Code, com env mínimo). Persistir o env no `service.json` é necessário mas não
suficiente — o daemon vivo só o recolhe num `opencode service restart`, e esse
restart derruba a sessão do TUI que o pediu. Por isso o restart é o **último**
passo, feito de fora da sessão do agente.

## 28.7 Sonda e atribuição (executadas)

| Etapa | Resultado |
| :--- | :--- |
| Sonda 9router | 216 modelos · 50 aprovados (200 + tool call) |
| Sonda nativa | 12 modelos · 0 aprovados |
| Pesquisa por papel | 23 registros `(modelo, papel)` no `model-history.json` |
| Atribuição | 7 agentes + 4 assentos de council, 100% `9router/*` |
| Preset | renomeado de `opencode-free` para `9router` |
| Conselho `diverse` | Anthropic / DeepSeek / Google / Moonshot |
| `npx oh-my-opencode-slim doctor` | `[preset] 9router ✓` |
| `opencode models` | 228 (216 + 12 nativos) |
| Inferência real | `opencode run --model 9router/ag/claude-sonnet-4-6` → `OK` |

### 28.7.1 Quatro defeitos encontrados no caminho

Todos silenciosos: nenhum deles dava erro, apenas faziam o seletor ignorar o
que deveria usar.

| # | Defeito | Efeito | Correção |
| :--- | :--- | :--- | :--- |
| D21 | `hscore()` comparava o id prefixado do universo (`9router/ag/...`) com a chave crua do histórico (`ag/...`) | **toda** nota de pesquisa era perdida; a Fase 4 virava decoração | normalizar com `bare()` na leitura |
| D22 | `stale_candidates()` fazia a mesma comparação e devolvia o id sem prefixo | modelo aprovado entrava como 4º fallback com referência inválida (`ag/...`, sem provedor) | normalizar e emitir o id completo |
| D23 | `select-models.sh` chamava o `model-history.sh` **instalado**, que resolve o arquivo a partir da própria pasta | leitura de um `model-history.json` diferente (ou inexistente) do que estava sendo escrito | pinar `MODEL_HISTORY` no env dos subprocessos |
| D24 | `record` grava id cru, `merge` grava id prefixado → duas entradas para o mesmo modelo | pesquisa em uma entrada, sonda em outra | `score` agrega por id canônico |

Além disso, duas ordens de categoria estavam erradas por construção:
`designer` era `werkzeug`-primeiro (herdava a cadeia de texto do `fixer`, apesar
de o papel receber imagem) e `council/optimiser` era `werkzeug`-primeiro (mesma
cadeia do `reviewer`, anulando a diversidade do consenso). Corrigidas para
`visao`-primeiro e `rapido`-primeiro.

## 28.8 Pendente

`opencode service restart` a partir de um shell com o `~/.zshenv` carregado.
O `service.json` já tem as três variáveis persistidas, mas o daemon vivo foi
subido por um processo sem o `~/.zshenv` — só o restart o recria com o env.
Atenção: o restart derruba a sessão do TUI que o pediu (D20).
