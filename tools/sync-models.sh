#!/usr/bin/env zsh
# tools/sync-models.sh
# Sincroniza oh-my-opencode-slim.json com modelos aprovados pela sonda.
# Uso: zsh tools/sync-models.sh [--apply]

set -euo pipefail

source "${0:A:h}/lib/venice-env.sh"

PROBE_OUT="probe.jsonl"
CONFIG="${HOME}/.config/opencode/oh-my-opencode-slim.json"
APPLY=false

[[ "${1:-}" == "--apply" ]] && APPLY=true

# --- 1. Roda a sonda se probe.jsonl não existe ou tem mais de 1h ---
if [[ ! -f "$PROBE_OUT" ]] || (( $(date +%s) - $(stat -c %Y "$PROBE_OUT" 2>/dev/null || echo 0) > 3600 )); then
  echo "[sync] rodando sonda..."
  zsh tools/probe-models.sh --concurrency 6 --out "$PROBE_OUT" >/dev/null
fi

# --- 2. Extrai modelos aprovados (HTTP 200 + tool calling) ---
APPROVED=()
while IFS= read -r line; do
  model=$(echo "$line" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('http_status') == 200 and d.get('tool_call_ok'):
        print(d['model'])
except: pass
")
  [[ -n "$model" ]] && APPROVED+=("$model")
done < "$PROBE_OUT"

echo "[sync] ${#APPROVED[@]} modelos aprovados (de $(wc -l < "$PROBE_OUT" 2>/dev/null || echo 0) sondados)"

# --- 3. Classifica por família + capacidade ---
declare -A BY_FAM
for m in "${APPROVED[@]}"; do
  fam="${m%%/*}"
  BY_FAM[$fam]+=" $m"
done

# --- 4. Função: escolhe melhor modelo de uma família ---
pick() {
  local fam="$1" want_vision="$2" want_reasoning="$3"
  local best="" best_score=-1
  for m in ${BY_FAM[$fam]:-}; do
    # score: prioriza reasoning > vision > geral
    score=0
    [[ "$want_reasoning" == 1 && "$m" == *"thinking"* ]] && score=$((score + 10))
    [[ "$want_vision" == 1 && ( "$m" == *"flash"* || "$m" == *"vision"* || "$m" == *"vl"* ) ]] && score=$((score + 5))
    [[ -z "$best" || score > best_score ]] && { best="$m"; best_score=$score; }
  done
  echo "$best"
}

# --- 5. Gera config recomendado ---
REC=$(cat <<EOF
{
  "preset": "9router",
  "image_routing": "auto",
  "presets": {
    "9router": {
      "orchestrator": { "model": ["9router/$(pick ag 0 0)", "9router/$(pick cx 0 0)", "9router/$(pick oc 0 0)"] },
      "oracle":       { "model": ["9router/$(pick ag 0 1)", "9router/$(pick cx 0 0)", "9router/$(pick ag 1 0)"] },
      "explorer":     { "model": ["9router/$(pick ag 0 0)", "9router/$(pick oc 0 0)", "9router/$(pick cx 0 0)"] },
      "designer":     { "model": ["9router/$(pick cx 0 0)", "9router/$(pick ag 1 0)", "9router/$(pick oc 0 0)"] },
      "fixer":        { "model": ["9router/$(pick cx 0 0)", "9router/$(pick ag 0 0)", "9router/$(pick oc 0 0)"] },
      "observer":     { "model": ["9router/$(pick ag 1 0)", "9router/$(pick oc 1 0)", "9router/$(pick oc 0 1)"] },
      "council":      { "model": ["9router/$(pick ag 0 0)", "9router/$(pick cx 0 0)", "9router/$(pick ag 1 0)"] }
    }
  },
  "council": {
    "default_preset": "default",
    "presets": {
      "default": {
        "architect": { "model": "9router/$(pick ag 0 1)", "prompt": "Focus on maintainability, boundaries, and long-term design." },
        "reviewer":  { "model": "9router/$(pick cx 0 0)", "prompt": "Focus on bugs, edge cases, and failure modes." },
        "optimiser": { "model": "9router/$(pick oc 0 0)", "prompt": "Focus on performance, latency, and resource usage." },
        "visual":    { "model": "9router/$(pick ag 1 0)", "prompt": "Focus on UI/UX correctness, accessibility, and visual details." }
      }
    }
  }
}
EOF
)

# --- 6. Merge com o arquivo existente (preserva $schema, image_routing, etc.) ---
CURRENT=$(cat "$CONFIG")
NEW_CONFIG=$(echo "$CURRENT" | python3 -c "
import sys, json
current = json.load(sys.stdin)
rec = json.loads(sys.argv[1])
# atualiza apenas presets.9router e council.presets.default
current['presets']['9router'] = rec['presets']['9router']
current['council']['presets']['default'] = rec['council']['presets']['default']
json.dump(current, sys.stdout, indent=2, ensure_ascii=False)
print()
" "$REC")

# --- 7. Mostra diff ---
echo "[sync] diff:"
diff -u <(echo "$CURRENT" | python3 -m json.tool) <(echo "$NEW_CONFIG" | python3 -m json.tool) | head -80 || true

# --- 8. Aplica se --apply ---
if [[ "$APPLY" == true ]]; then
  echo "$NEW_CONFIG" > "$CONFIG"
  echo "[sync] aplicado -> $CONFIG"
  echo "[sync] reiniciando daemon..."
  opencode service restart
else
  echo "[sync] dry-run apenas. Para aplicar: zsh tools/sync-models.sh --apply"
fi
