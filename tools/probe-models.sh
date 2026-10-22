#!/usr/bin/env zsh
# tools/probe-models.sh
#
# Fase 3 do AGENTS.md: sondagem dos modelos do 9router.
#
# Para cada modelo do catalogo, mede:
#   - latencia (ttfb = time to first byte, total = tempo de resposta);
#   - codigo HTTP;
#   - suporte a tool calling (funcao `get_weather`, com tool_choice=auto).
#
# Grava uma linha JSON por modelo em `probe.jsonl` (JSON Lines) e um relatorio
# tabular no stdout.
#
# Regras do AGENTS.md:
#   - o tunel e intocavel: a sonda fala SEMPRE pelo relay publico, nunca
#     direto na porta 20128;
#   - o script e local e em zsh;
#   - idempotente: pode rodar quantas vezes quiser (o probe.jsonl e
#     reescrito a cada execucao, exceto com --append).
#
# Uso:
#   zsh tools/probe-models.sh                      # sonda todos os modelos
#   zsh tools/probe-models.sh --concurrency 6      # mais paralelismo
#   zsh tools/probe-models.sh --filter 'ag/'       # so a familia ag/
#   zsh tools/probe-models.sh --repeat 2           # 2 requisicoes por modelo
#   zsh tools/probe-models.sh --out probe.jsonl    # caminho de saida
#   zsh tools/probe-models.sh --models lista.txt   # sonda uma lista propria
#
# Variaveis de ambiente:
#   NINEROUTER_BASE_URL  (default: https://${NINEROUTER_RELAY_HOST}/v1)
#   NINEROUTER_API_KEY   (fallback: ~/.config/venice-stack/9router.env)
#   PROBE_CONCURRENCY    (default: 4)
#   PROBE_TIMEOUT        (default: 120, segundos por requisicao)
#   PROBE_REPEAT         (default: 1)

set -euo pipefail

BASE_URL="${NINEROUTER_BASE_URL:-https://${NINEROUTER_RELAY_HOST}/v1}"
CONCURRENCY="${PROBE_CONCURRENCY:-4}"
TIMEOUT="${PROBE_TIMEOUT:-120}"
REPEAT="${PROBE_REPEAT:-1}"
OUT="probe.jsonl"
MODELS_FILE=""
FILTER=""
APPEND=false

while (( $# > 0 )); do
  case "$1" in
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2";     shift 2 ;;
    --repeat)      REPEAT="$2";      shift 2 ;;
    --out)         OUT="$2";         shift 2 ;;
    --models)      MODELS_FILE="$2"; shift 2 ;;
    --filter)      FILTER="$2";      shift 2 ;;
    --append)      APPEND=true;      shift ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '[probe] %s\n' "$*"; }
