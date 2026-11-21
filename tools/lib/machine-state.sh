#!/usr/bin/env zsh
# tools/lib/machine-state.sh
#
# Gerencia o estado local de aplicação por máquina.
# Registra qual commit do repo foi instalado (via install-command.sh),
# quando (timestamp LOCAL da máquina), e em qual hostname.
#
# Arquivos locais (gitignored, individuais por máquina):
#   ~/.local/share/9router-tools/machine-state.json  — estado estruturado (600)
#   <repo>/HISTORY.md                                — diário legível por humanos
#   <repo>/PLAN.md                                   — plano/notas locais (não versionado)
#
# Uso:
#   zsh tools/lib/machine-state.sh record  [--repo <dir>] [--note "texto"]
#   zsh tools/lib/machine-state.sh check   [--repo <dir>]   # exit 1 se desatualizado
#   zsh tools/lib/machine-state.sh show    [--repo <dir>]
#   zsh tools/lib/machine-state.sh history [--repo <dir>]   # exibe HISTORY.md

set -euo pipefail

STATE_FILE="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/machine-state.json"

# ------------------------------------------------------------------ helpers --

_ms_repo_root() {
  local repo="${1:-}"
  if [[ -n "$repo" ]]; then echo "$repo"; return; fi
  local self="${0:A:h:h:h}"
  if git -C "$self" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git -C "$self" rev-parse --show-toplevel 2>/dev/null
  else
    echo ""
  fi
}

_ms_commit() {
  local repo="$1"
  [[ -n "$repo" ]] || { echo ""; return; }
  git -C "$repo" rev-parse HEAD 2>/dev/null || echo ""
}

_ms_commit_subject() {
  local repo="$1" commit="$2"
  [[ -n "$repo" && -n "$commit" ]] || { echo ""; return; }
  git -C "$repo" log -1 --format="%s" "$commit" 2>/dev/null || echo ""
}

_ms_remote_commit() {
  local repo="$1"
  [[ -n "$repo" ]] || { echo ""; return; }
  git -C "$repo" fetch origin --quiet 2>/dev/null || true
  git -C "$repo" rev-parse origin/main 2>/dev/null \
    || git -C "$repo" rev-parse origin/master 2>/dev/null \
    || echo ""
}

_ms_hostname() {
  hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"
}

_ms_now_local() {
  # Timestamp local da máquina com timezone
  date '+%Y-%m-%d %H:%M:%S %Z'
}

_ms_read() {
  python3 -c "
import json
try:
    d = json.load(open('${STATE_FILE}'))
except Exception:
    d = {}
print(json.dumps(d))
" 2>/dev/null || echo "{}"
}

_ms_write() {
  local data="$1"
  mkdir -p "${STATE_FILE:h}"
  local tmp="${STATE_FILE}.tmp"
  printf '%s\n' "$data" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "${STATE_FILE}"
}

