#!/usr/bin/env zsh
# tools/print-model-dashboard.sh
#
# Exibe um dashboard resumido da seleção de modelos direto no chat/TUI,
# após rodar /refresh_models_9router, /auto_select_models_oh_my_opencode_slim
# ou /auto_select_uncensored_models.
#
# Lê:
#   ~/.config/opencode/oh-my-opencode-slim.json (ou .jsonc)
#   ~/.local/share/9router-tools/probe.jsonl        (opcional: status toolcall/qualidade)
#   ~/.local/share/9router-tools/model-history.json (opcional: histórico)
#
# Uso:
#   zsh tools/print-model-dashboard.sh
#   zsh tools/print-model-dashboard.sh --config <caminho>

set -euo pipefail

# ------------------------------------------------------------------ config ---

_OC_CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
if [[ -f "${_OC_CFG_DIR}/oh-my-opencode-slim.jsonc" ]]; then
  CONFIG="${_OC_CFG_DIR}/oh-my-opencode-slim.jsonc"
else
  CONFIG="${_OC_CFG_DIR}/oh-my-opencode-slim.json"
fi

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools"
PROBE_OUT="${DATA_DIR}/probe.jsonl"
HIST="${DATA_DIR}/model-history.json"

while (( $# > 0 )); do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ------------------------------------------------------------------ python ---

python3 - "$CONFIG" "$PROBE_OUT" "$HIST" <<'PY'
import json, os, sys, time

config_path, probe_path, hist_path = sys.argv[1], sys.argv[2], sys.argv[3]

PAPEIS_PRINCIPAIS = ["orchestrator", "oracle", "explorer", "designer", "fixer", "observer", "council"]
COUNCIL_SEATS     = ["architect", "reviewer", "optimiser", "visual"]

STATUS_OK   = "✅"
STATUS_WARN = "⚠️ "
STATUS_FREE = "🆓"
STATUS_NONE = "❌"

# ----------------------------------------------------------------- leitura --

def load_json(path, default):
    if not os.path.exists(path):
        return default
    try:
        return json.load(open(path, errors="replace"))
    except Exception:
        return default

def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows

config  = load_json(config_path, {})
probes  = {}
for r in read_jsonl(probe_path):
    mid = r.get("model", "")
    if mid:
        probes["9router/" + mid] = r
hist    = load_json(hist_path, {})

# ----------------------------------------------------------------- helpers ---

def model_list(section):
    """Retorna lista de modelos de uma seção (string ou lista)."""
    m = section.get("model", [])
    if isinstance(m, str):
        return [m]
    return list(m) if m else []

def model_status(mid):
    """Retorna (ícone, detalhe) para um modelo."""
    if not mid or mid == "(sem modelo)":
        return STATUS_NONE, "sem modelo"
    is_free = ":free" in mid or "-free" in mid or mid.startswith("opencode/")
    p = probes.get(mid)
    if p:
        toolcall = p.get("tool_ok", False)
        q = p.get("quality_score")
        q_str = f" q={q:.2f}" if isinstance(q, (int, float)) else ""
        lat = p.get("ttfb_ms") or p.get("total_ms")
        lat_str = f" {int(lat)}ms" if isinstance(lat, (int, float)) else ""
        if not toolcall:
            return STATUS_WARN, f"sem toolcall{q_str}{lat_str}"
        icon = STATUS_FREE if is_free else STATUS_OK
        return icon, f"toolcall{q_str}{lat_str}"
    if is_free:
        return STATUS_FREE, "free (sem sonda)"
    return STATUS_WARN, "sem sonda"

def short_model(mid):
    """Encurta o ID para caber na tabela."""
    if not mid:
        return "(sem modelo)"
    # remove prefixo 9router/
    s = mid.replace("9router/", "")
    if len(s) > 36:
        s = s[:33] + "..."
    return s

# ------------------------------------------------------------------ preset --

preset_name = config.get("preset", "9router")
presets = config.get("presets", {})
preset  = presets.get(preset_name, {})

# -------------------------------------------------------------- data/hora ---

mtime = ""
try:
    t = os.path.getmtime(config_path)
    mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(t))
except Exception:
    mtime = "?"

# ------------------------------------------------------------------ tabela --

SEP = "-" * 80
print()
print(SEP)
print(f"  DASHBOARD DE MODELOS — preset: {preset_name}   última gravação: {mtime}")
print(SEP)
print()

# Cabeçalho
print(f"{'Papel':<16} {'Modelo principal':<40} {'Status':<20} Fallbacks")
print(f"{'─'*16} {'─'*40} {'─'*20} {'─'*30}")

alerts = []

for papel in PAPEIS_PRINCIPAIS:
    sec = preset.get(papel, {})
    mods = model_list(sec)
    principal = mods[0] if mods else ""
    fallbacks = mods[1:] if len(mods) > 1 else []

    icon, detalhe = model_status(principal)
    p_str  = short_model(principal) if principal else "(sem modelo)"
    fb_str = ", ".join(short_model(f) for f in fallbacks[:2])

    # alertas
    if not principal:
        alerts.append(f"❌ Papel '{papel}' sem modelo atribuído!")
    elif icon == STATUS_WARN:
        alerts.append(f"⚠️  Papel '{papel}': {detalhe} em {short_model(principal)}")
    elif icon == STATUS_FREE and not fallbacks:
        alerts.append(f"🆓 Papel '{papel}': usando apenas modelo free sem fallback pago.")

    print(f"{papel:<16} {p_str:<40} {icon} {detalhe:<17} {fb_str}")

# Council seats
council_cfg = config.get("council", {})
seats_cfg = (council_cfg
             .get("presets", {})
             .get(council_cfg.get("default_preset", "default"), {}))

if seats_cfg:
    print()
    print(f"{'Council seat':<16} {'Modelo':<40} {'Status':<20}")
    print(f"{'─'*16} {'─'*40} {'─'*20}")
    for seat in COUNCIL_SEATS:
        sec = seats_cfg.get(seat, {})
        mid = sec.get("model", "") if isinstance(sec, dict) else sec
        icon, detalhe = model_status(mid)
        print(f"{seat:<16} {short_model(mid):<40} {icon} {detalhe}")

# ------------------------------------------------------------------ alertas --

print()
if alerts:
    print("── ALERTAS " + "─" * 69)
    for a in alerts:
        print(f"  {a}")
    print()
    print("  → Rode /auto_select_models_oh_my_opencode_slim para corrigir.")
else:
    print(f"  {STATUS_OK} Todos os papéis com modelo 9router atribuído.")

print(SEP)
print()
PY
