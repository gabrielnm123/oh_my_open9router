#!/usr/bin/env zsh
# tools/install-command.sh
#
# Instala os comandos globais do OpenCode:
#   /refresh_models_9router
#   /auto_select_models_oh_my_opencode_slim
#
# Idempotente, funciona de qualquer diretório. Usa ~/.config/venice-stack/9router.env
# como fallback de credenciais quando necessário.

set -euo pipefail

ROOT="${0:A:h:h}"

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools"
BIN_DIR="${XDG_BIN_HOME:-${HOME}/.local/bin}"
CMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/commands"

REF_CMD="refresh_models_9router"
SEL_CMD="auto_select_models_oh_my_opencode_slim"

REF_WRAPPER="${BIN_DIR}/refresh-9router-models"
SEL_WRAPPER="${BIN_DIR}/auto-select-9router-models"
REF_FILE="${CMD_DIR}/${REF_CMD}.md"
SEL_FILE="${CMD_DIR}/${SEL_CMD}.md"

ACTION="${1:-install}"
[[ "$ACTION" == "--print" ]] && ACTION="print"

log()  { printf '[install-command] %s\n' "$*" }
warn() { printf '[install-command] AVISO: %s\n' "$*" >&2 }

install_file() {
  local src="$1" dst="$2" mode="$3"
  [[ -r "$src" ]] || { warn "fonte ausente: $src"; return 1; }
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    log "ok (já atualizado): $dst"; return 0
  fi
  mkdir -p "${dst:h}"
  cp "$src" "$dst"; chmod "$mode" "$dst"
  log "instalado: $dst"
}

write_generated() {
  local dst="$1" mode="$2" fn="$3"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/install-cmd.XXXXXX")"
  "$fn" > "$tmp"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; chmod "$mode" "$dst" 2>/dev/null || true
    log "ok (já atualizado): $dst"; return 0
  fi
  mkdir -p "${dst:h}"; mv "$tmp" "$dst"; chmod "$mode" "$dst"
  log "gerado: $dst"
}

wrapper_refresh() {
  cat <<'EOF'
#!/usr/bin/env zsh
# GERADO por tools/install-command.sh — não edite à mão.
set -euo pipefail
SCRIPT="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/sync-catalog.sh"
[[ -r "$SCRIPT" ]] || { print -u2 "refresh-9router-models: $SCRIPT ausente (rode zsh tools/install-command.sh)"; exit 1; }
args=(); only=""; have_apply=false
for a in "$@"; do
  case "$a" in
    --apply)   have_apply=true; args+=(--apply) ;;
    --dry-run) args+=(--dry-run) ;;
    --refresh) args+=(--refresh) ;;
    --prune)   args+=(--prune) ;;
    --only=*)  only="${a#--only=}" ;;
    "")        ;;
    *)         print -u2 "refresh-9router-models: argumento ignorado: $a" ;;
  esac
done
[[ -n "$only" ]] && args+=(--only "$only")
(( $# == 0 || $have_apply )) && args+=(--apply)
exec /usr/bin/env zsh "$SCRIPT" "${args[@]}"
EOF
}

wrapper_select() {
  cat <<'EOF'
#!/usr/bin/env zsh
# GERADO por tools/install-command.sh — não edite à mão.
set -euo pipefail
SCRIPT="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/select-models.sh"
[[ -r "$SCRIPT" ]] || { print -u2 "auto-select-9router-models: $SCRIPT ausente (rode zsh tools/install-command.sh)"; exit 1; }
args=()
for a in "$@"; do
  case "$a" in
    --apply)           args+=(--apply) ;;
    --dry-run)         args+=(--dry-run) ;;
    --probe)           args+=(--probe) ;;
    --quick)           args+=(--quick) ;;
    --only-native)     args+=(--only-native) ;;
    --no-restart)      args+=(--no-restart) ;;
    --restart)         args+=(--restart) ;;
    --probe-filter=*)  args+=(--probe-filter "${a#--probe-filter=}") ;;
    "")                ;;
    *)                 print -u2 "auto-select-9router-models: argumento ignorado: $a" ;;
  esac
