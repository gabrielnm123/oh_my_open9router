#!/usr/bin/env zsh
# tools/net-diag.sh
#
# Diagnostico de conectividade do tunel do 9router e do endpoint do OpenCode.
#
# POR QUE EXISTE:
#   A maquina do operador pode estar atras de um resolver que FILTRA dominios
#   (ex.: FortiGuard devolve uma "blocked page" para o relay) e/ou de uma VPN
#   corporativa que bloqueia o endpoint do OpenCode (`opencode.ai`). Nos dois
#   casos o sintoma visivel e "o provider nao responde", sem pista da causa.
#   Este script separa DNS, TCP, TLS e HTTP para cada host, e compara a
#   resolucao local com a resolucao real obtida por DoH.
#
# E SOMENTE LEITURA: nao escreve em /etc/hosts, nao reinicia servico, nao
# altera o `.env`.
#
# USO:
#   zsh tools/net-diag.sh              # diagnostico completo
#   zsh tools/net-diag.sh --short      # so o veredito
#   zsh tools/net-diag.sh --host X     # um host extra
#
# VARIAVEIS: lidas do `.env` (ou do ambiente / copia canonica) por
# tools/lib/venice-env.sh — nada de host hardcoded aqui.

emulate -L zsh
setopt pipe_fail

VENICE_PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/venice-env.sh"

SHORT=0
EXTRA_HOSTS=()
while (( $# )); do
  case "$1" in
    --short) SHORT=1 ;;
    --host)  shift; EXTRA_HOSTS+=("${1:-}") ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) print -u2 "net-diag: opcao desconhecida: $1"; exit 2 ;;
  esac
  shift
done

typeset -a HOSTS
[[ -n "${NINEROUTER_RELAY_HOST:-}" ]] && HOSTS+=("${NINEROUTER_RELAY_HOST#https://}")
HOSTS+=("opencode.ai")
HOSTS+=("${EXTRA_HOSTS[@]}")

# Resolve o IP real do host por DNS-over-HTTPS. Serve para provar que o
# resolver local esta mentindo (filtro) em vez de o host nao existir.
doh_a() {
  local host="$1" out
  out="$(curl -sS -m 8 -H 'accept: application/dns-json' \
    "https://1.1.1.1/dns-query?name=${host}&type=A" 2>/dev/null)" || return 1
  python3 - "$out" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
ans=[a.get("data") for a in d.get("Answer",[]) if a.get("type")==1]
print(" ".join(a for a in ans if a))
sys.exit(0 if ans else 1)
PY
}

# Certificado apresentado pelo peer. `-verify_hostname` valida CN/SAN contra o
# nome pedido: se falhar, alguem no caminho esta interceptando (proxy/filtro
# TLS). Comparar o CN "a mao" da falso positivo em certificado wildcard
# (CN=abc-tunnel.us cobre *.abc-tunnel.us).
tls_subject() {
  local host="$1" out
  out="$(openssl s_client -connect "${host}:443" -servername "$host" \
    -verify_hostname "$host" </dev/null 2>&1)"
  print -r -- "$out" | openssl x509 -noout -subject 2>/dev/null \
    | sed -E 's/^subject= *//'
  if print -r -- "$out" | grep -q 'Verification: OK'; then
    print "VERIFY_OK"
  else
    print "VERIFY_FAIL"
  fi
}

# Uma linha por camada: DNS, TCP, TLS, HTTP.
probe_host() {
  local host="$1"
  local dns_ips doh_ips tcp tls http verdict

  dns_ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  dns_ips="${dns_ips% }"
  doh_ips="$(doh_a "$host" 2>/dev/null)" || doh_ips=""

  if [[ -z "$dns_ips" ]]; then
    tcp="no-dns"
  elif nc -z -w 4 "$host" 443 >/dev/null 2>&1; then
    tcp="open"
  else
    tcp="blocked"
  fi

  tls_raw="$(tls_subject "$host")"
  tls="$(print -r -- "$tls_raw" | sed -n '1p')"
  if print -r -- "$tls_raw" | grep -q 'VERIFY_OK'; then tls_ok=1; else tls_ok=0; fi
  http="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://${host}/v1/models" 2>/dev/null)" || http="000"

  # Veredito por host.
  if [[ -z "$dns_ips" ]]; then
    verdict="DNS_VAZIO"
  elif [[ -n "$doh_ips" && -n "$dns_ips" ]] && \
       ! python3 - "$dns_ips" "$doh_ips" <<'PY'
