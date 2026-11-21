#!/usr/bin/env python3
# tools/lib/probe-sort-models.py
#
# Recebe o JSON do catálogo via stdin e o caminho do model-history.json
# como argv[1]. Imprime os IDs dos modelos ordenados: modelos com histórico
# best/good primeiro (por score desc), sem histórico no meio, bad por último.
# Idempotente: se o histórico não existir ou falhar, usa a ordem original.

import json, sys, os

raw = sys.stdin.read()
hist_path = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write('[probe] catalogo nao-JSON: ' + raw[:200] + '\n')
    raise SystemExit(1)

ids = [m['id'] for m in d.get('data', []) if m.get('id')]
if not ids:
    sys.stderr.write('[probe] catalogo vazio\n')
    raise SystemExit(1)

# Carrega histórico: {id -> (verdict_priority, best_score)}
# verdict: best=3, good=2, (sem)=1, weak=0, bad=-1
VMAP = {'best': 3, 'good': 2, 'weak': 0, 'bad': -1}
hist = {}
try:
    if hist_path and os.path.exists(hist_path):
        h = json.load(open(hist_path, errors='replace'))
        for mid, data in h.items():
            if not isinstance(data, dict):
                continue
            roles = data.get('roles', {})
            if not isinstance(roles, dict):
                continue
            scores = [r.get('score', 0) for r in roles.values()
                      if isinstance(r, dict) and r.get('score') is not None]
            verdicts = [r.get('verdict', '') for r in roles.values()
                        if isinstance(r, dict)]
            best_score   = max(scores)   if scores   else 0.0
            best_verdict = max((VMAP.get(v, 1) for v in verdicts), default=1)
            hist[mid] = (best_verdict, best_score)
except Exception as e:
    sys.stderr.write(f'[probe] aviso: falha ao ler historico ({e}); ordem padrao\n')

def sort_key(mid):
    # histórico pode usar o ID sem prefixo de provedor
    short = mid.split('/', 1)[-1] if '/' in mid else mid
    entry = hist.get(mid) or hist.get(short)
    if entry:
        v, s = entry
    else:
        v, s = 1, 0.0        # sem histórico: neutro
    return (-v, -s)          # maior verdict/score → topo

ids_sorted = sorted(ids, key=sort_key)

n_hist = sum(1 for m in ids_sorted
             if hist.get(m) or hist.get(m.split('/', 1)[-1] if '/' in m else m))
if n_hist:
    sys.stderr.write(f'[probe] historico: {n_hist}/{len(ids_sorted)} modelos priorizados pelo ranking\n')

print('\n'.join(ids_sorted))
