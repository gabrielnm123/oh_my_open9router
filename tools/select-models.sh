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
#   zsh tools/select-models.sh                   # sonda TUDO e mostra o diff
#   zsh tools/select-models.sh --apply           # sonda tudo, grava e reinicia
#   zsh tools/select-models.sh --no-restart      # sonda tudo, grava sem reiniciar
#   zsh tools/select-models.sh --dry-run         # sonda tudo (nada e gravado)
#   zsh tools/select-models.sh --probe-only      # sonda tudo, nao grava
#   zsh tools/select-models.sh --only-native     # debug: ignora o 9router
#   zsh tools/select-models.sh --probe-filter 'ag/'   # debug: sonda parcial
#   zsh tools/select-models.sh --remote          # sonda via tunel SSH
#   zsh tools/select-models.sh --config <path>   # outro oh-my-opencode-slim.json
#
# A sonda roda SEMPRE (nao existe reaproveitar probe.jsonl antigo): o pool e
# montado a partir do catalogo vivo + dos nativos, sem excecao. Nada de
# selecionar a partir de dados velhos.
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
HISTORY="${MODEL_HISTORY:-${ROOT}/model-history.json}"
HISTORY_ENABLED=true
APPLY=false
RESTART=true
# A sonda roda sempre: o pool nunca vem de probe.jsonl reaproveitado.
RUN_PROBE=true
PROBE_ONLY=false
PROBE_FILTER=""
PROBE_CONCURRENCY="${PROBE_CONCURRENCY:-8}"
QUICK=false
ONLY_NATIVE=false
REMOTE=false
SERVER=""

while (( $# > 0 )); do
  case "$1" in
    --apply)        APPLY=true;   shift ;;
    --dry-run)      APPLY=false;  shift ;;
    --no-restart)   RESTART=false; shift ;;
    --restart)      RESTART=true;  shift ;;
    --probe)        RUN_PROBE=true; shift ;;
    --probe-only)   PROBE_ONLY=true; APPLY=false; shift ;;
    --quick)        printf '[select] AVISO: --quick ignorado — a sonda é sempre completa\n' >&2; shift ;;
    --only-native)  ONLY_NATIVE=true; shift ;;
    --remote)       REMOTE=true; shift ;;
    --server)       SERVER="$2"; REMOTE=true; shift 2 ;;
    --probe-filter) PROBE_FILTER="$2"; shift 2 ;;
    --probe-out)    PROBE_OUT="$2"; shift 2 ;;
    --native-out)   NATIVE_OUT="$2"; shift 2 ;;
    --config)       CONFIG="$2";  shift 2 ;;
    --history)      HISTORY="$2"; shift 2 ;;
    --no-history)   HISTORY_ENABLED=false; shift ;;
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
  # Filtro/quick so existem como ferramenta de debug; o comando oficial nunca
  # passa por aqui com universo reduzido.
  [[ -n "$PROBE_FILTER" ]] && { warn "--probe-filter '${PROBE_FILTER}': pool parcial (debug)"; extra=(--filter "$PROBE_FILTER"); }
  [[ "$REMOTE" == true ]] && extra+=(--remote)
  [[ -n "$SERVER" ]] && extra+=(--server "$SERVER")
  log "sondando o 9router (concurrency=${PROBE_CONCURRENCY})..."
  zsh "${TOOLS_DIR}/probe-models.sh" \
      --concurrency "$PROBE_CONCURRENCY" --out "$PROBE_OUT" "${extra[@]}" \
      || die "sonda do 9router falhou; nao aplico com dados antigos (veja o erro acima)"
}