warn() { printf '[probe] AVISO: %s\n' "$*" >&2; }
die()  { printf '[probe] ERRO: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- credenciais ---

# A chave vem do ambiente (regra do AGENTS.md: env no ~/.zshenv). Fallback para
# o arquivo de segredos, para o script funcionar fora de um shell com .zshenv.
if [[ -z "${NINEROUTER_API_KEY:-}" ]]; then
  SECRETS="${HOME}/.config/venice-stack/9router.env"
  [[ -r "$SECRETS" ]] || die "NINEROUTER_API_KEY ausente e $SECRETS ilegivel"
  NINEROUTER_API_KEY="$(grep '^NINEROUTER_API_KEY=' "$SECRETS" | cut -d= -f2-)"
fi
[[ -n "$NINEROUTER_API_KEY" ]] || die "NINEROUTER_API_KEY vazia"

BASE_URL="${BASE_URL%/}"

# ------------------------------------------------------- lista de modelos ----

if [[ -n "$MODELS_FILE" ]]; then
  [[ -r "$MODELS_FILE" ]] || die "lista de modelos ilegivel: $MODELS_FILE"
  MODELS=("${(@f)$(grep -v '^[[:space:]]*$' "$MODELS_FILE")}")
else
  log "consultando o catalogo em ${BASE_URL}/models ..."
  CATALOG="$(curl -sS --max-time 60 \
      -H "Authorization: Bearer ${NINEROUTER_API_KEY}" \
      "${BASE_URL}/models")" || die "falha ao consultar o catalogo"
  MODELS=("${(@f)$(printf '%s' "$CATALOG" | python3 -c "
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write('catalogo nao-JSON: ' + raw[:200] + '\n')
    raise SystemExit(1)
ids = [m['id'] for m in d.get('data', []) if m.get('id')]
if not ids:
    sys.stderr.write('catalogo vazio\n')
    raise SystemExit(1)
print('\n'.join(ids))
")}")
  log "catalogo: ${#MODELS[@]} modelos"
fi

if [[ -n "$FILTER" ]]; then
  FILTERED=()
  for m in "${MODELS[@]}"; do
    [[ "$m" == *"$FILTER"* ]] && FILTERED+=("$m")
  done
  MODELS=("${FILTERED[@]}")
  log "filtro '${FILTER}' -> ${#MODELS[@]} modelos"
fi

(( ${#MODELS[@]} > 0 )) || die "nenhum modelo para sondar"

# ---------------------------------------------------------------- workspace ---

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/probe-models.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# ------------------------------------------------------------------- worker ---

# Sonda UM modelo e grava um record JSON em $WORKDIR/<indice>.json.
probe_worker() {
  local idx="$1" model="$2"
  local tag; tag="$(printf '%04d' "$idx")"
  local out="$WORKDIR/$tag.json"
  local payload="$WORKDIR/$tag.req.json"
  local body="$WORKDIR/$tag.body"
  local errf="$WORKDIR/$tag.err"

  python3 - "$model" "$payload" <<'PY'
import json, sys
model, path = sys.argv[1], sys.argv[2]
req = {
    "model": model,
    "stream": False,
    "max_tokens": 256,
    "messages": [
        {"role": "user", "content": "Call the get_weather tool for Paris. Use the tool."}
    ],
    "tools": [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string", "description": "City name"}},
                "required": ["city"],
            },
        },
    }],
    "tool_choice": "auto",
}
open(path, "w").write(json.dumps(req))
PY

  local attempt=0 recorded=0 dropped_tool_choice=0
  local http_code="" ttfb="0" total="0"

  while (( attempt < REPEAT )); do
    attempt=$(( attempt + 1 ))

    local w
    w="$(curl -sS -o "$body" \
        -w '%{http_code} %{time_starttransfer} %{time_total}' \
        --max-time "$TIMEOUT" \
        -X POST "${BASE_URL}/chat/completions" \
        -H "Authorization: Bearer ${NINEROUTER_API_KEY}" \
        -H 'Content-Type: application/json' \
        --data-binary "@${payload}" 2>"$errf")" || w="000 0 0"

    read -r http_code ttfb total <<< "$w"

    # Alguns gateways rejeitam o parametro `tool_choice` (HTTP 400). Nesses
    # casos, refaz a mesma requisicao sem ele: o modelo ainda pode suportar
    # tools, e o que queremos medir e o tool calling, nao o parametro.
    if [[ "$http_code" == "400" ]] && (( dropped_tool_choice == 0 )) \
       && grep -qi "tool_choice" "$body" 2>/dev/null; then
      python3 - "$payload" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("tool_choice", None)
open(p, "w").write(json.dumps(d))
PY
      dropped_tool_choice=1
      attempt=$(( attempt - 1 ))   # o fallback nao conta como tentativa
      continue
    fi

    recorded=1
    break
  done

  if (( recorded == 1 )); then
    python3 - "$body" "$http_code" "$out" "$dropped_tool_choice" <<'PY'
import json, sys
body_path, http_code, out_path, dropped = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = ""
try:
    raw = open(body_path, "r", errors="replace").read()
except Exception:
    pass
data = {}
err = None
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    err = (raw[:300] or "resposta nao-JSON")
if err is None and http_code != "200":
    e = data.get("error")
    if isinstance(e, dict):
        err = str(e.get("message") or e)[:300]
    elif e:
        err = str(e)[:300]
    else:
        err = (raw[:300] or f"HTTP {http_code}")
choices = data.get("choices") or []
ch = choices[0] if choices else {}
msg = ch.get("message") or {}
tool_calls = msg.get("tool_calls") or []
tc = tool_calls[0] if tool_calls else {}
fn = tc.get("function") or {}
usage = data.get("usage") or {}
json.dump({
    "http_status": int(http_code),
    "finish_reason": ch.get("finish_reason"),
    "tool_call_ok": bool(fn.get("name")),
    "tool_name": fn.get("name") or "",
    "tool_args": fn.get("arguments") or "",
    "content_preview": (msg.get("content") or "")[:200],
    "prompt_tokens": usage.get("prompt_tokens"),
    "completion_tokens": usage.get("completion_tokens"),
    "tool_choice_dropped": dropped == "1",
    "error": err,
}, open(out_path, "w"))
PY
  else
    python3 - "$out" "$errf" <<'PY'
import json, sys
out, errf = sys.argv[1], sys.argv[2]
err = ""
try:
    err = open(errf, errors="replace").read()[:300]
except Exception:
    pass
json.dump({
    "http_status": 0, "finish_reason": None, "tool_call_ok": False,
    "tool_name": "", "tool_args": "", "content_preview": "",
    "prompt_tokens": None, "completion_tokens": None,
    "tool_choice_dropped": False,
    "error": err or "sem resposta (timeout/erro de rede)",
}, open(out, "w"))
PY
  fi

  # Consolida o record com o que o worker mediu.
  python3 - "$out" "$model" "$http_code" "$ttfb" "$total" "$attempt" <<'PY'
import json, os, sys, time
out, model, http_code, ttfb, total, attempts = sys.argv[1:7]
rec = {}
if os.path.exists(out):
    rec = json.load(open(out))
def ms(x):
    try:
        return int(float(x) * 1000)
    except Exception:
        return 0
rec.update({
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "model": model,
    "http_status": int(http_code) if str(http_code).isdigit() else 0,
    "ttfb_ms": ms(ttfb),
    "latency_ms": ms(total),
    "attempts": int(attempts),
})
json.dump(rec, open(out, "w"))
PY
}

# ------------------------------------------------------------------ execucao --

log "sondando ${#MODELS[@]} modelos · conc=${CONCURRENCY} · timeout=${TIMEOUT}s · repeat=${REPEAT}"
log "saida: ${OUT}"

if [[ "$APPEND" == "false" ]]; then
  : > "$OUT"
fi

n=${#MODELS[@]}
for (( i = 1; i <= n; i++ )); do
  probe_worker "$i" "${MODELS[$i]}" &
  if (( i % CONCURRENCY == 0 )); then wait; fi
done
wait

# Concatena em ordem de modelo (um JSON por linha).
for (( i = 1; i <= n; i++ )); do
  f="$WORKDIR/$(printf '%04d' "$i").json"
  if [[ -r "$f" ]]; then
    cat "$f" >> "$OUT"
    printf '\n' >> "$OUT"
  fi
done

# ------------------------------------------------------------------ relatorio --

python3 - "$OUT" <<'PY'
import json, sys
from collections import Counter

rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        try:
            rows.append(json.loads(line))
        except Exception:
            pass

total = len(rows)
ok_http = [r for r in rows if r.get("http_status") == 200]
tool_ok = [r for r in rows if r.get("tool_call_ok")]
both = [r for r in rows if r.get("http_status") == 200 and r.get("tool_call_ok")]

def med(xs):
    if not xs:
        return 0
    xs = sorted(xs)
    return xs[len(xs) // 2]

def pct(n):
    return f"{(100.0 * n / total):5.1f}%" if total else "  0.0%"

print()
print("=" * 78)
print(f"  RELATORIO DA SONDAGEM  ({total} modelos)")
print("=" * 78)
print(f"  HTTP 200                 : {len(ok_http):>3}  {pct(len(ok_http))}")
print(f"  tool calling OK          : {len(tool_ok):>3}  {pct(len(tool_ok))}")
print(f"  HTTP 200 + tool calling  : {len(both):>3}  {pct(len(both))}")
print()
print(f"  latencia mediana (todos os 200): {med([r['latency_ms'] for r in ok_http])} ms")
print(f"  latencia mediana (tool ok)    : {med([r['latency_ms'] for r in tool_ok])} ms")
print()

by_status = Counter(r.get("http_status") for r in rows)
print("  distribuicao de HTTP:")
for code, cnt in sorted(by_status.items(), key=lambda kv: -kv[1]):
    print(f"    {code if code else 'erro/timeout':>6} : {cnt}")
print()

fams = Counter(r["model"].split("/")[0] for r in rows)
print("  cobertura por familia:")
for fam, cnt in sorted(fams.items()):
    good = sum(1 for r in rows if r["model"].split("/")[0] == fam
               and r.get("http_status") == 200 and r.get("tool_call_ok"))
    print(f"    {fam:<8} {good:>3}/{cnt:<3} prontos")
print()

print("  erros/amostras:")
seen = set()
shown = 0
for r in rows:
    if r.get("http_status") == 200 and r.get("tool_call_ok"):
        continue
    key = (r.get("http_status"), (r.get("error") or "")[:60])
    if key in seen:
        continue
    seen.add(key)
    shown += 1
    if shown > 12:
        break
    err = (r.get("error") or "").replace("\n", " ")[:110]
    print(f"    {r['model']:<40} http={r.get('http_status')} {err}")
print()
print("=" * 78)
PY

log "resultado em ${OUT} ($(wc -l < "$OUT") linhas)"
