#!/usr/bin/env zsh
# tools/9router-systemd.sh
#
# Instala / atualiza a unidade systemd do 9router no servidor remoto.
# Idempotente: pode ser reexecutado a qualquer momento sem efeito colateral.
#
# Uso:
#   zsh tools/9router-systemd.sh install     # (re)escreve a unit + daemon-reload + enable + restart
#   zsh tools/9router-systemd.sh status      # mostra status/journal sem alterar nada
#   zsh tools/9router-systemd.sh uninstall   # para e remove a unit
#
# Variaveis de ambiente:
#   NINEROUTER_SSH_HOST   (formato user@host; se ausente, montado a partir de
#                          VENICE_STACK_SSH_USER + VENICE_STACK_SSH_HOST do .env)
#   NINEROUTER_SERVICE    (default: 9router.service)

set -euo pipefail

# Carrega o .env da raiz do projeto (fonte da verdade; gitignored, 600).
VENICE_PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/venice-env.sh"

# Destino SSH. Nao ha host real hardcoded no repositorio: vem do ambiente ou
# do .env (veja .env.example).
if [[ -n "${NINEROUTER_SSH_HOST:-}" ]]; then
  SSH_HOST="${NINEROUTER_SSH_HOST}"
elif [[ -n "${VENICE_STACK_SSH_HOST:-}" && -n "${VENICE_STACK_SSH_USER:-}" ]]; then
  SSH_HOST="${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}"
else
  printf '[9router-systemd] ERRO: host SSH indefinido (defina VENICE_STACK_SSH_HOST e VENICE_STACK_SSH_USER no .env)\n' >&2
  exit 1
fi
SERVICE="${NINEROUTER_SERVICE:-9router.service}"
ACTION="${1:-install}"

log() { printf '[9router-systemd] %s\n' "$*"; }
die() { printf '[9router-systemd] ERRO: %s\n' "$*" >&2; exit 1; }

# Roda um script bash no servidor remoto via stdin (evita quoting hell).
# As variaveis de contexto vao por ambiente, com o script em heredoc quoted.
# O usuario de servico tem sudo NOPASSWD no servidor (verificado na Fase 0);
# por isso o script remoto pode usar `sudo -n` onde precisa de privilegio.
remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
    "env N9R_SERVICE='${SERVICE}' bash -s"
}

case "$ACTION" in
  install)
    log "instalando ${SERVICE} em ${SSH_HOST}"

    remote <<'REMOTE'
set -euo pipefail
SERVICE="${N9R_SERVICE}"
# O diretorio de dados e o HOME do usuario remoto: o repositorio nao carrega
# nome de usuario nem caminho absoluto da maquina.
DATA_DIR="${HOME}/.9router"
# Usuario e grupo do servico: derivados de quem esta executando o script.
SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
APP_DIR="/usr/local/lib/node_modules/9router/app"
NODE_BIN="/usr/bin/node"
UNIT="/etc/systemd/system/${SERVICE}"
HELPER="${DATA_DIR}/bin/ensure-tunnel.sh"

test -f "${DATA_DIR}/.env" || { echo "ERRO: ${DATA_DIR}/.env ausente (Fase 0.3 nao aplicada)"; exit 1; }
test -x "${NODE_BIN}"        || { echo "ERRO: node ausente"; exit 1; }
test -f "${APP_DIR}/custom-server.js" || { echo "ERRO: app do 9router ausente"; exit 1; }

# --------------------------------------------------------------------------
# Helper de resiliencia do tunel.
#
# O app do 9router so retoma o tunel quando initializeApp() roda, o que nao
# acontece no boot do standalone. Sem isto, um restart do servico deixa o
# tunel caido. O helper chama a rota NATIVA /api/tunnel/enable (nada de
# cloudflared paralelo) em background, logo apos o servico subir.
# --------------------------------------------------------------------------
mkdir -p "${DATA_DIR}/bin" "${DATA_DIR}/logs"
cat > "${HELPER}" <<'HELPER_EOF'
#!/usr/bin/env bash
# Garante o tunel nativo do 9router apos o servico subir.
# Deriva o token CLI do proprio app:
#   sha256(machine-id + "9r-cli-auth" + cli-secret)[:16]
set -uo pipefail
# O diretorio de dados e o HOME do usuario que executa o helper.
D="${HOME}/.9router"
BASE="http://127.0.0.1:20128"

# NOTA: este heredoc e QUOTED (<<'HELPER_EOF'), logo o texto abaixo e
# gravado LITERALMENTE no helper. Nao escapar o '$' com barra invertida --
# a barra viraria um caractere real e o bash quebraria com
# "syntax error near unexpected token `('".
#
# 1) Aguarda o gateway aceitar conexoes (o ExecStartPost roda logo apos o
#    start, entao o next-server pode ainda nao estar escutando).
echo "[ensure-tunnel] $(date -Is) aguardando o gateway em ${BASE}"
for _ in $(seq 1 60); do
  if curl -sf --max-time 3 -o /dev/null "${BASE}/api/health"; then
    echo "[ensure-tunnel] gateway pronto"
    break
  fi
  sleep 2
done

MID="$(cat "${D}/machine-id" 2>/dev/null || true)"
SEC="$(cat "${D}/auth/cli-secret" 2>/dev/null || true)"
[[ -n "${MID}" && -n "${SEC}" ]] || { echo "[ensure-tunnel] sem machine-id/cli-secret"; exit 0; }
TOKEN="$(printf '%s' "${MID}9r-cli-auth${SEC}" | sha256sum | cut -c1-16)"

echo "[ensure-tunnel] $(date -Is) forcando POST /api/tunnel/enable"
RESP="$(curl -s --max-time 150 -X POST -H "x-9r-cli-token: ${TOKEN}" "${BASE}/api/tunnel/enable" 2>&1)"
echo "[ensure-tunnel] resposta: ${RESP:0:300}"