_ms_append_history() {
  local repo="$1" commit="$2" subject="$3" note="$4" ts_local="$5" host="$6"
  [[ -n "$repo" ]] || return 0
  local history_file="${repo}/HISTORY.md"

  # Cria o arquivo se não existir
  if [[ ! -f "$history_file" ]]; then
    cat > "$history_file" <<HEADER
# HISTORY.md — Diário local de aplicações

> Arquivo local desta máquina (**${host}**). Não versionado.
> Gerado por \`tools/lib/machine-state.sh\`.

---

HEADER
  fi

  # Prepend: nova entrada vai no topo (após o cabeçalho fixo)
  local tmp; tmp="$(mktemp)"
  python3 - "$history_file" "$tmp" <<PYEOF
import sys, re

src  = open(sys.argv[1]).read()
dst  = sys.argv[2]
host = '${host}'
ts   = '${ts_local}'
sha  = '${commit}'[:8]
subj = '${subject}'
note = '${note}'

entry = f"""## {ts}  —  {host}

- **commit:** \`{sha}\` {subj}
"""
if note:
    entry += f"- **nota:** {note}\n"
entry += "\n---\n\n"

# Insere depois do primeiro bloco '---\n\n' (fim do cabeçalho)
parts = src.split('---\n\n', 1)
if len(parts) == 2:
    new = parts[0] + '---\n\n' + entry + parts[1]
else:
    new = src + entry

open(dst, 'w').write(new)
PYEOF
  mv "$tmp" "$history_file"
}

# ------------------------------------------------------------------ funções --

ms_record() {
  local repo note ts_local host commit subject
  repo="$(_ms_repo_root "${_REPO:-}")"
  note="${_NOTE:-}"
  ts_local="$(_ms_now_local)"
  host="$(_ms_hostname)"
  commit="$(_ms_commit "$repo")"
  subject="$(_ms_commit_subject "$repo" "$commit")"

  local existing; existing="$(_ms_read)"

  local new_state; new_state="$(python3 -c "
import json, sys

existing = json.loads('''${existing}''')
host     = '${host}'
commit   = '${commit}'
ts_local = '${ts_local}'
subject  = '${subject}'
note     = '${note}'
repo     = '${repo}'

history = existing.get('history', [])
history.insert(0, {
    'commit':      commit,
    'subject':     subject,
    'applied_at':  ts_local,
    'hostname':    host,
    'note':        note,
    'repo':        repo,
})
history = history[:50]

state = {
    'hostname':    host,
    'repo':        repo,
    'last_commit': commit,
    'subject':     subject,
    'applied_at':  ts_local,
    'note':        note,
    'history':     history,
}
print(json.dumps(state, indent=2, ensure_ascii=False))
")"

  _ms_write "$new_state"
  _ms_append_history "$repo" "$commit" "$subject" "$note" "$ts_local" "$host"
  echo "[machine-state] registrado: commit=${commit:0:8} host=${host} em ${ts_local}"
  [[ -n "$note" ]] && echo "[machine-state] nota: ${note}" || true
}

ms_check() {
  local repo; repo="$(_ms_repo_root "${_REPO:-}")"
  [[ -n "$repo" ]] || { echo "[machine-state] repo nao encontrado; check ignorado"; return 0; }

  local state; state="$(_ms_read)"
  local last_applied; last_applied="$(python3 -c "
import json
d = json.loads('''${state}''')
print(d.get('last_commit', ''))
" 2>/dev/null)"

  local remote; remote="$(_ms_remote_commit "$repo")"
  local current; current="$(_ms_commit "$repo")"

  if [[ -z "$last_applied" ]]; then
    print -u2 "[machine-state] ⚠️  nenhuma aplicação registrada — rode: zsh tools/install-command.sh"
    return 1
  fi

  if [[ -n "$remote" && "$remote" != "$current" ]]; then
    local behind; behind="$(git -C "$repo" rev-list --count "${current}..${remote}" 2>/dev/null || echo "?")"
    print -u2 "[machine-state] ⚠️  ${behind} commit(s) novos no origin não puxados — rode: git pull && zsh tools/install-command.sh"
    return 1
  fi

  if [[ "$last_applied" != "$current" ]]; then
    local behind; behind="$(git -C "$repo" rev-list --count "${last_applied}..${current}" 2>/dev/null || echo "?")"
    local since; since="$(python3 -c "import json; d=json.loads('''${state}'''); print(d.get('applied_at','?'))" 2>/dev/null)"
    print -u2 "[machine-state] ⚠️  ${behind} commit(s) não aplicados desde ${since} — rode: zsh tools/install-command.sh"
    return 1
  fi

  return 0
}

ms_show() {
  local repo; repo="$(_ms_repo_root "${_REPO:-}")"
  local state; state="$(_ms_read)"
  local current; current="$(_ms_commit "$repo")"
  local remote; remote="$(_ms_remote_commit "$repo")"

  python3 - "$current" "$remote" <<PYEOF
import json, sys

state   = json.loads('''${state}''')
current = sys.argv[1]
remote  = sys.argv[2]

host       = state.get('hostname', '?')
last       = state.get('last_commit', '')
applied_at = state.get('applied_at', '?')
subject    = state.get('subject', '')
note       = state.get('note', '')

print()
print('── ESTADO DESTA MÁQUINA (' + host + ') ' + '─' * 38)
print(f'  Último commit aplicado : {last[:8] if last else "nunca"}  {subject}')
print(f'  Aplicado em            : {applied_at}')
if note:
    print(f'  Nota                   : {note}')
print(f'  Commit atual do repo   : {current[:8] if current else "?"}')
print(f'  Commit no origin       : {remote[:8] if remote else "?"}')

if not last:
    print('\n  ❌ Nenhuma aplicação registrada — rode: zsh tools/install-command.sh')
elif last == current:
    if remote and remote != current:
        print('\n  ⚠️  Commits novos no origin — rode: git pull && zsh tools/install-command.sh')
    else:
        print('\n  ✅ Máquina atualizada')
else:
    print('\n  ⚠️  Commits não aplicados — rode: zsh tools/install-command.sh')

history = state.get('history', [])
if len(history) > 1:
    print()
    print('  Últimas aplicações:')
    for h in history[:5]:
        sha  = h.get('commit', '?')[:8]
        ts   = h.get('applied_at', '?')
        subj = h.get('subject', '')
        hn   = h.get('hostname', '?')
        print(f'    {ts}  {sha}  {hn}  {subj}')

print('─' * 60)
print()
PYEOF
}

ms_history() {
  local repo; repo="$(_ms_repo_root "${_REPO:-}")"
  local f="${repo}/HISTORY.md"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "Nenhum HISTORY.md encontrado em ${repo}"
  fi
}

# ------------------------------------------------------------------ main ----

ACTION="${1:-show}"
shift 2>/dev/null || true

_REPO=""
_NOTE=""
while (( $# > 0 )); do
  case "$1" in
    --repo)  _REPO="$2";  shift 2 ;;
    --note)  _NOTE="$2";  shift 2 ;;
    *) shift ;;
  esac
done

case "$ACTION" in
  record)  ms_record  ;;
  check)   ms_check   ;;
  show)    ms_show    ;;
  history) ms_history ;;
  *) echo "uso: $0 record|check|show|history [--repo <dir>] [--note <texto>]" >&2; exit 1 ;;
esac

set -euo pipefail

STATE_FILE="${XDG_DATA_HOME:-${HOME}/.local/share}/9router-tools/machine-state.json"

# ------------------------------------------------------------------ helpers --

_ms_repo_root() {
  local repo="${1:-}"
  if [[ -n "$repo" ]]; then
    echo "$repo"; return
  fi
  # tenta descobrir a partir deste script
  local self="${0:A:h:h:h}"   # tools/lib/.. -> repo root
  if git -C "$self" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git -C "$self" rev-parse --show-toplevel 2>/dev/null
  else
    echo ""
  fi
}

_ms_commit() {
  local repo="$1"
  [[ -n "$repo" ]] || { echo ""; return; }
  git -C "$repo" rev-parse HEAD 2>/dev/null || echo ""
}

_ms_commit_date() {
  local repo="$1" commit="$2"
  [[ -n "$repo" && -n "$commit" ]] || { echo ""; return; }
  git -C "$repo" log -1 --format="%ci" "$commit" 2>/dev/null || echo ""
}

_ms_remote_commit() {
  local repo="$1"
  [[ -n "$repo" ]] || { echo ""; return; }
  git -C "$repo" fetch origin --quiet 2>/dev/null || true
  git -C "$repo" rev-parse origin/main 2>/dev/null \
    || git -C "$repo" rev-parse origin/master 2>/dev/null \
    || echo ""
}

_ms_hostname() {
  hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"
}

_ms_read() {
  python3 -c "
import json, sys
try:
    d = json.load(open('${STATE_FILE}'))
except Exception:
    d = {}
print(json.dumps(d))
" 2>/dev/null || echo "{}"
}

_ms_write() {
  local data="$1"
  mkdir -p "${STATE_FILE:h}"
  local tmp="${STATE_FILE}.tmp"
  printf '%s\n' "$data" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "${STATE_FILE}"
}

# ------------------------------------------------------------------ funções --

ms_record() {
  local repo="$(_ms_repo_root "${1:-}")"
  local commit="$(_ms_commit "$repo")"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local host="$(_ms_hostname)"
  local commit_date="$(_ms_commit_date "$repo" "$commit")"

  local existing; existing="$(_ms_read)"

  local new_state; new_state="$(python3 -c "
import json, sys

existing = json.loads('''${existing}''')
host     = '${host}'
commit   = '${commit}'
now      = '${now}'
cdate    = '${commit_date}'
repo     = '${repo}'

# histórico: mantém últimas 20 aplicações
history = existing.get('history', [])
history.insert(0, {
    'commit':      commit,
    'commit_date': cdate,
    'applied_at':  now,
    'hostname':    host,
    'repo':        repo,
})
history = history[:20]

state = {
    'hostname':    host,
    'repo':        repo,
    'last_commit': commit,
    'commit_date': cdate,
    'applied_at':  now,
    'history':     history,
}
print(json.dumps(state, indent=2, ensure_ascii=False))
")"

  _ms_write "$new_state"
  echo "[machine-state] registrado: commit=${commit:0:8} host=${host} em ${now}"
}

ms_check() {
  local repo="$(_ms_repo_root "${1:-}")"
  [[ -n "$repo" ]] || { echo "[machine-state] repo nao encontrado; check ignorado"; return 0; }

  local state; state="$(_ms_read)"
  local last_applied; last_applied="$(python3 -c "
import json, sys
d = json.loads('''${state}''')
print(d.get('last_commit', ''))
" 2>/dev/null)"

  local remote; remote="$(_ms_remote_commit "$repo")"
  local current; current="$(_ms_commit "$repo")"

  if [[ -z "$last_applied" ]]; then
    echo "[machine-state] ⚠️  nenhuma aplicação registrada nesta máquina"
    echo "                   rode: zsh tools/install-command.sh"
    return 1
  fi

  if [[ -n "$remote" && "$remote" != "$current" ]]; then
    local behind; behind="$(git -C "$repo" rev-list --count "${current}..${remote}" 2>/dev/null || echo "?")"
    echo "[machine-state] ⚠️  repositório desatualizado: ${behind} commit(s) novos no origin"
    echo "                   rode: git pull && zsh tools/install-command.sh"
    return 1
  fi

  if [[ "$last_applied" != "$current" ]]; then
    local since; since="$(python3 -c "
import json
d = json.loads('''${state}''')
print(d.get('applied_at', '?'))
" 2>/dev/null)"
    local behind; behind="$(git -C "$repo" rev-list --count "${last_applied}..${current}" 2>/dev/null || echo "?")"
    echo "[machine-state] ⚠️  ${behind} commit(s) desde a última aplicação (${since})"
    echo "                   rode: zsh tools/install-command.sh"
    return 1
  fi

  return 0
}

ms_show() {
  local repo="$(_ms_repo_root "${1:-}")"
  local state; state="$(_ms_read)"
  local current; current="$(_ms_commit "$repo")"
  local remote; remote="$(_ms_remote_commit "$repo")"

  python3 - "$current" "$remote" <<PYEOF
import json, sys

state   = json.loads('''${state}''')
current = sys.argv[1]
remote  = sys.argv[2]

host        = state.get('hostname', '?')
last        = state.get('last_commit', '')
applied_at  = state.get('applied_at', '?')
commit_date = state.get('commit_date', '?')

print()
print('── ESTADO DESTA MÁQUINA (' + host + ') ' + '─' * 40)
print(f'  Último commit aplicado : {last[:8] if last else "nunca"}  ({commit_date})')
print(f'  Aplicado em            : {applied_at}')
print(f'  Commit atual do repo   : {current[:8] if current else "?"}')
print(f'  Commit no origin       : {remote[:8] if remote else "?"}')

if not last:
    print()
    print('  ❌ Nenhuma aplicação registrada — rode: zsh tools/install-command.sh')
elif last == current:
    if remote and remote != current:
        print()
        print('  ⚠️  Há commits novos no origin não puxados (git pull)')
    else:
        print()
        print('  ✅ Máquina atualizada')
else:
    print()
    print('  ⚠️  Commits não aplicados — rode: zsh tools/install-command.sh')

history = state.get('history', [])
if len(history) > 1:
    print()
    print('  Histórico de aplicações:')
    for h in history[:5]:
        print(f"    {h.get('applied_at','?')}  commit={h.get('commit','?')[:8]}  host={h.get('hostname','?')}")

print('─' * 60)
print()
PYEOF
}

# ------------------------------------------------------------------ main ----

ACTION="${1:-show}"
shift 2>/dev/null || true
REPO=""
while (( $# > 0 )); do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$ACTION" in
  record) ms_record "$REPO" ;;
  check)  ms_check  "$REPO" ;;
  show)   ms_show   "$REPO" ;;
  *) echo "uso: $0 record|check|show [--repo <dir>]" >&2; exit 1 ;;
esac
