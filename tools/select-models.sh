#!/usr/bin/env zsh
# tools/select-models.sh
#
# Escolhe, para cada agente do oh-my-opencode-slim, o MELHOR modelo disponivel —
# entre TODOS os provedores que responderem na sonda, nao so o 9router.
#
# Ordem de preferencia:
#   1. modelos do provedor `9router` aprovados na sonda (o objetivo do projeto);
#   2. modelos NATIVOS do OpenCode (`opencode/*`, free) que responderem;
#   3. nada muda no papel (mantem o valor atual).
#
# Se o 9router nao devolver nenhum modelo bom (tunel fora, cota esgotada,
# upstream 503), os agentes ainda ficam funcionais com os free do OpenCode.
#
# COMO CLASSIFICA (por papel):
#   werkzeug     = precisa tool calling; qualidade
#   rapido       = precisa tool calling; velocidade
#   raciocinio   = precisa reasoning; qualidade
#   visao        = precisa visao; qualidade
#   nao_critico  = qualquer aprovado; velocidade
#
# Uso:
#   zsh tools/select-models.sh                   # dry-run (mostra o diff)
#   zsh tools/select-models.sh --apply           # grava + reinicia o daemon
#   zsh tools/select-models.sh --probe           # roda a sonda antes
#   zsh tools/select-models.sh --quick           # sonda rapida (~2min) e aplica
#   zsh tools/select-models.sh --only-native     # ignora o 9router (so opencode/*)
#   zsh tools/select-models.sh --no-restart      # grava sem reiniciar o daemon
#   zsh tools/select-models.sh --probe-filter 'ag/,cx/'   # sonda so esses prefixos
#   zsh tools/select-models.sh --config <path>   # outro oh-my-opencode-slim.json
#
# Idempotente: mesma sonda -> mesma atribuicao. Backup antes de gravar.

set -euo pipefail

SELF="${0:A}"
TOOLS_DIR="${SELF:h}"
# Dentro do repo: tools/ mora em <repo>/tools. Instalado (fora do repo):
# tools/ e a propria pasta ~/.local/share/9router-tools (layout plano).
if [[ -e "${TOOLS_DIR:h}/.git" ]]; then
  ROOT="${TOOLS_DIR:h}"
else
  ROOT="${TOOLS_DIR}"
fi
source "${TOOLS_DIR}/lib/venice-env.sh"

PROBE_OUT="${ROOT}/probe.jsonl"
NATIVE_OUT="${ROOT}/probe-native.jsonl"
CONFIG="${HOME}/.config/opencode/oh-my-opencode-slim.json"
APPLY=false
RESTART=true
RUN_PROBE=false
PROBE_ONLY=false
PROBE_FILTER=""
PROBE_CONCURRENCY="${PROBE_CONCURRENCY:-6}"
QUICK=false
ONLY_NATIVE=false

while (( $# > 0 )); do
  case "$1" in
    --apply)        APPLY=true;   shift ;;
    --dry-run)      APPLY=false;  shift ;;
    --no-restart)   RESTART=false; shift ;;
    --restart)      RESTART=true;  shift ;;
    --probe)        RUN_PROBE=true; shift ;;
    --probe-only)   RUN_PROBE=true; PROBE_ONLY=true; APPLY=false; shift ;;
    --quick)        QUICK=true; RUN_PROBE=true; PROBE_CONCURRENCY=8; shift ;;
    --only-native)  ONLY_NATIVE=true; shift ;;
    --probe-filter) PROBE_FILTER="$2"; shift 2 ;;
    --probe-out)    PROBE_OUT="$2"; shift 2 ;;
    --native-out)   NATIVE_OUT="$2"; shift 2 ;;
    --config)       CONFIG="$2";  shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) printf '[select] opcao desconhecida: %s\n' "$1" >&2; exit 1 ;;
  esac
done

