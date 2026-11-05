#!/usr/bin/env zsh
# tools/select-models-uncensored.sh
#
# Variante do select-models.sh que prioriza modelos mais próximos de
# "uncensored" / menos censurados disponíveis no 9router (e nativos).
#
# CRITÉRIO DE PRIORIDADE (ordem decrescente de preferência):
#   1. cx/  — roteadores custom do 9router (luna, terra, reserve, codex):
#              modelos proprietários com filtragem mínima, sem política
#              OpenAI/Anthropic/Google.
#   2. gcli/ — Grok (xAI): bem menos restritivo que os grandes labs.
#   3. nous/ — herança Hermes/Dolphin da Nous Research: fine-tunes abertos
#              com alinhamento suave.
#   4. kc/nvidia/ — Nemotron: modelos abertos da NVIDIA, permissivos.
#   5. ag/   — proxy do 9router para modelos Gemini: menos restritivo que
#              acessos diretos Google/Anthropic.
#   6. gh/   — fallback GitHub Copilot (mais censurado, mas funcional).
#   7. nativos OpenCode — último recurso.
#
# Tudo o mais (lógica de sonda, backup, dry-run, restart) é idêntico ao
# select-models.sh original.
#
# Uso:
#   zsh tools/select-models-uncensored.sh              # dry-run
#   zsh tools/select-models-uncensored.sh --apply      # grava + não reinicia
#   zsh tools/select-models-uncensored.sh --probe      # roda sonda antes
#   zsh tools/select-models-uncensored.sh --quick      # sonda rápida e aplica
#   zsh tools/select-models-uncensored.sh --no-restart # grava sem reiniciar
#   zsh tools/select-models-uncensored.sh --restart    # força restart do daemon
#   zsh tools/select-models-uncensored.sh --dry-run    # alias explícito
#   zsh tools/select-models-uncensored.sh --config <path>  # outro config
#
# Variáveis de ambiente:
#   NINEROUTER_BASE_URL  (obrigatório; vem do .env)
#   NINEROUTER_API_KEY   (obrigatório; vem do .env)

set -euo pipefail

SELF="${0:A}"
TOOLS_DIR="${SELF:h}"
if [[ -e "${TOOLS_DIR:h}/.git" ]]; then
  ROOT="${TOOLS_DIR:h}"
else
  ROOT="${TOOLS_DIR}"
fi

source "${TOOLS_DIR}/lib/venice-env.sh"

# ----------------------------------------------------------------- flags ----
apply=false
no_restart=false
do_restart=false
do_probe=false
probe_quick=false
only_native=false
dry_run=false
config_path=""
probe_filter=""
history_path="${ROOT}/model-history.json"

for arg in "$@"; do
  case "$arg" in
    --apply)        apply=true ;;
    --dry-run)      dry_run=true ;;
    --no-restart)   no_restart=true ;;
    --restart)      do_restart=true ;;
    --probe)        do_probe=true ;;
    --quick)        do_probe=true; probe_quick=true ;;
    --only-native)  only_native=true ;;
    --config=*)     config_path="${arg#--config=}" ;;
    --config)       : ;;  # próximo arg ignorado; zsh não tem shift fácil aqui
    --history=*)    history_path="${arg#--history=}" ;;
    --no-history)   history_path="" ;;
    --probe-filter=*) probe_filter="${arg#--probe-filter=}" ;;
    *)              printf '[select-uncensored] AVISO: argumento ignorado: %s\n' "$arg" >&2 ;;
  esac
done

[[ "$dry_run" == true ]] && apply=false

