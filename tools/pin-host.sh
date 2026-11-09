#!/usr/bin/env zsh
# tools/pin-host.sh
#
# Fixa o IP real do relay do 9router no /etc/hosts, contornando resolvers que
# FILTRAM o dominio (ex.: FortiGuard devolve uma "blocked page" no lugar do IP
# do Cloudflare). Sem isso, o tunel so responde quando outra rede/VPN resolve
# o nome corretamente.
#
# POR QUE /etc/hosts E NAO DNS:
#   trocar o resolver da maquina inteira quebraria nomes internos do dominio
#   corporativo (`search seas.local`). O bloco marcado afeta SO os hosts do
#   tunel, e e reversivel com --undo.
#
# O IP e obtido por DNS-over-HTTPS (Cloudflare), que nao passa pelo resolver
# local. Como o Cloudflare pode trocar o IP, `--refresh` re-resolve e reescreve.
#
# USO:
#   zsh tools/pin-host.sh --status      # mostra o bloco atual
#   zsh tools/pin-host.sh --dry-run     # mostra o que seria escrito
#   zsh tools/pin-host.sh               # aplica (pede sudo)
#   zsh tools/pin-host.sh --refresh     # re-resolve e reescreve (pede sudo)
#   zsh tools/pin-host.sh --undo        # remove o bloco (pede sudo)
#
# WSL: /etc/hosts e REGENERADO a cada boot. O script detecta isso e instrui a
# desligar a geracao (`generateHosts = false` em /etc/wsl.conf); sem isso o
# pin some no proximo `wsl --shutdown`.

emulate -L zsh
setopt pipe_fail

VENICE_PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/venice-env.sh"

HOSTS_FILE="${PIN_HOSTS_FILE:-/etc/hosts}"
MARK_BEGIN="# >>> 9router-tunnel >>>"
MARK_END="# <<< 9router-tunnel <<<"

MODE=apply
EXTRA_HOSTS=()
while (( $# )); do
  case "$1" in
    --status)  MODE=status ;;
    --dry-run) MODE=dry ;;
    --undo)    MODE=undo ;;
    --refresh) MODE=apply ;;
    --host)    shift; EXTRA_HOSTS+=("${1:-}") ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "pin-host: opcao desconhecida: $1"; exit 2 ;;
  esac
  shift
done

typeset -a HOSTS
RELAY="${NINEROUTER_RELAY_HOST:-}"
RELAY="${RELAY#https://}"; RELAY="${RELAY#http://}"; RELAY="${RELAY%%/*}"
[[ -n "$RELAY" ]] && HOSTS+=("$RELAY")
HOSTS+=("${EXTRA_HOSTS[@]}")

(( ${#HOSTS} )) || { print -u2 "pin-host: NINEROUTER_RELAY_HOST nao definido"; exit 1 }

# IP real via DoH. Ignora o resolver local de proposito.
doh_ips() {
  local host="$1" out
  out="$(curl -sS -m 10 -H 'accept: application/dns-json' \
    "https://1.1.1.1/dns-query?name=${host}&type=A" 2>/dev/null)" || return 1
  python3 - "$out" <<'PY'
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: sys.exit(1)
ips=[a["data"] for a in d.get("Answer",[]) if a.get("type")==1 and a.get("data")]
print("\n".join(dict.fromkeys(ips)))
sys.exit(0 if ips else 1)
PY
}

block_for_host() {
  local host="$1" ips
  ips="$(doh_ips "$host")" || { print -u2 "pin-host: DoH nao resolveu $host"; return 1; }
  print "$MARK_BEGIN"
  for ip in ${(f)ips}; do
    print "${ip}	${host}"
  done
  print "$MARK_END"
}

# Reescreve o arquivo removendo o bloco antigo e (opcionalmente) inserindo um novo.
rewrite_hosts() {
  local new_block="$1" target="$2"
  python3 - "$target" "$MARK_BEGIN" "$MARK_END" "$new_block" <<'PY'
import sys
path, begin, end, block = sys.argv[1:5]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
lines = text.splitlines(keepends=True)
out, skip = [], False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if line.strip() == end:
        skip = False
        continue
    if not skip:
        out.append(line)
if out and not out[-1].endswith("\n"):
    out[-1] += "\n"
if block:
    if out and out[-1].strip():
        out.append("\n")
    out.append(block + "\n")
open(path, "w").write("".join(out))
PY
}

is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

wsl_warning() {
  is_wsl || return 0
  local conf=/etc/wsl.conf
  if [[ -r "$conf" ]] && grep -qE '^[[:space:]]*generateHosts[[:space:]]*=[[:space:]]*false' "$conf"; then
    return 0
  fi
  cat <<EOF

AVISO (WSL): /etc/hosts e regenerado a cada boot do WSL, entao este pin
desaparece no proximo \`wsl --shutdown\`. Para tornar permanente:

  sudo tee -a /etc/wsl.conf >/dev/null <<'CONF'
[network]
generateHosts = false
CONF

Depois \`wsl --shutdown\` no Windows (o /etc/hosts atual e preservado) e rode
este script de novo.
EOF
}

case "$MODE" in
  status)
    if grep -qF "$MARK_BEGIN" "$HOSTS_FILE" 2>/dev/null; then
      sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$HOSTS_FILE"
    else
      print "sem bloco 9router-tunnel em $HOSTS_FILE"
    fi
    print ""
    for h in "${HOSTS[@]}"; do
      print "local : $(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
      print "real  : $(doh_ips "$h" 2>/dev/null | tr '\n' ' ')"
    done
    ;;

  undo)
    print "pin-host: removendo bloco de $HOSTS_FILE"
    sudo python3 - "$HOSTS_FILE" "$MARK_BEGIN" "$MARK_END" <<'PY'
import sys
path, begin, end = sys.argv[1:4]
text = open(path).read()
out, skip = [], False
for line in text.splitlines(keepends=True):
    if line.strip() == begin: skip = True; continue
    if line.strip() == end:   skip = False; continue
    if not skip: out.append(line)
open(path, "w").write("".join(out))
PY
    print "pin-host: removido"
    ;;

  dry|apply)
    typeset -a blocks
    for h in "${HOSTS[@]}"; do
      b="$(block_for_host "$h")" || exit 1
      blocks+=("$b")
    done
    new_block="${(j:\n:)blocks}"

    if [[ "$MODE" == dry ]]; then
      print "pin-host: escreveria em $HOSTS_FILE:"
      print ""
      print "$new_block"
      exit 0
    fi

    TMP="$(mktemp)"
    cp "$HOSTS_FILE" "$TMP" 2>/dev/null || : > "$TMP"
    rewrite_hosts "$new_block" "$TMP"
    sudo install -m 644 -o root -g root "$TMP" "$HOSTS_FILE" || {
      print -u2 "pin-host: falha ao escrever $HOSTS_FILE (sudo negado?)"
      rm -f "$TMP"; exit 1
    }
    rm -f "$TMP"
    print "pin-host: bloco aplicado em $HOSTS_FILE"
    getent ahostsv4 "$RELAY" 2>/dev/null | awk '{print "  local agora: "$1}' | sort -u
    wsl_warning
    ;;
esac