# Os modelos nativos do OpenCode (free) nao passam pelo 9router: precisam da sua
# propria sonda, com o mesmo teste de tool calling, mas direto no provedor.
probe_native() {
  local ids=""
  # Nao deixar uma falha aqui matar o script inteiro (set -e): sem nativos, o
  # pool segue so com o 9router, mas o comando aplica e responde.
  ids="$(opencode api get /api/model 2>/dev/null | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in d.get("data", []):
    if m.get("providerID") and m["providerID"] != "9router" and m.get("id"):
        print(m["providerID"] + "/" + m["id"])
' 2>/dev/null)" || ids=""

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

  local mid body http_code ttfb total tool_ok w
  while IFS= read -r mid; do
    [[ -n "$mid" ]] || continue
    body="$(mktemp "${TMPDIR:-/tmp}/native-body.XXXXXX")"
    # Sonda direta contra o endpoint do provedor nativo (o daemon do OpenCode
    # nao aceita POST arbitrario para inferencia; usamos a API publica do
    # provedor com a credencial "public" que o proprio OpenCode usa).
    http_code=0; ttfb=0; total=0; tool_ok=false
    # O endpoint aceita o ID do modelo SEM o prefixo do provedor (`beam-free`,
    # nao `opencode/beam-free`); o ID completo fica registrado no JSONL.
    w="$(curl -sS -o "$body" -w '%{http_code} %{time_starttransfer} %{time_total}' \
        --max-time 60 -X POST "https://opencode.ai/inference/openai/v1/chat/completions" \
        -H 'Authorization: Bearer public' -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["model"]=sys.argv[2].split("/",1)[-1]; print(json.dumps(d))' "$payload" "$mid")" \
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

python3 - "$PROBE_OUT" "$NATIVE_OUT" "$CATALOG" "$CONFIG" "$APPLY" "$RESTART" "$ONLY_NATIVE" \
         "$HISTORY" "$HISTORY_ENABLED" "${TOOLS_DIR}/model-history.sh" <<'PY'
import json, os, shutil, sys, subprocess, time

(probe_path, native_path, catalog_path, config_path,
 apply_s, restart_s, only_native_s, history_path, history_enabled_s,
 history_sh) = sys.argv[1:11]
apply = apply_s == "true"
restart = restart_s == "true"
only_native = only_native_s == "true"
history_on = history_enabled_s == "true" and os.path.exists(history_sh)

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

# Universo: 9router + nativos do OpenCode, ambos SO a partir da sonda.
# Nenhum modelo entra por metadados: se nao foi pingado e aprovado, fica fora.
universe = set()
for mid, r in probes.items():
    if approved(r):
        universe.add(mid)

nao_sonados = sorted(m for m in native_meta if m not in probes)
if nao_sonados:
    log(f"AVISO: {len(nao_sonados)} nativo(s) sem sonda valida; ficam fora: "
        + ", ".join(nao_sonados[:5]) + ("..." if len(nao_sonados) > 5 else ""))

if only_native:
    universe = {m for m in universe if not m.startswith("9router/")}

if not universe:
    raise SystemExit("[select] ERRO: nenhum modelo aprovado na sonda; config nao alterado")

by_tier = {0: [], 1: []}
for mid in universe:
    by_tier[tier(mid)].append(mid)

testados_9 = sum(1 for m in probes if m.startswith("9router/"))
testados_nativo = len(probes) - testados_9
log(f"testados: {testados_9} no 9router · {testados_nativo} nativos do OpenCode")

log(f"aprovados: {len(by_tier[0])} no 9router · {len(by_tier[1])} nativos do OpenCode"
    + (" (--only-native: 9router ignorado)" if only_native else ""))

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

# ------------------------------------------------------------- historico -----
# Cada categoria e consultada com os agentes que a usam: a nota de pesquisa
# pode ter sido registrada pelo nome do agente ou pela categoria.
CAT_AGENTS = {}
for _agent, _profiles in AGENT_PROFILES.items():
    CAT_AGENTS.setdefault(_profiles[0], []).append(_agent)
for _name, _profiles in COUNCIL_PROFILES.items():
    CAT_AGENTS.setdefault(_profiles[0], []).append("council/" + _name)

hist = {}
if history_on and os.path.exists(history_path):
    for _cat, _agents in CAT_AGENTS.items():
        try:
            _r = subprocess.run(
                ["zsh", history_sh, "score", "--role", _cat,
                 "--agents", ",".join(_agents)],
                capture_output=True, text=True, timeout=30)
            hist[_cat] = json.loads(_r.stdout or "{}")
        except Exception as _exc:
            log(f"AVISO: historico indisponivel para '{_cat}' ({_exc})")
            hist[_cat] = {}
    if any(hist.values()):
        log(f"historico: {history_path}")

def hscore(mid, cat):
    e = (hist.get(cat) or {}).get(mid) or {}
    return float(e.get("research") or 0.0), int(e.get("assigned") or 0)

def stale_candidates(cat):
    """Modelos que nao responderam agora, mas tem historico forte.
    Ficam como fallback para nao perder um bom modelo por uma sonda ruim."""
    out = []
    for mid, e in (hist.get(cat) or {}).items():
        if mid in universe:
            continue
        research = float(e.get("research") or 0.0)
        ok, fail = int(e.get("ok") or 0), int(e.get("fail") or 0)
        if research >= 0.7 or (ok >= 2 and ok > fail):
            out.append((-research, -(ok - fail), mid))
    return [m for _r, _d, m in sorted(out)]

stale_picked = []

pools = {}
for cat, key in CATEGORIES.items():
    pool = [m for m in universe if REQUIRES[cat](m)]
    def _score(m, cat=cat, key=key):
        research, assigned = hscore(m, cat)
        return key(m) + 1000.0 * research + 5 * assigned
    # Ordena por tier primeiro: 9router antes de nativo, sempre.
    pools[cat] = sorted(pool, key=lambda m: (tier(m), -_score(m), m))
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

def pick_with_history(profiles):
    """pick() + preserva 1 modelo com historico forte que nao respondeu agora."""
    chosen = pick(profiles)
    for cat in profiles:
        for mid in stale_candidates(cat):
            if mid not in chosen:
                chosen.append(mid)
                stale_picked.append((mid, cat))
                return chosen
    return chosen

def full(mid):
    """Referencia completa para o config: provedor/nome."""
    return mid if "/" in bare(mid) or mid.startswith("9router/") else mid

def ref(mid):
    return mid if mid.startswith("9router/") else mid

config = json.load(open(config_path))
preset_name = config.get("preset", "9router")
preset = config.setdefault("presets", {}).setdefault(preset_name, {})

changes = []
for agent, profiles in AGENT_PROFILES.items():
    picked = pick_with_history(profiles)
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
    picked = pick_with_history(profiles)
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
stale_set = {m for m, _cat in stale_picked}

def _fmt(m):
    return m + " [histórico]" if m in stale_set else m

for agent in AGENT_PROFILES:
    chain = preset.get(agent, {}).get("model") or []
    mark = " ~" if any(c[0] == agent for c in changes) else "  "
    head = _fmt(chain[0]) if chain else "(vazio)"
    extra = "  → " + ", ".join(_fmt(m) for m in chain[1:]) if len(chain) > 1 else ""
    print(f" {mark} {agent:<13} {head}{extra}")
print()
for name in COUNCIL_PROFILES:
    entry = council.get("default", {}).get(name, {})
    mark = " ~" if any(c[0] == f"council.{name}" for c in changes) else "  "
    model = entry.get("model", "(vazio)")
    print(f" {mark} council/{name:<10} {_fmt(model)}")
print("=" * 78)
print()
if stale_picked:
    log("preservado(s) pelo historico (nao responderam nesta rodada, entram como fallback):")
    for mid, cat in dict.fromkeys(stale_picked):
        print(f"   - {mid}  (categoria {cat})")

# ------------------------------------------------------------- historico ----
# Grava a sonda no historico e registra a atribuicao de cada agente. Assim a
# proxima execucao ja parte de um ranking acumulado, e nao do zero.
# Somente quando o resultado foi realmente aplicado: --dry-run nao escreve.
if history_on and apply:
    try:
        _r = subprocess.run(
            ["zsh", history_sh, "merge",
             "--probe", probe_path, "--native", native_path],
            capture_output=True, text=True, timeout=60)
        for line in (_r.stdout or "").splitlines():
            if line.strip():
                log(line.replace("[history] ", "historico: "))
        for agent in AGENT_PROFILES:
            chain = preset.get(agent, {}).get("model") or []
            if chain:
                subprocess.run(
                    ["zsh", history_sh, "assignment", "--agent", agent,
                     "--models", ",".join(chain)],
                    capture_output=True, text=True, timeout=30)
        for name in COUNCIL_PROFILES:
            model = council.get("default", {}).get(name, {}).get("model")
            if model:
                subprocess.run(
                    ["zsh", history_sh, "assignment", "--agent", "council/" + name,
                     "--models", model],
                    capture_output=True, text=True, timeout=30)
        log(f"historico atualizado: {history_path}")
    except Exception as exc:
        log(f"AVISO: falha ao atualizar o historico ({exc})")

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