# ----------------------------------------------------------------- sonda ----
probe_path="${ROOT}/probe.jsonl"
native_path="${ROOT}/probe-native.jsonl"
config_path="${config_path:-${HOME}/.config/opencode/oh-my-opencode-slim.json}"
# O catálogo é buscado ao vivo (mesmo que o select-models.sh), nunca de um
# arquivo local antigo: um modelo pode sair do catálogo sem sair da sonda.
catalog_path="$(mktemp "${TMPDIR:-/tmp}/select-uncensored-catalog.XXXXXX")"
trap 'rm -f "$catalog_path"' EXIT
if [[ -n "${NINEROUTER_BASE_URL:-}" && -n "${NINEROUTER_API_KEY:-}" ]]; then
  curl -sS --max-time 60 -H "Authorization: Bearer ${NINEROUTER_API_KEY}" \
    "${NINEROUTER_BASE_URL%/}/models" -o "$catalog_path" 2>/dev/null || : > "$catalog_path"
  [[ -s "$catalog_path" ]] || warn "catálogo do 9router indisponível; a classificação usará só a sonda"
else
  warn "NINEROUTER_API_KEY/NINEROUTER_BASE_URL ausentes; a classificação usará só a sonda"
  : > "$catalog_path"
fi

if [[ "$do_probe" == true ]]; then
  probe_args=(--concurrency 6)
  [[ "$probe_quick" == true ]] && probe_args+=(--quick)
  [[ -n "$probe_filter" ]] && probe_args+=(--filter "$probe_filter")
  printf '[select-uncensored] rodando sonda...\n'
  zsh "${TOOLS_DIR}/probe-models.sh" "${probe_args[@]}"
fi

if [[ ! -f "$probe_path" ]]; then
  printf '[select-uncensored] ERRO: probe.jsonl ausente. Rode com --probe.\n' >&2
  exit 1
fi

# -------------------------------------------------------------- python ------
python3 - \
  "$probe_path" \
  "${native_path:-/dev/null}" \
  "${catalog_path:-/dev/null}" \
  "$config_path" \
  "$apply" \
  "$only_native" \
  "$no_restart" \
  "$do_restart" \
  "$history_path" \
  "${TOOLS_DIR}/model-history.sh" \
  <<'PYEOF'
import sys, json, os, subprocess, shutil, datetime

probe_path, native_path, catalog_path, config_path, \
  apply_str, only_native_str, no_restart_str, do_restart_str, \
  history_path, history_sh = sys.argv[1:11]

apply       = apply_str       == "true"
only_native = only_native_str == "true"
no_restart  = no_restart_str  == "true"
do_restart  = do_restart_str  == "true"
history_on  = os.path.exists(history_sh)

def log(msg): print(f"[select-uncensored] {msg}", flush=True)

def read_jsonl(path):
    rows = []
    if not os.path.exists(path) or os.path.getsize(path) == 0:
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
for r in read_jsonl(probe_path):
    if r.get("model"):
        probes["9router/" + r["model"]] = r
for r in read_jsonl(native_path):
    if r.get("model"):
        probes[r["model"]] = r

if not probes:
    raise SystemExit("[select-uncensored] ERRO: nenhuma sonda legível; rode com --probe")

# --------------------------------------------------------- metadados --------
native_meta = {}
try:
    out = subprocess.run(["opencode", "api", "get", "/api/model"],
                         capture_output=True, text=True, timeout=60).stdout
    for m in json.loads(out).get("data", []):
        if not m.get("providerID") or m["providerID"] == "9router":
            continue
        caps = m.get("capabilities") or {}
        lim  = m.get("limit") or {}
        native_meta[f"{m['providerID']}/{m['id']}"] = {
            "vision":    "image" in (caps.get("input") or []),
            "reasoning": "reasoning" in (caps.get("input") or [])
                         or bool(caps.get("reasoning"))
                         or bool(m.get("variants")),
            "ctx":     int(lim.get("context") or caps.get("contextWindow") or 200000),
            "max_out": int(lim.get("output")  or caps.get("maxOutput")     or 64000),
        }
except Exception as exc:
    log(f"AVISO: metadados nativos indisponíveis ({exc})")

