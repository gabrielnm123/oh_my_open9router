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
UNC_CMD="auto_select_uncensored_models"

REF_WRAPPER="${BIN_DIR}/refresh-9router-models"
SEL_WRAPPER="${BIN_DIR}/auto-select-9router-models"
UNC_WRAPPER="${BIN_DIR}/auto-select-uncensored-models"
REF_FILE="${CMD_DIR}/${REF_CMD}.md"
SEL_FILE="${CMD_DIR}/${SEL_CMD}.md"
UNC_FILE="${CMD_DIR}/${UNC_CMD}.md"

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
args=(); only=""; have_dry=false
for a in "$@"; do
  case "$a" in
    --apply)   ;;
    --dry-run) have_dry=true; args+=(--dry-run) ;;
    --refresh) args+=(--refresh) ;;
    --prune)   args+=(--prune) ;;
    --only=*)  only="${a#--only=}" ;;
    "")        ;;
    *)         print -u2 "refresh-9router-models: argumento ignorado: $a" ;;
  esac
done
[[ -n "$only" ]] && args+=(--only "$only")
if [[ "$have_dry" == false ]]; then
  args+=(--apply)
fi
exec /usr/bin/env zsh "$SCRIPT" "${args[@]}"
EOF
}

wrapper_select() {
  cat <<'EOF'
#!/usr/bin/env zsh
# GERADO por tools/install-command.sh — não edite à mão.
#
# Regra: a sonda é SEMPRE completa — todos os modelos do catálogo do 9router
# mais todos os nativos do OpenCode, sem filtro e sem subconjunto. As flags que
# reduziriam o universo (--quick, --only-native, --probe-filter) são recusadas.
# O resultado é sempre aplicado (com backup), exceto em --dry-run.
set -euo pipefail
SCRIPT="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/select-models.sh"
[[ -r "$SCRIPT" ]] || { print -u2 "auto-select-9router-models: $SCRIPT ausente (rode zsh tools/install-command.sh)"; exit 1; }
args=(--probe); have_dry=false
while (( $# > 0 )); do
  case "$1" in
    --apply)        shift ;;
    --dry-run)      have_dry=true; args+=(--dry-run); shift ;;
    --probe)        shift ;;
    --no-restart)   args+=(--no-restart); shift ;;
    --restart)      args+=(--restart); shift ;;
    --remote)       args+=(--remote); shift ;;
    --server)
        if (( $# < 2 )) || [[ -z "$2" ]]; then
          print -u2 "auto-select-9router-models: --server exige um valor (usuario@host)"
          exit 2
        fi
        args+=(--server "$2"); shift 2 ;;
    --server=*)     args+=(--server "${1#--server=}"); shift ;;
    --quick|--only-native)
        print -u2 "auto-select-9router-models: $1 ignorado — a sonda é sempre completa (todos os modelos)"
        shift ;;
    --probe-filter)
        print -u2 "auto-select-9router-models: --probe-filter ignorado — a sonda é sempre completa (todos os modelos)"
        (( $# >= 2 )) && shift; shift ;;
    --probe-filter=*)
        print -u2 "auto-select-9router-models: --probe-filter ignorado — a sonda é sempre completa (todos os modelos)"
        shift ;;
    "")             shift ;;
    *)              print -u2 "auto-select-9router-models: argumento ignorado: $1"; shift ;;
  esac
done
if [[ "$have_dry" == false ]]; then
  args+=(--apply)
