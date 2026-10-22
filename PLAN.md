# PLAN.md — Execução da Fase 0 (9router + OpenCode)

**Servidor:** `${VENICE_STACK_SSH_HOST}` (`${VENICE_STACK_SSH_USER}`) · **Data:** 2026-10-22 (UTC) · **Fase:** 0 — Preparação, Descoberta, Hardening e Partida
**Status da Fase 0:** ✅ CONCLUÍDA E VERIFICADA

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
```

### Estado do repositório

| Arquivo | Mudança |
|---|---|
| `tools/9router-systemd.sh` | restaurado + B1 corrigido (heredoc) + polling `running:true` |
| `tools/wait-tunnel.sh` | restaurado + B6 corrigido + `assert_tunnel_is_locked()` |
| `PLAN.md` | este documento |
| `.gitignore` | novo — impede versionar segredos/artefatos |
| `AGENTS.md` | ⚠️ modificação **pré-existente** à esta sessão (reescrita condensada) — deixada sem commit para revisão do responsável |