log()  { printf '[select] %s\n' "$*"; }
warn() { printf '[select] AVISO: %s\n' "$*" >&2; }
die()  { printf '[select] ERRO: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- sonda ----

probe_9router() {
  local extra=()
  [[ -n "$PROBE_FILTER" ]] && extra=(--filter "$PROBE_FILTER")
  [[ "$QUICK" == true ]] && extra+=(--quick)
  log "sondando o 9router (concurrency=${PROBE_CONCURRENCY})..."
  zsh "${TOOLS_DIR}/probe-models.sh" \
      --concurrency "$PROBE_CONCURRENCY" --out "$PROBE_OUT" "${extra[@]}" \
      || warn "a sonda do 9router falhou; seguindo com o que ja existir em $PROBE_OUT"
}

# Os modelos nativos do OpenCode (free) nao passam pelo 9router: precisam da sua
# propria sonda, com o mesmo teste de tool calling, mas direto no provedor.
probe_native() {
  local ids
  ids="$(opencode api get /api/model 2>/dev/null | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in d.get("data", []):
    if m.get("providerID") and m["providerID"] != "9router" and m.get("id"):
        print(f"{m[\"providerID\"]}/{m[\"id\"]}")
' 2>/dev/null)"

  if [[ -z "$ids" ]]; then
    warn "nenhum modelo nativo do OpenCode encontrado; so o 9router sera considerado"
    : > "$NATIVE_OUT"
    return
  fi

  log "sondando modelos nativos do OpenCode..."
  : > "$NATIVE_OUT"
  local payload
  payload="$(mktemp "${TMPDIR:-/tmp}/native-probe.XXXXXX")"
  python3 - "$payload" <<'PY'
import json, sys
req = {
    "model": "PLACEHOLDER",
    "max_tokens": 256,
    "messages": [{"role": "user", "content": "Call the get_weather tool for Paris. Use the tool."}],
    "tools": [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city",
            "parameters": {"type": "object",
                           "properties": {"city": {"type": "string", "description": "City name"}},
                           "required": ["city"]},
        },
    }],
    "tool_choice": "auto",
}
open(sys.argv[1], "w").write(json.dumps(req))
PY

  local mid body http_code ttfb total tool_ok
  while IFS= read -r mid; do
    [[ -n "$mid" ]] || continue
    body="$(mktemp "${TMPDIR:-/tmp}/native-body.XXXXXX")"
    # Sonda direta contra o endpoint do provedor nativo (o daemon do OpenCode
    # nao aceita POST arbitrario para inferencia; usamos a API publica do
    # provedor com a credencial "public" que o proprio OpenCode usa).
    http_code=0; ttfb=0; total=0; tool_ok=false
    local w
    w="$(curl -sS -o "$body" -w '%{http_code} %{time_starttransfer} %{time_total}' \
        --max-time 60 -X POST "https://opencode.ai/inference/openai/v1/chat/completions" \
        -H 'Authorization: Bearer public' -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["model"]=sys.argv[2]; print(json.dumps(d))' "$payload" "$mid")" \
        2>/dev/null)" || w="0 0 0"
    read -r http_code ttfb total <<< "$w"
    grep -q '"name"[[:space:]]*:[[:space:]]*"get_weather"' "$body" 2>/dev/null && tool_ok=true
    python3 - "$NATIVE_OUT" "$mid" "$http_code" "$ttfb" "$total" "$tool_ok" <<'PY'
import json, sys, time
out, model, code, ttfb, total, tool_ok = sys.argv[1:7]
def ms(x):
    try:
        return int(float(x) * 1000)
    except Exception:
        return 0
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "model": model,
    "http_status": int(code) if code.isdigit() else 0,
    "tool_call_ok": tool_ok == "true",
    "ttfb_ms": ms(ttfb),
    "latency_ms": ms(total),
    "source": "native",
}
with open(out, "a") as fh:
    fh.write(json.dumps(rec) + "\n")
PY
    rm -f "$body"
  done <<< "$ids"
  rm -f "$payload"
  log "sonda nativa: $(wc -l < "$NATIVE_OUT") modelos testados"
}

if [[ "$RUN_PROBE" == true ]]; then
  [[ "$ONLY_NATIVE" == false ]] && probe_9router
  probe_native
fi

[[ "$PROBE_ONLY" == true ]] && { log "somente sonda (--probe-only); nada foi gravado."; exit 0; }

