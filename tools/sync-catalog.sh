#!/usr/bin/env zsh
# tools/sync-catalog.sh
#
# Sincroniza `providers.9router.models` do `~/.config/opencode/opencode.json`
# com o catalogo VIVO do 9router (`GET {NINEROUTER_BASE_URL}/models`).
#
# Motivo: o `opencode.json` lista os modelos um a um. Quando o 9router ganha
# (ou perde) um provedor, o catalogo muda e a config fica velha — o modelo
# existe no `/models` mas nao aparece em `opencode models` nem no seletor do
# TUI. Este script resolve exatamente essa deriva.
#
# O que ele NAO faz: nao toca em `$schema`, `model` (raiz), `plugin`, `lsp`
# nem em qualquer outra chave do arquivo; nao altera o `oh-my-opencode-slim.json`
# (para isso existe `tools/sync-models.sh`, que trabalha sobre a sonda).
#
# Uso:
#   zsh tools/sync-catalog.sh                 # dry-run: mostra o que mudaria
#   zsh tools/sync-catalog.sh --apply         # grava (com backup antes)
#   zsh tools/sync-catalog.sh --dry-run       # explicito (default; cancela --apply)
#   zsh tools/sync-catalog.sh --only 'qd/'    # so familias/prefixos indicados
#   zsh tools/sync-catalog.sh --refresh       # reescreve limits/caps dos existentes
#   zsh tools/sync-catalog.sh --prune         # remove os que sumiram do catalogo
#
# Combinacoes uteis:
#   zsh tools/sync-catalog.sh --only 'qd/,kc/' --apply
#   zsh tools/sync-catalog.sh --refresh --prune --apply
#
# Regras do AGENTS.md respeitadas:
#   - segredos/URL so do `.env` (via tools/lib/venice-env.sh), nada hardcoded;
#   - idempotente: rodar duas vezes seguidas nao muda nada na segunda;
#   - backup antes de qualquer alteracao, permissao 600 preservada.

set -euo pipefail

source "${0:A:h}/lib/venice-env.sh"

CONFIG="${HOME}/.config/opencode/opencode.json"
BACKUP_DIR="${HOME}/.config/opencode/backups"
BASE_URL="${NINEROUTER_BASE_URL:-}"
APPLY=false
PRUNE=false
REFRESH=false
ONLY=""

while (( $# > 0 )); do
  case "$1" in
    --apply)   APPLY=true;   shift ;;
    --dry-run) APPLY=false;  shift ;;
    --prune)   PRUNE=true;   shift ;;
    --refresh) REFRESH=true; shift ;;
    --only)    ONLY="$2";    shift 2 ;;
    --config)  CONFIG="$2";  shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf '[catalog] opcao desconhecida: %s\n' "$1" >&2; exit 1 ;;
  esac
done

log()  { printf '[catalog] %s\n' "$*"; }
die()  { printf '[catalog] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -n "$BASE_URL" ]] || die "NINEROUTER_BASE_URL ausente (defina no .env da raiz do projeto)"

if [[ -z "${NINEROUTER_API_KEY:-}" ]]; then
  SECRETS="${HOME}/.config/venice-stack/9router.env"
  [[ -r "$SECRETS" ]] || die "NINEROUTER_API_KEY ausente e $SECRETS ilegivel"
  NINEROUTER_API_KEY="$(strip_quotes "$(grep '^NINEROUTER_API_KEY=' "$SECRETS" | cut -d= -f2-)")"
fi
[[ -n "$NINEROUTER_API_KEY" ]] || die "NINEROUTER_API_KEY vazia"
[[ -r "$CONFIG" ]] || die "config ilegivel: $CONFIG"

CATALOG="$(mktemp "${TMPDIR:-/tmp}/sync-catalog.XXXXXX")"
trap 'rm -f "$CATALOG"' EXIT

log "consultando o catalogo em ${BASE_URL%/}/models ..."
curl -sS --max-time 60 \
  -H "Authorization: Bearer ${NINEROUTER_API_KEY}" \
  "${BASE_URL%/}/models" -o "$CATALOG" || die "falha ao consultar o catalogo"

python3 - "$CONFIG" "$CATALOG" "$ONLY" "$APPLY" "$PRUNE" "$REFRESH" "$BACKUP_DIR" <<'PY'
import json, os, shutil, sys, time

config_path, catalog_path, only, apply_s, prune_s, refresh_s, backup_dir = sys.argv[1:8]
apply = apply_s == "true"
prune = prune_s == "true"
refresh = refresh_s == "true"
prefixes = tuple(p for p in only.split(",") if p) if only else ()

cfg = json.load(open(config_path))
prov = cfg.get("providers", {}).get("9router")
if prov is None:
    raise SystemExit("[catalog] ERRO: providers.9router nao existe em " + config_path)
models = prov.setdefault("models", {})

cat = json.load(open(catalog_path)).get("data", [])
if not cat:
    raise SystemExit("[catalog] ERRO: catalogo vazio")

catalog_ids = [m["id"] for m in cat if m.get("id")]

def entry(m):
    caps = m.get("capabilities") or {}
    inp = ["text"] + (["image"] if caps.get("vision") else []) \
        + (["pdf"] if caps.get("pdf") else [])
    ctx = m.get("context_length") or caps.get("contextWindow") or 200000
    out = m.get("max_completion_tokens") or caps.get("maxOutput") or 64000
    return {
        "name": m["id"],
        "capabilities": {
            "tools": bool(caps.get("tools", True)),
            "input": inp,
            "output": ["text"],
        },
        "limit": {"context": int(ctx), "output": int(out)},
    }

scope = [m for m in cat if not prefixes or m["id"].startswith(prefixes)]
added, refreshed, pruned = [], [], []

for m in scope:
    mid = m["id"]
    if mid not in models:
        models[mid] = entry(m)
        added.append(mid)
    elif refresh:
        new = entry(m)
        if models[mid] != new:
            models[mid] = new
            refreshed.append(mid)

if prune:
    keep = set(catalog_ids)
    for mid in list(models):
        if mid not in keep and (not prefixes or mid.startswith(prefixes)):
            del models[mid]
            pruned.append(mid)

print(f"[catalog] catalogo: {len(cat)} modelos · config: {len(models)} · escopo: {len(scope)}")

def fam(i):
    return i.split("/")[0]

for label, ids in (("novos", added), ("atualizados", refreshed), ("removidos", pruned)):
    if not ids:
        continue
    print(f"\n[catalog] {label} ({len(ids)}):")
    for i in sorted(ids):
        print(f"  {'+' if label == 'novos' else ('~' if label == 'atualizados' else '-')} {i}")

if not (added or refreshed or pruned):
    print("\n[catalog] nada a fazer: config ja esta em sincronia.")
    raise SystemExit(0)

if not apply:
    print("\n[catalog] dry-run. Para gravar: zsh tools/sync-catalog.sh --apply")
    raise SystemExit(0)

os.makedirs(backup_dir, exist_ok=True)
stamp = time.strftime("%Y%m%d-%H%M%S")
bak = os.path.join(backup_dir, f"opencode.json.{stamp}.bak")
shutil.copy2(config_path, bak)
print(f"\n[catalog] backup: {bak}")

mode = os.stat(config_path).st_mode & 0o777
tmp = config_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, config_path)
print(f"[catalog] gravado: {config_path} (mode {oct(mode)[2:]}, {len(models)} modelos)")
PY

if [[ "$APPLY" == true ]]; then
  log "reinicie o daemon para o TUI enxergar o catalogo novo: opencode service restart"
fi