# A rota pode responder "Health check timeout" mesmo com o tunel no ar
# (o relay abc-tunnel.us propaga em >60s). O estado real e o /api/tunnel/status.
ST="$(curl -s --max-time 20 -H "x-9r-cli-token: ${TOKEN}" "${BASE}/api/tunnel/status" 2>&1)"
echo "[ensure-tunnel] status: ${ST:0:400}"

# 3) Aguarda o tunel ficar realmente "running" (max 90s).
for _ in $(seq 1 30); do
  ST="$(curl -s --max-time 20 -H "x-9r-cli-token: ${TOKEN}" "${BASE}/api/tunnel/status" 2>&1)"
  case "${ST}" in
    *'"running":true'*) echo "[ensure-tunnel] tunel ativo"; break ;;
  esac
  sleep 3
done
echo "[ensure-tunnel] status final: ${ST:0:400}"

# Nao falha a unit: o tunel e acessorio, o gateway e o essencial.
exit 0
HELPER_EOF
chmod 700 "${HELPER}"

# --------------------------------------------------------------------------
# Unit
# --------------------------------------------------------------------------
TMP_UNIT="$(mktemp /tmp/9router-unit.XXXXXX)"
trap 'rm -f "${TMP_UNIT}"' EXIT
cat > "${TMP_UNIT}" <<'UNIT_EOF'
[Unit]
Description=9Router - gateway de IA (headless, sem dashboard obrigatorio)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
# Substituidos por sed na geracao da unit (ver abaixo): o repositorio nao
# carrega o nome do usuario do servidor.
User=@SERVICE_USER@
Group=@SERVICE_GROUP@
WorkingDirectory=/usr/local/lib/node_modules/9router/app

# Valores base. O .env (EnvironmentFile) vem DEPOIS e tem precedencia.
Environment=NODE_ENV=production
Environment=PORT=20128
Environment=HOSTNAME=127.0.0.1
Environment=DATA_DIR=@DATA_DIR@
Environment=NODE_PATH=@DATA_DIR@/runtime/node_modules:/usr/local/lib/node_modules/9router/app/node_modules

# Hardening / secrets (Fase 0.3). Falha fechada: .env ausente = servico nao sobe.
EnvironmentFile=@DATA_DIR@/.env

# O app (custom-server.js) sobe o next-server e gerencia o tunel cloudflared.
ExecStart=/usr/bin/node --dns-result-order=ipv4first --max-old-space-size=384 /usr/local/lib/node_modules/9router/app/custom-server.js
Restart=always
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=20
KillSignal=SIGTERM
KillMode=control-group
UMask=0077

# Retoma o tunel nativo em background logo apos o servico subir.
# (& no shell => nao bloqueia o "active" da unit; o helper nunca falha a unit.)
ExecStartPost=/bin/sh -c '@DATA_DIR@/bin/ensure-tunnel.sh >>@DATA_DIR@/logs/ensure-tunnel.log 2>&1 &'

# --- Sandbox ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=@DATA_DIR@
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryMax=600M
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT_EOF

# O heredoc acima e quoted (literal), entao os placeholders @TOKEN@ chegam
# intactos ate aqui. Substituimos pelos valores reais do servidor.
# | como delimitador: os valores contem "/" (caminhos) e nao contem "|".
sed -i \
  -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
  -e "s|@SERVICE_GROUP@|${SERVICE_GROUP}|g" \
  -e "s|@DATA_DIR@|${DATA_DIR}|g" \
  "${TMP_UNIT}"

# Sanidade: nenhum placeholder deve sobrar na unit gerada.
if grep -q '@[A-Z_]*@' "${TMP_UNIT}"; then
  echo "ERRO: placeholders nao substituidos na unit:" >&2
  grep -o '@[A-Z_]*@' "${TMP_UNIT}" | sort -u >&2
  exit 1
fi

chmod 644 "${TMP_UNIT}"
sudo -n install -m 644 -o root -g root "${TMP_UNIT}" "${UNIT}"
sudo -n systemctl daemon-reload
sudo -n systemctl enable "${SERVICE}" >/dev/null
sudo -n systemctl restart "${SERVICE}"
sleep 6
printf 'enabled=%s\n' "$(systemctl is-enabled "${SERVICE}")"
printf 'active=%s\n'  "$(systemctl is-active  "${SERVICE}")"
REMOTE
    log "instalado."
    ;;

  status)
    remote <<'REMOTE'
set -uo pipefail
SERVICE="${N9R_SERVICE}"
sudo -n systemctl is-enabled "${SERVICE}" 2>&1
sudo -n systemctl is-active "${SERVICE}" 2>&1
echo "=== systemctl status ==="
sudo -n systemctl status "${SERVICE}" --no-pager -n 20 2>&1
echo "=== porta 20128 ==="
ss -tlnp 2>/dev/null | grep 20128 || echo "(nao escutando)"
echo "=== journal (ultimas 30 linhas) ==="
sudo -n journalctl -u "${SERVICE}" --no-pager -n 30 2>&1
REMOTE
    ;;

  uninstall)
    log "removendo ${SERVICE}"
    remote <<'REMOTE'
set -uo pipefail
SERVICE="${N9R_SERVICE}"
sudo -n systemctl disable --now "${SERVICE}" 2>&1 || true
sudo -n rm -f "/etc/systemd/system/${SERVICE}"
sudo -n systemctl daemon-reload
sudo -n systemctl reset-failed "${SERVICE}" 2>&1 || true
echo "removido."
REMOTE
    ;;

  *)
    die "acao desconhecida: $ACTION (use install|status|uninstall)"
    ;;
esac