[[ -r "$PROBE_OUT" ]]    || die "sonda ausente: $PROBE_OUT (rode com --probe)"
[[ -r "$CONFIG" ]]       || die "config ilegivel: $CONFIG"
[[ -r "$NATIVE_OUT" ]]   || : > "$NATIVE_OUT"

# ------------------------------------------------- categorias + atribuicao ----

CATALOG="$(mktemp "${TMPDIR:-/tmp}/select-models.XXXXXX")"
trap 'rm -f "$CATALOG"' EXIT

BASE_URL_HOST="${NINEROUTER_BASE_URL%/}"
if [[ -n "$BASE_URL_HOST" && -n "${NINEROUTER_API_KEY:-}" ]]; then
  curl -sS --max-time 60 -H "Authorization: Bearer ${NINEROUTER_API_KEY}" \
    "${BASE_URL_HOST}/models" -o "$CATALOG" 2>/dev/null || : > "$CATALOG"
  [[ -s "$CATALOG" ]] || warn "catalogo do 9router indisponivel; a classificacao usara so a sonda"
else
  warn "NINEROUTER_API_KEY/NINEROUTER_BASE_URL ausentes; a classificacao usara so a sonda"
  : > "$CATALOG"
fi

python3 - "$PROBE_OUT" "$NATIVE_OUT" "$CATALOG" "$CONFIG" "$APPLY" "$RESTART" "$ONLY_NATIVE" <<'PY'
import json, os, shutil, sys, subprocess, time

(probe_path, native_path, catalog_path, config_path,
 apply_s, restart_s, only_native_s) = sys.argv[1:8]
apply = apply_s == "true"
restart = restart_s == "true"
only_native = only_native_s == "true"

log = lambda *a: print("[select]", *a, flush=True)

# ------------------------------------------------------------- leitura ------

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

probes = {}
# A sonda do 9router grava IDs sem prefixo; a nativa grava "provedor/modelo".
# Normalizamos para referencias completas, senao um mesmo ID (ex.: cx/x) seria
# contado como nativo e o 9router perderia a preferencia.
for r in read_jsonl(probe_path):
    if r.get("model"):
        probes["9router/" + r["model"]] = r
for r in read_jsonl(native_path):
    if r.get("model"):
        probes[r["model"]] = r

if not probes:
    raise SystemExit("[select] ERRO: nenhuma sonda legivel; rode com --probe")

# Metadados dos modelos NATIVOS vem da API local do OpenCode (caps/limits reais).
native_meta = {}
try:
    out = subprocess.run(["opencode", "api", "get", "/api/model"],
                         capture_output=True, text=True, timeout=60).stdout
    for m in json.loads(out).get("data", []):
        if not m.get("providerID") or m["providerID"] == "9router":
            continue
        caps = m.get("capabilities") or {}
        lim = m.get("limit") or {}
        native_meta[f"{m['providerID']}/{m['id']}"] = {
            "vision": "image" in (caps.get("input") or []),
            "reasoning": "reasoning" in (caps.get("input") or [])
                         or bool(caps.get("reasoning"))
                         or bool(m.get("variants")),
            "ctx": int(lim.get("context") or caps.get("contextWindow") or 200000),
            "max_out": int(lim.get("output") or caps.get("maxOutput") or 64000),
        }
except Exception as exc:
    log(f"AVISO: metadados nativos indisponiveis ({exc})")

# Metadados do 9router vem do catalogo ao vivo.
catalog_meta = {}
if os.path.exists(catalog_path) and os.path.getsize(catalog_path) > 0:
    try:
        for m in json.load(open(catalog_path)).get("data", []):
            if not m.get("id"):
                continue
            c = m.get("capabilities") or {}
            catalog_meta[m["id"]] = {
                "vision": bool(c.get("vision")),
                "reasoning": bool(c.get("reasoning")),
                "ctx": int(m.get("context_length") or c.get("contextWindow") or 200000),
                "max_out": int(m.get("max_completion_tokens") or c.get("maxOutput") or 64000),
            }
    except Exception as exc:
        log(f"AVISO: catalogo do 9router ilegivel ({exc})")

# ------------------------------------------------------------- pools --------

def approved(r):
    return r.get("http_status") == 200 and r.get("tool_call_ok")

