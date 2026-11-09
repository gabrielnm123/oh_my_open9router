#!/usr/bin/env zsh
# tools/vpn-window.sh
#
# Descobre no servidor as credenciais que só existem lá e grava no `.env`
# local — em UMA execução, sem interação.
#
# POR QUE EXISTE:
#   A porta 22 do servidor costuma estar bloqueada fora da VPN, e alguns
#   clientes de VPN (ex.: ProtonVPN no Windows com WSL2 em NAT) fazem o
#   tráfego do WSL sair por um IP compartilhado cuja cota de free tier já
#   estourou. Resultado: com a VPN ligada o servidor é alcançável mas o
#   agente do OpenCode não responde; com a VPN desligada o agente responde mas
#   o SSH não passa. Este script elimina a troca de contexto: você liga a VPN,
#   roda UMA vez, e tudo o que dependia do servidor é coletado e aplicado.
#
# O QUE ELE FAZ (tudo via SSH, rotas local-only em 127.0.0.1:20128):
#   1. deriva o token CLI: sha256(machine-id + "9r-cli-auth" + cli-secret)[:16]
#   2. GET /api/keys            -> NINEROUTER_API_KEY
#   3. GET /api/tunnel/status   -> NINEROUTER_RELAY_HOST / NINEROUTER_TUNNEL_HOST
#   4. lê ~/.9router/.env       -> JWT_SECRET, INITIAL_PASSWORD
#   5. `hostname`               -> VENICE_SERVER_HOSTNAME
#   6. grava só o que está vazio/placeholder no `.env` e na cópia canônica
#   7. roda tools/sync-catalog.sh --apply (preenche providers.9router.models)
#
# O que ele NÃO faz: sonda de modelos e atribuição por papel (levam dezenas de
# minutos e não precisam de VPN — rode depois, com a rede normal).
#
# USO:
#   zsh tools/vpn-window.sh --check     # só testa o SSH
#   zsh tools/vpn-window.sh --dry-run   # mostra o que seria gravado
#   zsh tools/vpn-window.sh             # descobre + aplica + sincroniza catálogo
#   zsh tools/vpn-window.sh --force     # sobrescreve valores já preenchidos
#   zsh tools/vpn-window.sh --no-sync   # aplica sem sincronizar o catálogo

emulate -L zsh
setopt pipe_fail

VENICE_PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/venice-env.sh"

MODE=apply
FORCE=0
SYNC=1
while (( $# )); do
  case "$1" in
    --check)   MODE=check ;;
    --dry-run) MODE=dry ;;
    --force)   FORCE=1 ;;
    --no-sync) SYNC=0 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "vpn-window: opcao desconhecida: $1"; exit 2 ;;
  esac
  shift
done

if [[ -n "${NINEROUTER_SSH_HOST:-}" ]]; then
  SSH_HOST="${NINEROUTER_SSH_HOST}"
elif [[ -n "${VENICE_STACK_SSH_HOST:-}" && -n "${VENICE_STACK_SSH_USER:-}" ]]; then
  SSH_HOST="${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST}"
else
  print -u2 "vpn-window: host SSH indefinido (VENICE_STACK_SSH_HOST/USER no .env)"
  exit 1
fi

log()  { print "[vpn-window] $*" }
warn() { print -u2 "[vpn-window] AVISO: $*" }
die()  { print -u2 "[vpn-window] ERRO: $*"; exit 1 }

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" 'bash -s' }

# ---------------------------------------------------------------- check -----
if [[ "$MODE" == check ]]; then
  log "testando SSH em ${SSH_HOST} ..."
  if remote <<'REMOTE'
set -e
echo "OK $(hostname)"
REMOTE
  then
    log "SSH OK — pode rodar sem flags para descobrir as credenciais"
  else
    die "SSH inacessivel. Ligue a VPN (porta 22 costuma ser bloqueada fora dela)."
  fi
  exit 0
fi

# ------------------------------------------------------------ discovery -----
log "consultando o servidor (rotas local-only em 127.0.0.1:20128) ..."
DISCOVERY="$(remote <<'REMOTE'
set -uo pipefail
D="${HOME}/.9router"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

MID="$(cat "${D}/machine-id" 2>/dev/null || true)"
SEC="$(cat "${D}/auth/cli-secret" 2>/dev/null || true)"
if [[ -z "$MID" || -z "$SEC" ]]; then
  echo '{"error":"machine-id ou cli-secret ausente em ~/.9router"}'
  exit 0