fi
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
Pinga e testa **todos** os modelos disponíveis (catálogo inteiro do 9router +
todos os nativos do OpenCode), sem filtro e sem subconjunto, escolhe os
melhores por papel (orchestrator, oracle, explorer, designer, fixer, observer,
council + councillors) e **sempre aplica** no
\`~/.config/opencode/oh-my-opencode-slim.json\` com backup.

A varredura completa demora (dezenas de minutos); é o preço de não escolher a
partir de dados velhos ou de um pool reduzido. \`--quick\`, \`--only-native\` e
\`--probe-filter\` são ignorados de propósito.

Por padrão o comando **não** reinicia o daemon: reiniciar de dentro do TUI
derruba a própria sessão (o comando é cancelado antes de responder). Depois de
aplicar, avise o usuário para rodar \`opencode service restart\` (ou reabrir o
app). Se estiver rodando fora do TUI, use \`--restart\`.

Pesquisa e histórico (obrigatório, depois da sonda):
pesquise na web quais modelos aprovados são realmente os melhores para cada
papel (tool calling, raciocínio, contexto, latência) e grave o resultado no
histórico persistente. O histórico é cumulativo e altera a ordenação da
**próxima** execução — uma pesquisa nova pode derrubar um modelo antigo.

\`\`\`
zsh ~/.local/share/9router-tools/model-history.sh record \\
  --model 9router/<id-ou-nativo> --role <papel> --score <0.0-1.0> \\
  --verdict <best|good|weak|bad> --source <URL> --note "<motivo curto>"
zsh ~/.local/share/9router-tools/model-history.sh ranking --role <papel> --limit 15
\`\`\`

Papéis aceitos: orchestrator, oracle, explorer, designer, fixer, observer,
council, council/architect, council/reviewer, council/optimiser,
council/visual, werkzeug, rapido, raciocinio, visao, nao_critico.
Registre pelo menos os 3 primeiros de cada agente alterado. Um modelo com
histórico forte que não respondeu nesta rodada continua como fallback
(marcado \`[histórico]\`) — não o descarte por causa de uma falha isolada.

Saída do seletor:

!\`${SEL_WRAPPER} --no-restart \$ARGUMENTS\`

Responda em português, curto e sem inventar:
1. Quantos testados e quantos aprovados (9router + nativos)
2. Principais mudanças por agente
3. Caminho do backup caso tenha gravado
4. Que o restart do daemon ficou pendente (se houve mudança)
5. Em caso de erro, diga a causa e o próximo passo

Padrão: sonda completa + aplica, sem restart. Use \`--dry-run\` para sondar
tudo e só mostrar o diff, \`--restart\` para reiniciar o daemon.
EOF
}

wrapper_uncensored() {
  cat <<'EOF'
#!/usr/bin/env zsh
# GERADO por tools/install-command.sh — não edite à mão.
#
# Mesma regra do seletor principal: sonda SEMPRE completa, aplica com backup.
set -euo pipefail
SCRIPT="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/select-models-uncensored.sh"
[[ -r "$SCRIPT" ]] || { print -u2 "auto-select-uncensored-models: $SCRIPT ausente (rode zsh tools/install-command.sh)"; exit 1; }
args=(--probe); have_dry=false
while (( $# > 0 )); do
  case "$1" in
    --apply)        shift ;;
    --dry-run)      have_dry=true; args+=(--dry-run); shift ;;
    --probe)        shift ;;
    --no-restart)   args+=(--no-restart); shift ;;
    --restart)      args+=(--restart); shift ;;
    --quick|--only-native)
        print -u2 "auto-select-uncensored-models: $1 ignorado — a sonda é sempre completa (todos os modelos)"
        shift ;;
    --probe-filter)
        print -u2 "auto-select-uncensored-models: --probe-filter ignorado — a sonda é sempre completa (todos os modelos)"
        (( $# >= 2 )) && shift; shift ;;
    --probe-filter=*)
        print -u2 "auto-select-uncensored-models: --probe-filter ignorado — a sonda é sempre completa (todos os modelos)"
        shift ;;
    "")             shift ;;
    *)              print -u2 "auto-select-uncensored-models: argumento ignorado: $1"; shift ;;
  esac
done
if [[ "$have_dry" == false ]]; then
  args+=(--apply)
fi
exec /usr/bin/env zsh "$SCRIPT" "${args[@]}"
EOF
}

cmd_uncensored() {
  cat <<EOF
---
description: Seleciona modelos menos censurados (cx/, Grok, Nous, Nemotron) para todos os agentes
---
Sonda e distribui os modelos mais próximos de "uncensored" disponíveis no
9router (e nativos), priorizando: **cx/** → **gcli/** (Grok) → **nous/**
(Hermes/Dolphin) → **kc/nvidia/** (Nemotron) → **ag/** → **kc/** → **gh/**
→ nativos OpenCode.

Por padrão o comando **não** reinicia o daemon (reiniciar de dentro do TUI
derruba a própria sessão). Depois de aplicar, rode \`opencode service restart\`.
Se estiver fora do TUI, use \`--restart\`.

Pesquisa e histórico (obrigatório, depois da sonda):
pesquise na web quais modelos aprovados são os melhores para cada papel
**e** quais recusam menos (censura/refusal, alinhamento, jailbreak conhecido),
e grave no histórico persistente:

\`\`\`
zsh ~/.local/share/9router-tools/model-history.sh record \\
  --model 9router/<id-ou-nativo> --role <papel> --score <0.0-1.0> \\
  --verdict <best|good|weak|bad> --source <URL> --note "<motivo curto>"
zsh ~/.local/share/9router-tools/model-history.sh ranking --role <papel> --limit 15
\`\`\`

Papéis aceitos: orchestrator, oracle, explorer, designer, fixer, observer,
council, council/architect, council/reviewer, council/optimiser,
council/visual, werkzeug, rapido, raciocinio, visao, nao_critico.
O histórico é cumulativo, muda o ranking da próxima execução e preserva como
fallback (\`[histórico]\`) um modelo forte que não respondeu agora.

Saída do seletor:

!\`${UNC_WRAPPER} --no-restart \$ARGUMENTS\`

Responda em português, curto e sem inventar:
1. Quantos testados e quantos aprovados
2. Família dominante escolhida por agente (ex.: cx/, gcli/, nous/)
3. Principais mudanças por agente
4. Caminho do backup caso tenha gravado
5. Que o restart do daemon ficou pendente (se houve mudança)
6. Em caso de erro, diga a causa e o próximo passo

Padrão: sonda completa + aplica com \`--no-restart\`. Use \`--dry-run\` para só
mostrar o diff, \`--restart\` para reiniciar o daemon. \`--quick\`,
\`--only-native\` e \`--probe-filter\` são recusados: o universo é sempre inteiro.
EOF
}


do_install() {
  for f in "${ROOT}/tools/sync-catalog.sh" "${ROOT}/tools/select-models.sh" \
           "${ROOT}/tools/select-models-uncensored.sh" "${ROOT}/tools/probe-models.sh" \
           "${ROOT}/tools/model-history.sh" "${ROOT}/tools/lib/venice-env.sh"; do
    [[ -r "$f" ]] || { log "ERRO: $f não encontrado"; exit 1; }
  done
  mkdir -p "$DATA_DIR/lib" "$BIN_DIR" "$CMD_DIR"
  install_file "${ROOT}/tools/sync-catalog.sh"   "${DATA_DIR}/sync-catalog.sh"   0755
  install_file "${ROOT}/tools/select-models.sh"  "${DATA_DIR}/select-models.sh"  0755
  install_file "${ROOT}/tools/probe-models.sh"   "${DATA_DIR}/probe-models.sh"   0755
  install_file "${ROOT}/tools/lib/venice-env.sh" "${DATA_DIR}/lib/venice-env.sh" 0644
  install_file "${ROOT}/tools/select-models-uncensored.sh" "${DATA_DIR}/select-models-uncensored.sh" 0755
  install_file "${ROOT}/tools/model-history.sh"  "${DATA_DIR}/model-history.sh"  0755
  # Histórico já acumulado no repo (execução manual) vira semente do instalado,
  # mas nunca sobrescreve um histórico instalado mais novo.
  if [[ -f "${ROOT}/model-history.json" && ! -f "${DATA_DIR}/model-history.json" ]]; then
    cp "${ROOT}/model-history.json" "${DATA_DIR}/model-history.json"
    chmod 600 "${DATA_DIR}/model-history.json"
    log "semeado: ${DATA_DIR}/model-history.json (a partir do repo)"
  fi
  write_generated "$REF_WRAPPER" 0755 wrapper_refresh
  write_generated "$SEL_WRAPPER" 0755 wrapper_select
  write_generated "$UNC_WRAPPER" 0755 wrapper_uncensored
  write_generated "$REF_FILE"    0644 cmd_refresh
  write_generated "$SEL_FILE"    0644 cmd_select
  write_generated "$UNC_FILE"    0644 cmd_uncensored
  log "pronto. No TUI: /${REF_CMD} | /${SEL_CMD} | /${UNC_CMD}"
  log "CLI: ${REF_WRAPPER} | ${SEL_WRAPPER} | ${UNC_WRAPPER} --dry-run"
}

do_uninstall() {
  local n=0
  for f in "$REF_WRAPPER" "$SEL_WRAPPER" "$UNC_WRAPPER" "$REF_FILE" "$SEL_FILE" "$UNC_FILE"; do
    [[ -e "$f" ]] && { rm -f "$f"; log "removido: $f"; n=1; }
  done
  if [[ -f "${DATA_DIR}/model-history.json" ]]; then
    log "preservado: ${DATA_DIR}/model-history.json (histórico de modelos)"
  fi
  if [[ -d "$DATA_DIR" ]]; then
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -name 'model-history.json' -exec rm -rf {} +
    log "removido: $DATA_DIR (exceto o histórico)"
    n=1
  fi
  (( n )) || log "nada instalado"
}

do_status() {
  log "repo: $ROOT"
  for f in "$DATA_DIR/sync-catalog.sh" "$DATA_DIR/select-models.sh" "$DATA_DIR/select-models-uncensored.sh" "$DATA_DIR/probe-models.sh" "$DATA_DIR/model-history.sh" "$DATA_DIR/lib/venice-env.sh" "$REF_WRAPPER" "$SEL_WRAPPER" "$UNC_WRAPPER" "$REF_FILE" "$SEL_FILE" "$UNC_FILE"; do
    [[ -e "$f" ]] && printf '  [ok]  %s\n' "$f" || printf '  [--]  %s\n' "$f"
  done
  local hist="${DATA_DIR}/model-history.json"
  if [[ -f "$hist" ]]; then
    printf '  [ok]  %s (%s modelos)\n' "$hist" \
      "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("models",{})))' "$hist" 2>/dev/null || echo '?')"
  else
    printf '  [--]  %s (histórico ainda vazio)\n' "$hist"
  fi
}

do_print() {
  echo "### $REF_WRAPPER"; wrapper_refresh; echo; echo "### $SEL_WRAPPER"; wrapper_select; echo; echo "### $UNC_WRAPPER"; wrapper_uncensored; echo; echo "### $REF_FILE"; cmd_refresh; echo; echo "### $SEL_FILE"; cmd_select; echo; echo "### $UNC_FILE"; cmd_uncensored
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  print)     do_print ;;
  *) log "ação desconhecida: $ACTION"; exit 1 ;;
esac
