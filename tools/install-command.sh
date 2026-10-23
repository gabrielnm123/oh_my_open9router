#!/usr/bin/env zsh
# tools/install-command.sh
#
# Instala o comando global `/refresh_models_9router` no OpenCode, de forma que
# ele funcione em QUALQUER diretorio — o operador nao precisa estar dentro
# deste repositorio para atualizar o catalogo de modelos.
#
# O que e instalado:
#
#   ${XDG_DATA_HOME:-~/.local/share}/9router-tools/
#       sync-catalog.sh          copia de tools/sync-catalog.sh
#       lib/venice-env.sh        copia de tools/lib/venice-env.sh
#
#   ${XDG_BIN_HOME:-~/.local/bin}/refresh-9router-models
#       wrapper: valida as flags recebidas e chama o sync-catalog.sh instalado
#
#   ${XDG_CONFIG_HOME:-~/.config}/opencode/commands/refresh_models_9router.md
#       arquivo de comando do OpenCode (barra, no TUI) que roda o wrapper
#
# Credenciais: o script instalado roda FORA do repositorio, entao nao existe
# `.env` ao lado dele. A URL e a chave vem do ambiente ou, como fallback, da
# copia canonica `~/.config/venice-stack/9router.env` (600) — ver
# `tools/lib/venice-env.sh`. Nada de segredo e copiado para dentro do comando.
#
# Uso (local, zsh):
#   zsh tools/install-command.sh              # instala/atualiza
#   zsh tools/install-command.sh status       # mostra o que esta instalado
#   zsh tools/install-command.sh uninstall    # remove tudo o que instalou
#   zsh tools/install-command.sh --print      # so imprime os arquivos gerados
#
# Idempotente: rodar duas vezes nao duplica nada; copias sao comparadas por
# conteudo antes de gravar.

set -euo pipefail

ROOT="${0:A:h:h}"

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools"
BIN_DIR="${XDG_BIN_HOME:-${HOME}/.local/bin}"
CMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/commands"
CMD_NAME="refresh_models_9router"
WRAPPER="${BIN_DIR}/refresh-9router-models"
CMD_FILE="${CMD_DIR}/${CMD_NAME}.md"

ACTION="${1:-install}"
[[ "$ACTION" == "--print" ]] && ACTION="print"

log() { printf '[install-command] %s\n' "$*" }

# ------------------------------------------------------------ arquivos gerados --

wrapper_body() {
  cat <<EOF
#!/usr/bin/env zsh
# GERADO por tools/install-command.sh — nao edite a mao.
#
# Atualiza \`providers.9router.models\` do opencode.json a partir do catalogo
# vivo do 9router. Funciona de qualquer diretorio.
#
# Sem argumentos: aplica (--apply). Flags aceitas:
#   --apply | --dry-run | --refresh | --prune | --only=<prefixo[,prefixo]>
#
# Qualquer outro argumento e ignorado com aviso (o bloco de shell do comando
# do OpenCode recebe texto livre; nao repassamos isso ao shell).

set -euo pipefail

SCRIPT="${DATA_DIR}/sync-catalog.sh"
[[ -r "\$SCRIPT" ]] || { print -u2 "refresh-9router-models: \$SCRIPT ausente; rode zsh tools/install-command.sh"; exit 1; }

args=()
only_prefixes=""
have_apply=false
for a in "\$@"; do
  case "\$a" in
    --apply)   have_apply=true; args+=(--apply) ;;
    --dry-run) args+=(--dry-run) ;;
    --refresh) args+=(--refresh) ;;
    --prune)   args+=(--prune) ;;
    --only=*)  only_prefixes="\${a#--only=}" ;;
    "")        ;;
    *)         print -u2 "refresh-9router-models: argumento ignorado: \$a" ;;
  esac
done

if [[ -n "\$only_prefixes" ]]; then
  args+=(--only "\$only_prefixes")
fi