def meta(mid):
    b = bare(mid)
    if mid in catalog_meta:
        return catalog_meta[mid]
    if b in catalog_meta:
        return catalog_meta[b]
    if mid in native_meta:
        return native_meta[mid]
    if b in native_meta:
        return native_meta[b]
    return {"vision": False, "reasoning": False, "ctx": 200000, "max_out": 64000}

def tier(mid):
    return 0 if mid.startswith("9router/") else 1

def bare(mid):
    return mid[len("9router/"):] if mid.startswith("9router/") else mid

def reward_penalty(mid):
    low = mid.lower()
    if ":free" in low or "-free" in low:
        return -200
    return 0

def probe_for(mid):
    return (probes.get(mid)
            or probes.get("9router/" + bare(mid))
            or probes.get(bare(mid))
            or {})

def quality(mid):
    m = meta(mid)
    r = probe_for(mid)
    lat = r.get("latency_ms") or 60000
    return (
        reward_penalty(mid)
        + min(m["ctx"], 1_000_000) // 100_000
        + min(m["max_out"], 128_000) // 16_000
        + (4 if m["reasoning"] else 0)
        + (2 if m["vision"] else 0)
        - min(lat, 60000) // 1000
    )

def speed(mid):
    r = probe_for(mid)
    lat = r.get("latency_ms") or 60000
    return -min(lat, 60000) // 100 + quality(mid) // 1000

CATEGORIES = {
    "werkzeug":    lambda mid: quality(mid),
    "rapido":      lambda mid: speed(mid),
    "raciocinio":  lambda mid: quality(mid),
    "visao":       lambda mid: quality(mid),
    "nao_critico": lambda mid: speed(mid),
}

REQUIRES = {
    "werkzeug":    lambda mid: True,
    "rapido":      lambda mid: True,
    "raciocinio":  lambda mid: meta(mid)["reasoning"],
    "visao":       lambda mid: meta(mid)["vision"],
    "nao_critico": lambda mid: True,
}

# Universo: 9router + nativos do OpenCode.
universe = set()
for mid, r in probes.items():
    if approved(r):
        universe.add(mid)
for mid in native_meta:
    if mid not in universe:
        universe.add(mid)
if only_native:
    universe = {m for m in universe if not m.startswith("9router/")}

by_tier = {0: [], 1: []}
for mid in universe:
    by_tier[tier(mid)].append(mid)

log(f"aprovados: {len(by_tier[0])} no 9router · {len(by_tier[1])} nativos do OpenCode"
    + (" (--only-native: 9router ignorado)" if only_native else ""))

pools = {}
for cat, key in CATEGORIES.items():
    pool = [m for m in universe if REQUIRES[cat](m)]
    # Ordena por tier primeiro: 9router antes de nativo, sempre.
    pools[cat] = sorted(pool, key=lambda m: (tier(m), -key(m), m))
    log(f"pool {cat:<12}: {len(pool):>3} modelos")

for cat in ("raciocinio", "visao"):
    if not pools[cat]:
        log(f"AVISO: nada aprovado em '{cat}'; papeis que dependem dela usam fallback")

def pick(profiles):
    chosen = []
    for cat in profiles:
        for mid in pools.get(cat, []):
            if mid not in chosen:
                chosen.append(mid)
                if len(chosen) == 3:
                    return chosen
    for cat in CATEGORIES:
        for mid in pools.get(cat, []):
            if mid not in chosen:
                chosen.append(mid)
                if len(chosen) == 3:
                    return chosen
    return chosen

def full(mid):
    """Referencia completa para o config: provedor/nome."""
    return mid if "/" in bare(mid) or mid.startswith("9router/") else mid

def ref(mid):
    return mid if mid.startswith("9router/") else mid

AGENT_PROFILES = {
    "orchestrator":  ["werkzeug", "raciocinio", "nao_critico"],
    "oracle":        ["raciocinio", "werkzeug", "nao_critico"],
    "explorer":      ["rapido", "werkzeug", "nao_critico"],
    "designer":      ["werkzeug", "visao", "nao_critico"],
    "fixer":         ["werkzeug", "raciocinio", "nao_critico"],
    "observer":      ["visao", "werkzeug", "nao_critico"],
    "council":       ["werkzeug", "raciocinio", "nao_critico"],
}