catalog_meta = {}
if os.path.exists(catalog_path) and os.path.getsize(catalog_path) > 0:
    try:
        for m in json.load(open(catalog_path)).get("data", []):
            if not m.get("id"):
                continue
            c = m.get("capabilities") or {}
            catalog_meta[m["id"]] = {
                "vision":    bool(c.get("vision")),
                "reasoning": bool(c.get("reasoning")),
                "ctx":     int(m.get("context_length") or c.get("contextWindow") or 200000),
                "max_out": int(m.get("max_completion_tokens") or c.get("maxOutput") or 64000),
            }
    except Exception as exc:
        log(f"AVISO: catálogo do 9router ilegível ({exc})")

# ------------------------------------------------ critério uncensored -------
# Ordem de prioridade de família (menor = mais preferido).
# Lógica: quanto mais proprietário/restritivo o provider upstream,
# mais alto o número (pior colocado no ranking uncensored).

UNCENSORED_TIERS = [
    # tier 0 — roteadores custom do 9router: sem política OpenAI/Anthropic
    ("cx/",),
    # tier 1 — Grok (xAI): bem menos restritivo
    ("gcli/",),
    # tier 2 — Nous Research (herança Hermes/Dolphin, fine-tunes abertos)
    ("nous/",),
    # tier 3 — NVIDIA Nemotron (aberto, permissivo)
    ("kc/nvidia/",),
    # tier 4 — proxy ag/ do 9router (Gemini via 9router: menos restritivo que acesso direto)
    ("ag/",),
    # tier 5 — kc/ outros (OpenRouter via kilo.codes, variado)
    ("kc/",),
    # tier 6 — gh/ (GitHub Copilot: mais censurado, mas funcional)
    ("gh/",),
    # tier 7+ — nativos do OpenCode (último recurso)
]

def uncensored_tier(mid):
    """Retorna (tier_uncensored, tier_9router).
    Menor = mais preferido no ranking uncensored."""
    bare_id = mid[len("9router/"):] if mid.startswith("9router/") else mid
    is_9router = mid.startswith("9router/")
    for i, prefixes in enumerate(UNCENSORED_TIERS):
        for pfx in prefixes:
            if bare_id.startswith(pfx):
                # Modelos do 9router têm bônus adicional dentro do mesmo tier
                return (i, 0 if is_9router else 1)
    # Não mapeado: vai para o fim; nativos do OpenCode depois dos 9router
    return (len(UNCENSORED_TIERS), 0 if is_9router else 1)

# ------------------------------------------------------------ helpers -------
def approved(r):
    return r.get("http_status") == 200 and r.get("tool_call_ok")

def bare(mid):
    return mid[len("9router/"):] if mid.startswith("9router/") else mid

def meta(mid):
    b = bare(mid)
    if mid in catalog_meta: return catalog_meta[mid]
    if b in catalog_meta:   return catalog_meta[b]
    if mid in native_meta:  return native_meta[mid]
    if b in native_meta:    return native_meta[b]
    return {"vision": False, "reasoning": False, "ctx": 200000, "max_out": 64000}

def probe_for(mid):
    return (probes.get(mid)
            or probes.get("9router/" + bare(mid))
            or probes.get(bare(mid))
            or {})

def reward_penalty(mid):
    low = mid.lower()
    if ":free" in low or "-free" in low:
        return -200
    return 0

def quality(mid):
    m   = meta(mid)
    r   = probe_for(mid)
    lat = r.get("latency_ms") or 60000
    return (
        reward_penalty(mid)
        + min(m["ctx"],     1_000_000) // 100_000
        + min(m["max_out"], 128_000)   // 16_000
        + (4 if m["reasoning"] else 0)
        + (2 if m["vision"]    else 0)
        - min(lat, 60000) // 1000
    )

def speed(mid):
    r   = probe_for(mid)
    lat = r.get("latency_ms") or 60000
    return -min(lat, 60000) // 100 + quality(mid) // 1000