fi
TOKEN="$(printf '%s' "${MID}9r-cli-auth${SEC}" | sha256sum | cut -c1-16)"

grep -m1 '^JWT_SECRET='       "${D}/.env" 2>/dev/null | cut -d= -f2- > "$TMP/jwt"  || : > "$TMP/jwt"
grep -m1 '^INITIAL_PASSWORD=' "${D}/.env" 2>/dev/null | cut -d= -f2- > "$TMP/pw"   || : > "$TMP/pw"

api() { curl -s --max-time 25 -H "x-9r-cli-token: ${TOKEN}" "http://127.0.0.1:20128$1"; }

# /api/keys: primeiro com o token CLI (rotas local-only). Se nao passar, tenta
# o login com INITIAL_PASSWORD e repete com o cookie auth_token.
KEYS_CODE="$(curl -s --max-time 25 -o "$TMP/keys" -w '%{http_code}' \
  -H "x-9r-cli-token: ${TOKEN}" http://127.0.0.1:20128/api/keys 2>/dev/null || echo 000)"
LOGIN_CODE=""
if [[ "$KEYS_CODE" != "200" ]]; then
  PW="$(sed -E "s/^['\"]//; s/['\"]$//" "$TMP/pw" 2>/dev/null)"
  if [[ -n "$PW" ]]; then
    python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$PW" > "$TMP/login.json" 2>/dev/null
    LOGIN_CODE="$(curl -s --max-time 25 -o /dev/null -w '%{http_code}' \
      -X POST http://127.0.0.1:20128/api/auth/login \
      -H 'Content-Type: application/json' --data-binary @"$TMP/login.json" \
      -c "$TMP/cookies" 2>/dev/null || echo 000)"
    if [[ "$LOGIN_CODE" == "200" ]]; then
      KEYS_CODE="$(curl -s --max-time 25 -o "$TMP/keys" -w '%{http_code}' \
        -b "$TMP/cookies" http://127.0.0.1:20128/api/keys 2>/dev/null || echo 000)"
    fi
  fi
fi
[[ "$KEYS_CODE" == "200" ]] || : > "$TMP/keys"

api /api/tunnel/status   > "$TMP/tunnel" 2>/dev/null || : > "$TMP/tunnel"
api /api/health          > "$TMP/health" 2>/dev/null || : > "$TMP/health"
hostname                 > "$TMP/hostname" 2>/dev/null || : > "$TMP/hostname"
printf '%s' "$KEYS_CODE"  > "$TMP/keys_code"
printf '%s' "$LOGIN_CODE" > "$TMP/login_code"

python3 - "$TMP" <<'PY'
import json, sys, os
d = sys.argv[1]
def read(n):
    try:
        return open(os.path.join(d, n)).read().strip()
    except Exception:
        return ""
def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        s = s[1:-1]
    return s
def as_json(n):
    raw = read(n)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return {"_raw": raw[:500]}
print(json.dumps({
    "hostname": read("hostname"),
    "jwt_secret": strip_quotes(read("jwt")),
    "initial_password": strip_quotes(read("pw")),
    "keys_code": read("keys_code"),
    "login_code": read("login_code"),
    "keys": as_json("keys"),
    "tunnel": as_json("tunnel"),
    "health": as_json("health"),
}))
PY
REMOTE
)"

[[ -n "$DISCOVERY" ]] || die "resposta vazia do servidor"

print -r -- "$DISCOVERY" > "${TMPDIR:-/tmp}/vpn-window-discovery.json"
log "resposta bruta salva em ${TMPDIR:-/tmp}/vpn-window-discovery.json"

# ------------------------------------------------------------- extraction ---
# Extrai os valores e reescreve o .env. Tudo em python3 para não depender de jq.
APPLY_OUT="$(python3 - "$VENICE_ENV_FILE" "$HOME/.config/venice-stack/9router.env" \
                          "${TMPDIR:-/tmp}/vpn-window-discovery.json" "$FORCE" "$MODE" <<'PY'
import json, os, re, sys

env_path, canonical_path, disc_path, force_s, mode = sys.argv[1:6]
force = force_s == "1"
dry = mode == "dry"
d = json.load(open(disc_path))

if d.get("error"):
    print("ERROR " + d["error"]); sys.exit(0)

