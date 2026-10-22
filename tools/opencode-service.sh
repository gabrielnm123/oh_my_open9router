#!/usr/bin/env zsh
# tools/opencode-service.sh
#
# Garante que o servico em background do OpenCode (daemon compartilhado) este
# de pe E com o ambiente correto do provider 9router.
#
# Por que isso e necessario:
#   O OpenCode V2 e cliente-servidor. O daemon compartilhado
#   (`opencode serve --service`) e daemonizado (PPID=1) e herda o ambiente do
#   processo que o iniciou. O ambiente e congelado no exec: se o daemon nasceu
#   antes do `~/.zshenv` receber `export NINEROUTER_API_KEY=...`, ele roda sem
#   a chave e toda chamada ao provider falha com:
#       Error: API key required for remote API access
#   (a configuracao esta correta; o que falta e o env do processo).
#
#   A solucao NAO e depender do processo que iniciou o daemon (pode ser a
#   extensao do VS Code, que observamos com env minimo). E persistir o env no
#   proprio servico:
#       opencode service set env <KEY> <VALUE>
#   O daemon entao nasce com essas variaveis independente de quem o iniciou.
#
# Regras do AGENTS.md:
#   - variaveis de ambiente local vao em `~/.zshenv`, nunca em `~/.zshrc`
#     (o OpenCode roda `zsh -c`, nao-interativo);
#   - `~/.zshenv` (mode 600) e a fonte canonica; o `service.json` do OpenCode
#     (mode 600, fora do repo) e a copia de trabalho do daemon;
#   - idempotente: pode rodar quantas vezes quiser.
#
# Uso:
#   zsh tools/opencode-service.sh            # garante env + servico healthy
#   zsh tools/opencode-service.sh --check    # so diagnostica (exit != 0 se unhealthy)
#   zsh tools/opencode-service.sh --probe    # diagnostica + inferencia real no provider
#
# Variaveis de ambiente:
#   OPENCODE_SERVICE_TIMEOUT  (default: 120, segundos para o servico ficar healthy)
#   NINEROUTER_PROBE_MODEL   (default: 9router/ag/claude-sonnet-4-6)

set -euo pipefail

TIMEOUT="${OPENCODE_SERVICE_TIMEOUT:-120}"
PROBE_MODEL="${NINEROUTER_PROBE_MODEL:-9router/ag/claude-sonnet-4-6}"
ACTION="${1:-ensure}"

REQUIRED_VARS=(NINEROUTER_API_KEY OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS)
STATE_FILE="${HOME}/.local/state/opencode/service.json"