# ------------------------------------------------------------ universo ------
universe = set()
for mid, r in probes.items():
    if approved(r):
        universe.add(mid)
# Nativo so entra se passou na sonda: catalogo do OpenCode nao e prova de vida.
nao_sonados = sorted(m for m in native_meta if m not in probes)
if nao_sonados:
    log(f"AVISO: {len(nao_sonados)} nativo(s) sem sonda valida; ficam fora")
if only_native:
    universe = {m for m in universe if not m.startswith("9router/")}

uncensored_pool   = [m for m in universe]
uncensored_native = [m for m in universe if not m.startswith("9router/")]
uncensored_9r     = [m for m in universe if m.startswith("9router/")]

log(f"aprovados: {len(uncensored_9r)} no 9router · {len(uncensored_native)} nativos do OpenCode")

# Ordena pelo critério uncensored primeiro, qualidade como desempate
def sort_key_uncensored(mid):
    ut, pt = uncensored_tier(mid)
    return (ut, pt, -quality(mid), mid)

def sort_key_uncensored_speed(mid):
    ut, pt = uncensored_tier(mid)
    return (ut, pt, -speed(mid), mid)

# Categorias idênticas ao select-models.sh
CATEGORIES = {
    "werkzeug":    sort_key_uncensored,
    "rapido":      sort_key_uncensored_speed,
    "raciocinio":  sort_key_uncensored,
    "visao":       sort_key_uncensored,
    "nao_critico": sort_key_uncensored_speed,
}

REQUIRES = {
    "werkzeug":    lambda mid: True,
    "rapido":      lambda mid: True,
    "raciocinio":  lambda mid: meta(mid)["reasoning"],
    "visao":       lambda mid: meta(mid)["vision"],
    "nao_critico": lambda mid: True,
}

# ------------------------------------------------------------- historico -----
CAT_AGENTS = {
    "werkzeug":    ["orchestrator", "designer", "fixer", "observer", "council",
                    "council/reviewer", "council/optimiser"],
    "raciocinio":  ["oracle", "council/architect"],
    "rapido":      ["explorer", "council/optimiser"],
    "visao":       ["observer", "designer", "council/visual"],
    "nao_critico": ["orchestrator", "oracle", "explorer", "designer", "fixer",
                    "observer", "council"],
}

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
for cat, key_fn in CATEGORIES.items():
    pool = [m for m in universe if REQUIRES[cat](m)]
    def _key(m, cat=cat, key_fn=key_fn):
        ut, pt = uncensored_tier(m)
        research, assigned = hscore(m, cat)
        base = key_fn(m)[2]          # -quality/-speed
        return (ut, pt, base - 1000.0 * research - 5 * assigned, m)
    pools[cat] = sorted(pool, key=_key)
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

AGENT_PROFILES = {
    "orchestrator": ["werkzeug", "raciocinio", "nao_critico"],
    "oracle":       ["raciocinio", "werkzeug",  "nao_critico"],
    "explorer":     ["rapido",    "werkzeug",   "nao_critico"],
    "designer":     ["werkzeug",  "visao",      "nao_critico"],
    "fixer":        ["werkzeug",  "raciocinio", "nao_critico"],
    "observer":     ["visao",     "werkzeug",   "nao_critico"],
    "council":      ["werkzeug",  "raciocinio", "nao_critico"],
}

COUNCIL_PROFILES = {
    "architect": ["raciocinio", "werkzeug",  "nao_critico"],
    "reviewer":  ["werkzeug",   "raciocinio","nao_critico"],
    "optimiser": ["werkzeug",   "rapido",    "nao_critico"],
    "visual":    ["visao",      "werkzeug",  "nao_critico"],
}

COUNCIL_PROMPTS = {
    "architect": "Focus on maintainability, boundaries, and long-term design.",
    "reviewer":  "Focus on bugs, edge cases, and failure modes.",
    "optimiser": "Focus on performance, latency, and resource usage.",
    "visual":    "Focus on UI/UX correctness, accessibility, and visual details.",
}

