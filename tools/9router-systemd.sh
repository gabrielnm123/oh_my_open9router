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
#   NINEROUTER_SSH_HOST   (default: ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST})
#   NINEROUTER_SERVICE    (default: 9router.service)

set -euo pipefail

SSH_HOST="${NINEROUTER_SSH_HOST:-${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}}"
SERVICE="${NINEROUTER_SERVICE:-9router.service}"
ACTION="${1:-install}"

log() { printf '[9router-systemd] %s\n' "$*"; }
die() { printf '[9router-systemd] ERRO: %s\n' "$*" >&2; exit 1; }

# Roda um script bash no servidor remoto via stdin (evita quoting hell).
# As variaveis de contexto vao por ambiente, com o script em heredoc quoted.
# O usuario '${VENICE_STACK_SSH_USER}' tem sudo NOPASSWD no servidor (verificado na Fase 0);
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
DATA_DIR="/home/${VENICE_STACK_SSH_USER}/.9router"
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
D="/home/${VENICE_STACK_SSH_USER}/.9router"
BASE="http://127.0.0.1:20128"

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
User=${VENICE_STACK_SSH_USER}
Group=${VENICE_STACK_SSH_USER}
WorkingDirectory=/usr/local/lib/node_modules/9router/app

# Valores base. O .env (EnvironmentFile) vem DEPOIS e tem precedencia.
Environment=NODE_ENV=production
Environment=PORT=20128
Environment=HOSTNAME=127.0.0.1
Environment=DATA_DIR=/home/${VENICE_STACK_SSH_USER}/.9router
Environment=NODE_PATH=/home/${VENICE_STACK_SSH_USER}/.9router/runtime/node_modules:/usr/local/lib/node_modules/9router/app/node_modules

# Hardening / secrets (Fase 0.3). Falha fechada: .env ausente = servico nao sobe.
EnvironmentFile=/home/${VENICE_STACK_SSH_USER}/.9router/.env

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
ExecStartPost=/bin/sh -c '/home/${VENICE_STACK_SSH_USER}/.9router/bin/ensure-tunnel.sh >>/home/${VENICE_STACK_SSH_USER}/.9router/logs/ensure-tunnel.log 2>&1 &'

# --- Sandbox ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/${VENICE_STACK_SSH_USER}/.9router
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