COUNCIL_PROFILES = {
    "architect": ["raciocinio", "werkzeug", "nao_critico"],
    "reviewer":  ["werkzeug", "raciocinio", "nao_critico"],
    "optimiser": ["werkzeug", "rapido", "nao_critico"],
    "visual":    ["visao", "werkzeug", "nao_critico"],
}

COUNCIL_PROMPTS = {
    "architect": "Focus on maintainability, boundaries, and long-term design.",
    "reviewer":  "Focus on bugs, edge cases, and failure modes.",
    "optimiser": "Focus on performance, latency, and resource usage.",
    "visual":    "Focus on UI/UX correctness, accessibility, and visual details.",
}

config = json.load(open(config_path))
preset_name = config.get("preset", "9router")
preset = config.setdefault("presets", {}).setdefault(preset_name, {})

changes = []
for agent, profiles in AGENT_PROFILES.items():
    picked = pick(profiles)
    if not picked:
        log(f"AVISO: sem modelo para '{agent}'; mantendo o valor atual")
        continue
    entry = preset.setdefault(agent, {})
    old = entry.get("model")
    if old != picked:
        entry["model"] = picked
        changes.append((agent, old, picked))

council = config.setdefault("council", {}).setdefault("presets", {})
for name, profiles in COUNCIL_PROFILES.items():
    picked = pick(profiles)
    if not picked:
        continue
    entry = council.setdefault("default", {}).setdefault(name, {})
    entry.setdefault("prompt", COUNCIL_PROMPTS[name])
    old = entry.get("model")
    if old != picked[0]:
        entry["model"] = picked[0]
        changes.append((f"council.{name}", old, picked[0]))

# ------------------------------------------------------------- resumo -------

print()
print("=" * 78)
print(f"  ATRIBUICAO DE MODELOS AOS AGENTES"
      f"  ({len(by_tier[0])} do 9router, {len(by_tier[1])} nativos)")
print("=" * 78)
for agent in AGENT_PROFILES:
    chain = preset.get(agent, {}).get("model") or []
    mark = " ~" if any(c[0] == agent for c in changes) else "  "
    head = chain[0] if chain else "(vazio)"
    extra = "  → " + ", ".join(chain[1:]) if len(chain) > 1 else ""
    print(f" {mark} {agent:<13} {head}{extra}")
print()
for name in COUNCIL_PROFILES:
    entry = council.get("default", {}).get(name, {})
    mark = " ~" if any(c[0] == f"council.{name}" for c in changes) else "  "
    print(f" {mark} council/{name:<10} {entry.get('model', '(vazio)')}")
print("=" * 78)
print()

if not changes:
    log("nada a fazer: os agentes ja estao apontando para os melhores aprovados.")
    raise SystemExit(0)

log(f"{len(changes)} papel(is) mudariam de modelo:")
for agent, old, new in changes:
    print(f"   - {agent}\n       antes:  {old}\n       depois: {new}")

if not apply:
    print()
    log("dry-run. Para gravar: zsh tools/select-models.sh --apply")
    raise SystemExit(0)

backup_dir = os.path.join(os.path.expanduser("~"), ".config", "opencode", "backups")
os.makedirs(backup_dir, exist_ok=True)
stamp = time.strftime("%Y%m%d-%H%M%S")
bak = os.path.join(backup_dir, f"oh-my-opencode-slim.json.{stamp}.bak")
shutil.copy2(config_path, bak)
print()
log(f"backup: {bak}")

mode = os.stat(config_path).st_mode & 0o777
tmp = config_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(config, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, config_path)
log(f"gravado: {config_path} (mode {oct(mode)[2:]})")

if restart:
    log("reiniciando o daemon do OpenCode...")
    rc = os.system("opencode service restart >/dev/null 2>&1")
    log("daemon reiniciado." if rc == 0 else "AVISO: 'opencode service restart' retornou erro")
else:
    log("daemon NAO reiniciado (--no-restart). Rode: opencode service restart")
PY