if not os.path.exists(config_path):
    raise SystemExit(f"[select-uncensored] ERRO: config não encontrado: {config_path}")

config      = json.load(open(config_path))
preset_name = config.get("preset", "9router")
preset      = config.setdefault("presets", {}).setdefault(preset_name, {})

changes = []
for agent, profiles in AGENT_PROFILES.items():
    picked = pick_with_history(profiles)
    if not picked:
        log(f"AVISO: sem modelo para '{agent}'; mantendo valor atual")
        continue
    entry = preset.setdefault(agent, {})
    old   = entry.get("model")
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

# ------------------------------------------------------------ resumo --------
print()
print("=" * 78)
print(f"  ATRIBUIÇÃO UNCENSORED — {len(uncensored_9r)} do 9router · {len(uncensored_native)} nativos")
print("  Ordem: cx/ → gcli/ → nous/ → kc/nvidia/ → ag/ → kc/ → gh/ → nativos")
print("=" * 78)

# mostra tier uncensored de cada escolha
for agent in AGENT_PROFILES:
    chain = preset.get(agent, {}).get("model") or []
    mark  = " ~" if any(c[0] == agent for c in changes) else "  "
    head  = chain[0] if chain else "(vazio)"
    ut, _ = uncensored_tier(head)
    fam   = UNCENSORED_TIERS[ut][0] if ut < len(UNCENSORED_TIERS) else "outro"
    extra = "  → " + ", ".join(chain[1:]) if len(chain) > 1 else ""
    print(f" {mark} {agent:<13} [{fam:<12}] {head}{extra}")

print()
for name in COUNCIL_PROFILES:
    entry = council.get("default", {}).get(name, {})
    mark  = " ~" if any(c[0] == f"council.{name}" for c in changes) else "  "
    head  = entry.get("model", "(vazio)")
    ut, _ = uncensored_tier(head) if head != "(vazio)" else (99, 0)
    fam   = UNCENSORED_TIERS[ut][0] if ut < len(UNCENSORED_TIERS) else "outro"
    print(f" {mark} council/{name:<10} [{fam:<12}] {head}")

print("=" * 78)
print()

stale_set = {m for m, _cat in stale_picked}
if stale_set:
    log("preservado(s) pelo historico (nao responderam nesta rodada, entram como fallback): "
        + ", ".join(sorted(stale_set)))

# ------------------------------------------------------------ historico -----
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
    log("nada a fazer: agentes já apontam para os melhores modelos uncensored aprovados.")
    raise SystemExit(0)

log(f"{len(changes)} papel(is) mudariam de modelo:")
for agent, old, new in changes:
    head = new[0] if isinstance(new, list) else new
    print(f"   - {agent}\n       antes:  {old}\n       depois: {head}")

if not apply:
    print()
    log("dry-run. Para gravar: zsh tools/select-models-uncensored.sh --apply")
    raise SystemExit(0)

# ------------------------------------------------------------ backup --------
backup_dir = os.path.join(os.path.expanduser("~"), ".config", "opencode", "backups")
os.makedirs(backup_dir, exist_ok=True)
ts         = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup     = os.path.join(backup_dir, f"oh-my-opencode-slim.{ts}.json")
shutil.copy2(config_path, backup)
log(f"backup: {backup}")

with open(config_path, "w") as fh:
    json.dump(config, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(config_path, 0o600)
log(f"gravado: {config_path}")

if do_restart and not no_restart:
    try:
        subprocess.run(["opencode", "service", "restart"], check=True, timeout=30)
        log("daemon reiniciado.")
    except Exception as exc:
        log(f"AVISO: restart falhou ({exc}); reinicie manualmente.")
elif not no_restart and not do_restart:
    log("restart pendente. Rode: opencode service restart")

PYEOF