import sys
local=set(sys.argv[1].split()); real=set(sys.argv[2].split())
sys.exit(0 if local & real else 1)
PY
  then
    verdict="DNS_FILTRADO (local: ${dns_ips} / real: ${doh_ips})"
  elif [[ "$tcp" != "open" ]]; then
    verdict="TCP_BLOQUEADO (443)"
  elif (( tls_ok == 0 )); then
    verdict="TLS_INTERCEPTADO (cert: ${tls:-<sem handshake>})"
  elif [[ "$host" == "${NINEROUTER_RELAY_HOST#https://}" ]]; then
    # No relay, 401 = tunel no ar exigindo API key; 200 = rota publica.
    if [[ "$http" == "200" || "$http" == "401" ]]; then
      verdict="OK (HTTP ${http})"
    else
      verdict="HTTP_${http}"
    fi
  elif [[ "$http" != "000" ]]; then
    # Qualquer outra rota do host respondeu: a rede ate ele esta boa.
    verdict="OK (HTTP ${http})"
  else
    verdict="SEM_RESPOSTA_HTTP"
  fi

  if (( SHORT )); then
    printf '%-40s %s\n' "$host" "$verdict"
  else
    print "── ${host}"
    print "   dns local : ${dns_ips:-<vazio>}"
    print "   dns real  : ${doh_ips:-<sem DoH>}"
    print "   tcp 443   : ${tcp}"
    print "   tls cert  : ${tls:-<sem handshake>}"
    print "   http      : ${http} (GET /v1/models)"
    print "   veredito  : ${verdict}"
  fi
}

# SSH do servidor: porta 22 e o que a maioria das redes corporativas bloqueia.
probe_ssh() {
  local host="${VENICE_STACK_SSH_HOST:-}" user="${VENICE_STACK_SSH_USER:-}"
  [[ -z "$host" ]] && return 0
  local port="${NINEROUTER_SSH_PORT:-22}" state
  if nc -z -w 4 "$host" "$port" >/dev/null 2>&1; then state="open"; else state="blocked"; fi
  if (( SHORT )); then
    printf '%-40s ssh/%s %s\n' "$host" "$port" "$state"
  else
    print "── ssh ${user:-?}@${host}:${port}"
    print "   tcp ${port}   : ${state}"
    print "   veredito  : $([[ "$state" == open ]] && print OK || print FIREWALL_BLOQUEADO)"
  fi
}

if (( ! SHORT )); then
  print "net-diag — $(date '+%Y-%m-%d %H:%M:%S')"
  print "resolver  : $(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')"
  print "relay     : ${NINEROUTER_RELAY_HOST:-<nao definido>}"
  print ""
fi

for h in "${HOSTS[@]}"; do
  [[ -n "$h" ]] && probe_host "$h"
done
probe_ssh

if (( ! SHORT )); then
  cat <<'HINTS'

── como ler o resultado
   DNS_FILTRADO      o resolver local devolve um IP de block page. Solucao:
                     fixar o IP real em /etc/hosts (bloco "9router") ou
                     usar um resolver sem filtro.
   TCP_BLOQUEADO     firewall/VPN barra a porta 443. Sem hosts fixo resolve.
   TLS_INTERCEPTADO  proxy inspecionando TLS; o provider nao valida esse cert.
   HTTP_401          tunel no ar e exigindo API key (esperado).
   HTTP_200          tunel no ar, rota publica (sem REQUIRE_API_KEY).
   FIREWALL_BLOQUEADO no SSH: o servidor so e alcancavel por VPN/allowlist.
HINTS
fi