# Padrao do comando global: aplicar. \`--dry-run\` desliga o apply.
if (( \${#args[@]} == 0 )) || \$have_apply; then
  args+=(--apply)
fi

exec /usr/bin/env zsh "\$SCRIPT" "\${args[@]}"
EOF
}

command_body() {
  cat <<EOF
---
description: Atualiza os modelos do 9router no OpenCode (sincroniza opencode.json com o catálogo vivo)
---
Sincronize o catálogo de modelos do 9router com o arquivo de configuração do
OpenCode, para que todo modelo novo do \`/v1/models\` apareça em \`/models\`.

Saída do sincronizador:

!\`${WRAPPER} \$ARGUMENTS\`

Responda em português, curto e sem inventar:

1. quantos modelos o catálogo tem e quantos estão no \`opencode.json\` agora;
2. quais foram adicionados e quais foram removidos (ou "nada a fazer" se já
   estava em sincronia);
3. o caminho do backup, quando houve escrita;
4. se houver erro (chave ausente, túnel fora do ar, HTTP != 200), diga a causa
   provável e o próximo passo — nunca afirme que atualizou sem a linha de
   confirmação do script.

Se o usuário pedir para revisar sem gravar, rode com \`--dry-run\`.
EOF
}

install_file() {
  local src="$1" dst="$2" mode="$3"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst"
    log "ok (já atualizado): $dst"
    return
  fi
  mkdir -p "${dst:h}"
  cp "$src" "$dst"
  chmod "$mode" "$dst"
  log "instalado: $dst"
}

write_generated() {
  local dst="$1" mode="$2" body_fn="$3"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/install-command.XXXXXX")"
  "$body_fn" > "$tmp"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; chmod "$mode" "$dst"
    log "ok (já atualizado): $dst"
    return
  fi
  mkdir -p "${dst:h}"
  mv "$tmp" "$dst"
  chmod "$mode" "$dst"
  log "gerado: $dst"
}

# ------------------------------------------------------------------- acoes ----

do_install() {
  [[ -r "${ROOT}/tools/sync-catalog.sh" ]] || {
    log "ERRO: ${ROOT}/tools/sync-catalog.sh não encontrado (rode de dentro do repo)"; exit 1 }

  install_file "${ROOT}/tools/sync-catalog.sh"    "${DATA_DIR}/sync-catalog.sh"    0755
  install_file "${ROOT}/tools/lib/venice-env.sh"  "${DATA_DIR}/lib/venice-env.sh"  0644
  write_generated "${WRAPPER}" 0755 wrapper_body
  write_generated "${CMD_FILE}" 0644 command_body

  log "pronto. No TUI do OpenCode: /${CMD_NAME}  (aceita --dry-run, --prune, --refresh, --only=prefixo)"
  log "fora do OpenCode: ${WRAPPER} --dry-run"
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) log "AVISO: ${BIN_DIR} não está no PATH (o comando do OpenCode usa caminho absoluto, então funciona mesmo assim)" ;;
  esac
}

do_uninstall() {
  local removed=0
  for f in "$WRAPPER" "$CMD_FILE"; do
    if [[ -e "$f" ]]; then rm -f "$f"; log "removido: $f"; removed=1; fi
  done
  if [[ -d "$DATA_DIR" ]]; then rm -rf "$DATA_DIR"; log "removido: $DATA_DIR"; removed=1; fi
  (( removed )) || log "nada instalado"
}

do_status() {
  log "repo:   ${ROOT}"
  for f in "$DATA_DIR/sync-catalog.sh" "$DATA_DIR/lib/venice-env.sh" "$WRAPPER" "$CMD_FILE"; do
    if [[ -e "$f" ]]; then
      printf '  [ok]  %s\n' "$f"
    else
      printf '  [--]  %s\n' "$f"
    fi
  done
}

do_print() {
  printf '### %s\n' "$WRAPPER"; wrapper_body
  printf '\n### %s\n' "$CMD_FILE"; command_body
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  print)     do_print ;;
  *) log "ação desconhecida: $ACTION (use install | status | uninstall | --print)"; exit 1 ;;
esac
