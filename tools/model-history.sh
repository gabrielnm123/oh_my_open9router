#!/usr/bin/env zsh
# tools/model-history.sh
#
# Histórico persistente de modelos: sonda + pesquisa (web) por papel.
#
# O seletor consulta este arquivo para ordenar os candidatos de cada agente e
# para não esquecer um modelo que hoje não respondeu mas tem histórico bom.
# A pesquisa em si é feita pelo agente que roda o comando de barra (websearch);
# aqui só se grava e se consulta o resultado.
#
# ARQUIVO: ${ROOT}/model-history.json (permissao 600, gitignored)
#   ROOT = raiz do repo quando rodando de dentro dele; senao a pasta dos
#   scripts instalados (~/.local/share/9router-tools).
#
# Uso:
#   zsh tools/model-history.sh path
#   zsh tools/model-history.sh record --model M --role PAPEL --score 0.0-1.0 \
#        --verdict best|good|weak|bad --source URL [--note "texto"]
#   zsh tools/model-history.sh merge --probe probe.jsonl [--native probe-native.jsonl]
#   zsh tools/model-history.sh score --role CATEGORIA [--agents a,b] [--json]
#   zsh tools/model-history.sh ranking [--role PAPEL] [--limit 20]
#   zsh tools/model-history.sh assignment --agent AGENTE --models m1,m2,m3
#   zsh tools/model-history.sh show --model M
#
# PAPEL/CATEGORIA aceitos: orchestrator, oracle, explorer, designer, fixer,
# observer, council, council/architect, council/reviewer, council/optimiser,
# council/visual, werkzeug, rapido, raciocinio, visao, nao_critico.
#
# `record` aceita qualquer papel; o seletor consulta primeiro o nome do agente
# e, se nao houver nota, a categoria que ele usa.

set -euo pipefail

SELF="${0:A}"
TOOLS_DIR="${SELF:h}"
if [[ -e "${TOOLS_DIR:h}/.git" ]]; then
  ROOT="${TOOLS_DIR:h}"
else
  ROOT="${TOOLS_DIR}"
fi

HISTORY="${MODEL_HISTORY:-${ROOT}/model-history.json}"
CMD="${1:-help}"
shift || true

python3 - "$CMD" "$HISTORY" "$@" <<'PY'
import json
import os
import sys
import time

cmd, path = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]

ROLES = {
    "orchestrator", "oracle", "explorer", "designer", "fixer", "observer",
    "council", "council/architect", "council/reviewer", "council/optimiser",
    "council/visual", "werkzeug", "rapido", "raciocinio", "visao",
    "nao_critico",
}
VERDICTS = {"best", "good", "weak", "bad"}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def opt(flag, default=None):
    if flag not in argv:
        return default
    i = argv.index(flag)
    if i + 1 >= len(argv):
        raise SystemExit(f"[history] ERRO: {flag} exige um valor")
    return argv[i + 1]


def load():
    base = {"version": 1, "updated_at": now(), "last_probe_run": None,
            "models": {}, "assignments": []}
    if not os.path.exists(path):
        return base
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as exc:
        raise SystemExit(f"[history] ERRO: {path} ilegivel ({exc})")
    if not isinstance(data, dict):
        raise SystemExit(f"[history] ERRO: {path} nao contem um objeto JSON")
    base.update(data)
    base.setdefault("models", {})
    base.setdefault("assignments", [])
    return base


def save(data):
    data["updated_at"] = now()
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def model_entry(data, mid):
    m = data["models"].setdefault(mid, {})
    m.setdefault("first_seen", now())
    m.setdefault("last_seen", now())
    m.setdefault("probe", {"ok": 0, "fail": 0, "last": {}})
    m.setdefault("research", {})
    m.setdefault("research_log", [])
    m.setdefault("assigned", {})
    m.setdefault("last_assigned", {})
    return m


def bad(msg):
    raise SystemExit(f"[history] ERRO: {msg}")


if cmd in ("help", "-h", "--help"):
    print(__doc__ or "zsh tools/model-history.sh <record|merge|score|ranking|assignment|show|path>")
    print("ver: zsh tools/model-history.sh path")
    raise SystemExit(0)

if cmd == "path":
    print(path)
    raise SystemExit(0)

if cmd == "record":
    mid = opt("--model")
    role = opt("--role")
    score = opt("--score")
    verdict = opt("--verdict", "good")
    if not mid or not role or score is None:
        bad("record exige --model, --role e --score")
    if role not in ROLES:
        bad(f"papel desconhecido: {role} (aceitos: {', '.join(sorted(ROLES))})")
    if verdict not in VERDICTS:
        bad(f"veredito invalido: {verdict} (aceitos: {', '.join(sorted(VERDICTS))})")
    try:
        score = float(score)
    except ValueError:
        bad(f"score invalido: {score}")
    if not 0.0 <= score <= 1.0:
        bad("score precisa estar entre 0.0 e 1.0")

    data = load()
    m = model_entry(data, mid)
    rec = {
        "ts": now(),
        "role": role,
        "score": score,
        "verdict": verdict,
        "source": opt("--source", ""),
        "note": opt("--note", ""),
    }
    m["research_log"].append(rec)
    m["research_log"] = m["research_log"][-50:]
    prev = m["research"].get(role)
    if not prev or score >= prev.get("score", 0) or rec["ts"] >= prev.get("ts", ""):
        m["research"][role] = {k: rec[k] for k in ("score", "verdict", "source", "note", "ts")}
    m["last_seen"] = now()
    save(data)
    print(f"[history] {mid} :: {role} = {score:.2f} ({verdict})"
          + (f" — {rec['source']}" if rec["source"] else ""))
    raise SystemExit(0)