log()  { printf '[opencode-service] %s\n' "$*"; }
warn() { printf '[opencode-service] AVISO: %s\n' "$*" >&2; }
die()  { printf '[opencode-service] ERRO: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- diagnostico ---

# PID do daemon compartilhado, sem efeito colateral.
service_pid() {
  [[ -r "$STATE_FILE" ]] || { echo ''; return 0; }
  python3 -c "
import json
try:
    print(json.load(open('$STATE_FILE')).get('pid') or '')
except Exception:
    print('')
" 2>/dev/null || echo ''
}

# O daemon tem a variavel no ambiente? (proc/pid/environ reflete o exec)
service_has_var() {
  local pid="$1" var="$2"
  [[ -n "$pid" && -r "/proc/${pid}/environ" ]] || return 1
  tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -q "^${var}="
}

# O daemon responde na API?
service_healthy() {
  timeout 20 opencode api get /api/info >/dev/null 2>&1
}

# Este shell tem as variaveis? (precisa ter sido aberto a partir de um zsh que
# leu o ~/.zshenv - por isso o script exige `zsh tools/opencode-service.sh`)
shell_has_var() {
  local var="$1"
  [[ -n "$(printenv "$var" 2>/dev/null)" ]]
}

# Valor persistido no service.json do OpenCode ("opencode service get env").
persisted_env_value() {
  local var="$1"
  timeout 20 opencode service get env "$var" 2>/dev/null | tail -n 1
}

# --------------------------------------------------------------- relatorio ---

report() {
  local pid="$1" v
  printf '\n[opencode-service] --- relatorio ---\n'
  printf '[opencode-service] daemon pid      : %s\n' "${pid:-<nenhum>}"
  printf '[opencode-service] daemon healthy  : %s\n' "$(service_healthy && echo sim || echo nao)"
  for v in "${REQUIRED_VARS[@]}"; do
    if service_has_var "$pid" "$v"; then
      printf '[opencode-service] daemon tem %-42s: sim\n' "$v"
    else
      printf '[opencode-service] daemon tem %-42s: NAO\n' "$v"
    fi
  done
  for v in "${REQUIRED_VARS[@]}"; do
    if shell_has_var "$v"; then
      printf '[opencode-service] shell  tem %-42s: sim\n' "$v"
    else
      printf '[opencode-service] shell  tem %-42s: NAO\n' "$v"
    fi
  done
  printf '[opencode-service] ----------------------------\n\n'
}

# ------------------------------------------------------------------ check ---

pid="$(service_pid)"
healthy=false
if service_healthy; then healthy=true; fi

needs_restart=false
for v in "${REQUIRED_VARS[@]}"; do
  if ! service_has_var "$pid" "$v"; then
    needs_restart=true
  fi
done

report "$pid"

if [[ "$ACTION" == "--check" ]]; then
  if [[ "$healthy" == "true" && "$needs_restart" == "false" ]]; then
    log "servico HEALTHY (env completo)"
    exit 0
  fi
  warn "servico UNHEALTHY (healthy=${healthy}, env_incompleto=${needs_restart})"
  exit 1
fi

# ----------------------------------------------------------------- ensure ---

# O env do shell e a fonte canonica. O restart so funciona se este shell tiver
# as variaveis, porque o daemon herda o ambiente de quem o iniciou.
for v in "${REQUIRED_VARS[@]}"; do
  if ! shell_has_var "$v"; then
    die "este shell nao tem $v - rode via 'zsh tools/opencode-service.sh' (o .zshenv precisa estar carregado)"
  fi
done

if [[ "$healthy" == "true" && "$needs_restart" == "false" ]]; then
  log "servico ja HEALTHY com o env completo (pid ${pid}) - nada a fazer"
else
  # Persiste o env no proprio servico (independentemente de quem o iniciar).
  # 'service set env' para o daemon atual; o start seguinte o recolhe.
  for v in "${REQUIRED_VARS[@]}"; do
    want="$(printenv "$v" 2>/dev/null)"
    have="$(persisted_env_value "$v" || true)"
    if [[ "$want" == "$have" ]]; then
      log "env persistido de $v ja esta atualizado"
      continue
    fi
    log "persistindo $v no service.json do OpenCode..."
    timeout 60 opencode service set env "$v" "$want" >/dev/null 2>&1 \
      || warn "falha ao persistir $v (o daemon sera recriado do .zshenv assim mesmo)"
  done

  log "subindo o daemon..."
  timeout 120 opencode service start >/dev/null 2>&1 || warn "'opencode service start' retornou erro"
fi

# -------------------------------------------------------------- wait/verify --

log "aguardando o servico ficar healthy (timeout ${TIMEOUT}s)..."
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  if service_healthy; then
    pid="$(service_pid)"
    ok=true
    for v in "${REQUIRED_VARS[@]}"; do
      if ! service_has_var "$pid" "$v"; then
        ok=false
        warn "daemon ainda sem $v"
      fi
    done
    if [[ "$ok" == "true" ]]; then
      report "$pid"
      log "OK: daemon rodando com o env do provider 9router"
      if [[ "$ACTION" == "--probe" ]]; then
        log "probe de inferencia real no provider (${PROBE_MODEL})..."
        if timeout 240 opencode run --model "$PROBE_MODEL" "Responda APENAS a palavra: OK" 2>&1 | tail -5; then
          log "probe: provider respondeu"
        else
          die "probe falhou: o provider nao respondeu"
        fi
      fi
      exit 0
    fi
  fi
  sleep 2
done

die "timeout aguardando o servico ficar healthy com o env completo"
