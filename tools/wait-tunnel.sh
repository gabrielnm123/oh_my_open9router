#!/usr/bin/env zsh
# tools/wait-tunnel.sh
#
# Forca o tunel NATIVO do 9router (POST /api/tunnel/enable, rota local-only)
# via SSH e aguarda ate que o tunel publico responda HTTP 200 ou 401.
#
# Regras do AGENTS.md:
#   - o tunel e do 9router e e intocavel (nada de cloudflared/ngrok paralelo);
#   - acesso externo e somente pelo tunel;
#   - idempotente: pode rodar quantas vezes quiser.
#
# Uso:
#   zsh tools/wait-tunnel.sh              # forca + aguarda
#   zsh tools/wait-tunnel.sh --status     # so consulta o status do tunel
#
# Variaveis de ambiente:
#   NINEROUTER_SSH_HOST   (default: ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST})
#   WAIT_TUNNEL_TIMEOUT   (default: 240, segundos)
#   WAIT_TUNNEL_INTERVAL  (default: 3, segundos entre tentativas)

set -euo pipefail

SSH_HOST="${NINEROUTER_SSH_HOST:-${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}}"
TIMEOUT="${WAIT_TUNNEL_TIMEOUT:-240}"
INTERVAL="${WAIT_TUNNEL_INTERVAL:-3}"
ACTION="${1:-enable}"

log()  { printf '[wait-tunnel] %s\n' "$*"; }
warn() { printf '[wait-tunnel] AVISO: %s\n' "$*" >&2; }
die()  { printf '[wait-tunnel] ERRO: %s\n' "$*" >&2; exit 1; }

# Roda um script bash no servidor remoto via stdin (evita quoting hell).
remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" 'bash -s'
}

# Calcula o token CLI do 9router no servidor.
# O app deriva o token de: sha256(machine-id + "9r-cli-auth" + cli-secret)[:16]
# (ver .next-cli-build/server/middleware.js -> funcoes L/aH).
cli_token_remote() {
  remote <<'REMOTE'
set -euo pipefail
D="/home/${VENICE_STACK_SSH_USER}/.9router"
MID="$(cat "${D}/machine-id")"
SEC="$(cat "${D}/auth/cli-secret")"
printf '%s' "${MID}9r-cli-auth${SEC}" | sha256sum | cut -c1-16
REMOTE
}

# Status do tunel (JSON) lido pela rota local-only /api/tunnel/status.
tunnel_status_remote() {
  local token="$1"
  remote <<REMOTE
set -euo pipefail
TOKEN="${token}"
curl -s --max-time 20 -H "x-9r-cli-token: \${TOKEN}" http://127.0.0.1:20128/api/tunnel/status
REMOTE
}

# Extrai um campo do JSON do tunnel (usa python3, presente nos dois lados).
json_get() {
  python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit
t=(d.get('tunnel') or {})
print(t.get('$1') or '')
" 2>/dev/null || echo ''
}

# ------------------------------------------------------- security assert ----
# O tunel expoe o 9router para a internet. A rota /api/health e publica por
# design (o AGENTS.md aceita 200 OU 401 nela), mas as rotas /v1/* DEVEM
# exigir API key quando acessadas de fora. O middleware so dispensa a key
# para peer loopback; via tunel o peer e externo, entao o esperado e 401.
# Se vier 200, o catalogo de modelos esta exposto sem autenticacao.
assert_tunnel_is_locked() {
  local base="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${base}/v1/models" 2>/dev/null)" || true
  code="${code:-000}"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    log "seguranca OK: ${base}/v1/models sem key -> HTTP ${code} (exige API key)"
  elif [[ "$code" == "200" ]]; then
    warn "ATENCAO: ${base}/v1/models sem key -> HTTP 200 (catalogo publico via tunel!)"
  else
    warn "ATENCAO: nao deu para validar a exigencia de API key (HTTP ${code})"
  fi
}