if cmd == "merge":
    probe = opt("--probe")
    native = opt("--native")
    if not probe:
        bad("merge exige --probe <arquivo>")
    rows = []
    for p, origin in ((probe, "9router"), (native, "native")):
        if not p or not os.path.exists(p):
            continue
        for line in open(p, errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            row["_origin"] = origin
            rows.append(row)
    if not rows:
        print("[history] nada para importar (sonda vazia)")
        raise SystemExit(0)

    run_id = max((r.get("ts") or "") for r in rows) or now()
    data = load()
    if data.get("last_probe_run") == run_id:
        print(f"[history] sonda {run_id} ja importada; nada a fazer")
        raise SystemExit(0)

    for r in rows:
        mid = r.get("model")
        if not mid:
            continue
        # A origem vem do arquivo, nunca do formato do ID: um modelo do 9router
        # pode ter barra no nome (ex.: cbai/minimax-m3).
        if mid.startswith("9router/") or r.get("_origin") != "native":
            ref = mid if mid.startswith("9router/") else "9router/" + mid
        else:
            ref = mid
        m = model_entry(data, ref)
        last = (m.get("probe") or {}).get("last") or {}
        # Mesma linha (mesmo ts) ja contabilizada: nao duplica a contagem.
        if r.get("ts") and r.get("ts") <= (last.get("ts") or ""):
            continue
        ok = r.get("http_status") == 200 and bool(r.get("tool_call_ok"))
        m["probe"]["ok" if ok else "fail"] += 1
        m["probe"]["last"] = {
            "ts": r.get("ts"),
            "http_status": r.get("http_status"),
            "tool_call_ok": bool(r.get("tool_call_ok")),
            "latency_ms": r.get("latency_ms"),
        }
        m["last_seen"] = r.get("ts") or now()
    data["last_probe_run"] = run_id
    save(data)
    print(f"[history] sonda {run_id} importada: {len(rows)} modelos")
    raise SystemExit(0)

if cmd == "score":
    role = opt("--role")
    agents = [a for a in (opt("--agents", "") or "").split(",") if a]
    if not role:
        bad("score exige --role")
    wanted = [role] + [a for a in agents if a != role]
    data = load()
    out = {}
    for mid, m in data["models"].items():
        research = 0.0
        for r in wanted:
            rec = (m.get("research") or {}).get(r)
            if rec and rec.get("score", 0) > research:
                research = rec["score"]
        probe = m.get("probe") or {}
        assigned = max([(m.get("assigned") or {}).get(a, 0) for a in wanted] or [0])
        out[mid] = {
            "research": round(research, 3),
            "ok": probe.get("ok", 0),
            "fail": probe.get("fail", 0),
            "assigned": assigned,
            "last": probe.get("last", {}),
        }
    print(json.dumps(out))
    raise SystemExit(0)

if cmd == "assignment":
    agent = opt("--agent")
    models = [m for m in (opt("--models", "") or "").split(",") if m]
    if not agent or not models:
        bad("assignment exige --agent e --models")
    data = load()
    for mid in models:
        m = model_entry(data, mid)
        m["assigned"][agent] = m["assigned"].get(agent, 0) + 1
        m["last_assigned"][agent] = now()
    data["assignments"].append({"ts": now(), "agent": agent, "models": models})
    data["assignments"] = data["assignments"][-500:]
    save(data)
    print(f"[history] {agent} <- {', '.join(models)}")
    raise SystemExit(0)

if cmd == "ranking":
    role = opt("--role")
    try:
        limit = int(opt("--limit", "20"))
    except ValueError:
        limit = 20
    data = load()
    rows = []
    for mid, m in data["models"].items():
        roles = m.get("research") or {}
        if role:
            rec = roles.get(role)
            if not rec:
                continue
            score = rec.get("score", 0)
            verdict = rec.get("verdict", "")
        else:
            score = max([r.get("score", 0) for r in roles.values()] or [0])
            verdict = ""
        probe = m.get("probe") or {}
        rows.append((score, probe.get("ok", 0), probe.get("fail", 0), mid, verdict))
    rows.sort(key=lambda x: (-x[0], -(x[1] - x[2]), x[3]))
    if not rows:
        print("[history] vazio" + (f" para {role}" if role else ""))
        raise SystemExit(0)
    print(f"{'score':>6}  {'ok/fail':>7}  {'verdict':<8}  modelo")
    for score, ok, fail, mid, verdict in rows[:limit]:
        print(f"{score:>6.2f}  {ok:>3}/{fail:<3}  {verdict:<8}  {mid}")
    raise SystemExit(0)

if cmd == "show":
    mid = opt("--model")
    if not mid:
        bad("show exige --model")
    data = load()
    m = data["models"].get(mid)
    if not m:
        print(f"[history] {mid}: sem registros")
        raise SystemExit(0)
    print(json.dumps(m, indent=2, ensure_ascii=False, sort_keys=True))
    raise SystemExit(0)

bad(f"comando desconhecido: {cmd} (use: record|merge|score|ranking|assignment|show|path)")
PY