done
(( $# == 0 )) && args+=(--apply)
exec /usr/bin/env zsh "$SCRIPT" "${args[@]}"
EOF
}

cmd_refresh() {
  cat <<EOF
---
description: Atualiza os modelos do 9router no OpenCode (sincroniza opencode.json com o catálogo vivo)
---
Sincronize o catálogo de modelos do 9router com o \`opencode.json\`.

Saída do sincronizador:

!\`${REF_WRAPPER} \$ARGUMENTS\`

Responda em português, curto e sem inventar:
1. Quantos modelos no catálogo e quantos no \`opencode.json\`
2. Adicionados/removidos ou "nada a fazer"
3. Caminho do backup caso tenha gravado
4. Em caso de erro, diga a causa e o próximo passo

Use \`--dry-run\` para revisar. Padrão: aplica.
EOF
}

cmd_select() {
  cat <<EOF
---
description: Auto-seleciona os melhores modelos para todos os agentes do oh-my-opencode-slim
---
Pinga e testa todos os modelos disponíveis (9router + nativos do OpenCode),
escolhe os melhores por papel (orchestrator, oracle, explorer, designer,
fixer, observer, council + councillors) e aplica no
\`~/.config/opencode/oh-my-opencode-slim.json\` com backup + reset do daemon
quando necessário.

Saída do seletor:

!\`${SEL_WRAPPER} \$ARGUMENTS\`

Responda em português, curto e sem inventar:
1. Quantos testados e quantos aprovados (9router + nativos)
2. Principais mudanças por agente
3. Caminho do backup caso tenha gravado
4. Daemon reiniciado? (sim/não)
5. Em caso de erro, diga a causa e o próximo passo

Padrão: aplica. Use \`--dry-run\` para só mostrar, \`--quick\` para varredura mais rápida.
EOF
}

do_install() {
  for f in "${ROOT}/tools/sync-catalog.sh" "${ROOT}/tools/select-models.sh" "${ROOT}/tools/probe-models.sh" "${ROOT}/tools/lib/venice-env.sh"; do
    [[ -r "$f" ]] || { log "ERRO: $f não encontrado"; exit 1; }
  done
  mkdir -p "$DATA_DIR/lib" "$BIN_DIR" "$CMD_DIR"
  install_file "${ROOT}/tools/sync-catalog.sh"   "${DATA_DIR}/sync-catalog.sh"   0755
  install_file "${ROOT}/tools/select-models.sh"  "${DATA_DIR}/select-models.sh"  0755
  install_file "${ROOT}/tools/probe-models.sh"   "${DATA_DIR}/probe-models.sh"   0755
  install_file "${ROOT}/tools/lib/venice-env.sh" "${DATA_DIR}/lib/venice-env.sh" 0644
  write_generated "$REF_WRAPPER" 0755 wrapper_refresh
  write_generated "$SEL_WRAPPER" 0755 wrapper_select
  write_generated "$REF_FILE"    0644 cmd_refresh
  write_generated "$SEL_FILE"    0644 cmd_select
  log "pronto. No TUI: /${REF_CMD} | /${SEL_CMD}"
  log "CLI: ${REF_WRAPPER} --dry-run | ${SEL_WRAPPER} --dry-run"
}

do_uninstall() {
  local n=0
  for f in "$REF_WRAPPER" "$SEL_WRAPPER" "$REF_FILE" "$SEL_FILE"; do
    [[ -e "$f" ]] && { rm -f "$f"; log "removido: $f"; n=1; }
  done
  [[ -d "$DATA_DIR" ]] && { rm -rf "$DATA_DIR"; log "removido: $DATA_DIR"; n=1; }
  (( n )) || log "nada instalado"
}

do_status() {
  log "repo: $ROOT"
  for f in "$DATA_DIR/sync-catalog.sh" "$DATA_DIR/select-models.sh" "$DATA_DIR/probe-models.sh" "$DATA_DIR/lib/venice-env.sh" "$REF_WRAPPER" "$SEL_WRAPPER" "$REF_FILE" "$SEL_FILE"; do
    [[ -e "$f" ]] && printf '  [ok]  %s\n' "$f" || printf '  [--]  %s\n' "$f"
  done
}

do_print() {
  echo "### $REF_WRAPPER"; wrapper_refresh; echo; echo "### $SEL_WRAPPER"; wrapper_select; echo; echo "### $REF_FILE"; cmd_refresh; echo; echo "### $SEL_FILE"; cmd_select
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  print)     do_print ;;
  *) log "ação desconhecida: $ACTION"; exit 1 ;;
esac