# ---------------------------------------------------------------- status ----
if [[ "$ACTION" == "--status" ]]; then
  TOKEN="$(cli_token_remote)"
  log "status do tunel:"
  tunnel_status_remote "$TOKEN" | python3 -m json.tool 2>/dev/null \
    || tunnel_status_remote "$TOKEN"
  exit 0
fi

# --------------------------------------------------------------- enable ----
log "forcando o tunel nativo em ${SSH_HOST} (POST /api/tunnel/enable) ..."

TOKEN="$(cli_token_remote)"
[[ -n "$TOKEN" ]] || die "nao foi possivel calcular o token CLI do 9router"

# A rota /api/tunnel/enable espera ~8s pelo tunel subir antes de responder.
# Ela pode responder {"error":"Health check timeout after 60000ms"} mesmo com o
# tunel no ar: o relay abc-tunnel.us leva >60s para propagar o novo upstream.
# Por isso o erro da rota NAO e fatal aqui - o loop abaixo valida o tunel de fato.
ENABLE_OUT="$(remote <<REMOTE
set -uo pipefail
TOKEN="${TOKEN}"
curl -s --max-time 150 -X POST -H "x-9r-cli-token: \${TOKEN}" http://127.0.0.1:20128/api/tunnel/enable
REMOTE
)" || ENABLE_OUT="(sem resposta)"

if [[ "$ENABLE_OUT" == *error* ]]; then
  warn "a rota /api/tunnel/enable retornou: ${ENABLE_OUT:0:200}"
  warn "(falso negativo conhecido: propagacao do relay > 60s). Validando pelo status real..."
else
  log "resposta do enable: ${ENABLE_OUT:0:300}"
fi

# --------------------------------------------------------------- wait ------
log "aguardando o tunel responder (timeout ${TIMEOUT}s, intervalo ${INTERVAL}s)..."

deadline=$(( SECONDS + TIMEOUT ))
url=""
direct_url=""
last_code="000"

while (( SECONDS < deadline )); do
  # O URL muda a cada enable (quick tunnel): reconsultamos sempre.
  STATUS="$(tunnel_status_remote "$TOKEN" 2>/dev/null || echo '{}')"

  url="$(print -r -- "$STATUS" | json_get publicUrl)"
  direct_url="$(print -r -- "$STATUS" | json_get tunnelUrl)"

  # O relay publico (abc-tunnel.us) e o endpoint estavel; o trycloudflare e
  # o upstream direto e efemero. Testamos os dois.
  for candidate in "$url" "$direct_url"; do
    [[ -n "$candidate" ]] || continue
    # curl imprime o codigo mesmo em falha de rede (000); nao anexar um
    # segundo "000" via `|| echo 000`, senao a comparacao quebra.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${candidate}/api/health" 2>/dev/null)" || true
    code="${code:-000}"
    last_code="$code"
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      log "tunel NOVO: ${candidate}"
      log "resposta: HTTP ${code}  ->  tunel ativo"
      printf 'TUNNEL_URL=%s\n' "$candidate"
      [[ -n "$direct_url" ]] && printf 'TUNNEL_DIRECT_URL=%s\n' "$direct_url"
      assert_tunnel_is_locked "$candidate"
      exit 0
    fi
    log "  ${candidate} -> HTTP ${code} (ainda subindo)"
  done

  # Fallback: le o state.json gravado pelo proprio 9router.
  if [[ -z "$url" ]]; then
    url="$(remote "cat /home/${VENICE_STACK_SSH_USER}/.9router/tunnel/state.json 2>/dev/null" 2>/dev/null \
      | json_get tunnelUrl)"
  fi

  sleep "$INTERVAL"
done

warn "timeout apos ${TIMEOUT}s (ultimo HTTP: ${last_code})"
warn "status atual do tunel:"
tunnel_status_remote "$TOKEN" >&2 || true
exit 1