def pick_key(obj):
    """Aceita {"keys":[...]}, [...] ou {"_raw": ...} e devolve a 1a chave."""
    if obj is None:
        return ""
    if isinstance(obj, dict) and "_raw" in obj:
        return ""
    items = obj
    if isinstance(obj, dict):
        for k in ("keys", "data", "items", "apiKeys"):
            if isinstance(obj.get(k), list):
                items = obj[k]; break
        else:
            items = [obj]
    if not isinstance(items, list) or not items:
        return ""
    first = items[0]
    if isinstance(first, str):
        return first.strip()
    for f in ("key", "apiKey", "value", "token", "secret"):
        v = first.get(f)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""

api_key = pick_key(d.get("keys"))
tun = d.get("tunnel") or {}
t = tun.get("tunnel") if isinstance(tun.get("tunnel"), dict) else tun
public_url = (t.get("publicUrl") or t.get("public_url") or "") if isinstance(t, dict) else ""
tunnel_url = (t.get("tunnelUrl") or t.get("tunnel_url") or "") if isinstance(t, dict) else ""

def host_only(u):
    u = (u or "").strip()
    u = re.sub(r"^https?://", "", u)
    return u.split("/")[0]

relay = host_only(public_url)
tunnel_host = host_only(tunnel_url)
jwt = (d.get("jwt_secret") or "").strip()
pw = (d.get("initial_password") or "").strip()
hostname = (d.get("hostname") or "").strip()

PLACEHOLDER = re.compile(r"^(|troque-.*|exemplo-.*|servidor-.*|sk-xxxx.*|0123456789abcdef.*)$")

wanted = {
    "NINEROUTER_API_KEY": api_key,
    "NINEROUTER_JWT_SECRET": jwt,
    "NINEROUTER_ADMIN_PASSWORD": pw,
    "NINEROUTER_RELAY_HOST": relay,
    "NINEROUTER_TUNNEL_HOST": tunnel_host,
    "VENICE_SERVER_HOSTNAME": hostname,
}
if relay:
    wanted["NINEROUTER_BASE_URL"] = f"https://{relay}/v1"

try:
    text = open(env_path).read()
except FileNotFoundError:
    print("ERROR .env nao encontrado"); sys.exit(0)

changed, skipped, missing = [], [], []
for key, value in wanted.items():
    if not value:
        missing.append(key)
        continue
    m = re.search(rf"^{key}='(.*)'[ \t]*$", text, re.M)
    if not m:
        text += f"\n{key}='{value}'\n"
        changed.append(key); continue
    current = m.group(1)
    if not force and not PLACEHOLDER.match(current):
        if current != value:
            skipped.append(f"{key} (ja preenchido: {current} != {value})")
        continue
    if current == value:
        continue
    text = re.sub(rf"^{key}='.*'[ \t]*$", f"{key}='{value}'", text, flags=re.M)
    changed.append(key)

if changed and not dry:
    open(env_path, "w").write(text)
    os.chmod(env_path, 0o600)
    if canonical_path:
        os.makedirs(os.path.dirname(canonical_path), mode=0o700, exist_ok=True)
        open(canonical_path, "w").write(text)
        os.chmod(canonical_path, 0o600)

print("CHANGED " + (",".join(changed) if changed else "-"))
for s in skipped:
    print("SKIP " + s)
for s in missing:
    print("MISSING " + s)
if not api_key:
    print("NOAPIKEY")
PY
)"

print -r -- "$APPLY_OUT"

if [[ "$APPLY_OUT" == ERROR* ]]; then
  die "${APPLY_OUT#ERROR }"
fi

if (( FORCE == 0 )) && [[ "$APPLY_OUT" == *NOAPIKEY* ]]; then
  warn "nenhuma API key em /api/keys — crie uma no dashboard e rode de novo"
fi

if [[ "$MODE" == dry ]]; then
  log "--dry-run: nada gravado"
  exit 0
fi

# --------------------------------------------------------------- catalog ----
if (( SYNC )); then
  if [[ "$APPLY_OUT" == *NINEROUTER_API_KEY* ]] || grep -q '^NINEROUTER_API_KEY=.' "$VENICE_ENV_FILE"; then
    log "sincronizando o catalogo de modelos no opencode.json ..."
    VENICE_ENV_FILE="$VENICE_ENV_FILE" zsh "${VENICE_PROJECT_ROOT}/tools/sync-catalog.sh" --apply \
      || warn "sync-catalog falhou (rode de novo com a rede normal: zsh tools/sync-catalog.sh --apply)"
  else
    warn "sem API key: pulando sync-catalog"
  fi
fi

log "pronto. Agora DESLIGUE a VPN e rode a sonda:"
log "  zsh tools/probe-models.sh"
log "  zsh tools/select-models.sh --apply    # ou /auto_select_models_oh_my_opencode_slim no TUI"
