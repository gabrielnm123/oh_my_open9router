#!/usr/bin/env zsh
# tools/lib/venice-env.sh
#
# Carrega as variaveis de ambiente do projeto a partir do `.env` da raiz.
#
# POR QUE EXISTE:
#   O repositorio vai para um remoto PUBLICO. Nenhuma credencial, host ou URL
#   real pode ficar hardcoded nos scripts. O `.env` da raiz do projeto e a
#   fonte da verdade: ele e gitignored, tem permissao 600 e pode ser copiado
#   para outra maquina junto com o `.env.example` (que so tem placeholders).
#
# ORDEM DE RESOLUCAO DAS CREDENCIAIS:
#   1. variavel ja exportada no ambiente (ex.: vinda do `~/.zshenv`);
#   2. `.env` da raiz do projeto (carregado aqui);
#   3. copia canonica em `~/.config/venice-stack/9router.env` (so preenche
#      o que ainda estiver vazio — nunca sobrescreve o `.env` do projeto).
#
# O passo 3 e o que permite instalar os scripts FORA do repositorio (por
# exemplo, o comando global `/refresh_models_9router` do OpenCode, gerado por
# `tools/install-command.sh`): o script roda de qualquer diretorio e ainda
# encontra URL e chave.
#
# Nada aqui tem valor padrao "de verdade": quem chama decide o que fazer se
# faltar algo.
#
# USO (em qualquer script zsh deste repo):
#   VENICE_PROJECT_ROOT="${0:A:h:h}"
#   source "${0:A:h}/lib/venice-env.sh"
#
# Este arquivo nao define funcao de negocio: apenas popula o ambiente.

# Raiz do projeto. O chamador normalmente ja define; o fallback usa o proprio
# caminho do lib (tools/lib/venice-env.sh -> tools -> raiz do projeto).
: "${VENICE_PROJECT_ROOT:=${0:A:h:h:h}}"

# Arquivo de credenciais da raiz. Nao versionado (ver .gitignore).
# Pode ser apontado explicitamente por `VENICE_ENV_FILE` (util quando o script
# roda fora do repositorio e o operador quer usar um arquivo especifico).
: "${VENICE_ENV_FILE:=${VENICE_PROJECT_ROOT}/.env}"

# Remove as aspas simples de um valor lido de um arquivo `KEY='valor'`.
# Usado quando o valor vem de `grep`/`cut` (que nao remove as aspas).
strip_quotes() {
  local value="${1:-}"
  value="${value%$'\n'}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

# Se o `.env` existir e for legivel, carrega com todas as variaveis exportadas.
# `set -a` (allexport) faz o `source` exportar o que foi definido no arquivo.
if [[ -r "${VENICE_ENV_FILE}" ]]; then
  set -a
  source "${VENICE_ENV_FILE}"
  set +a
fi

# Fallback: copia canonica de segredos, fora do repositorio. So preenche
# variaveis que ainda estao vazias — o `.env` do projeto e o ambiente sempre
# ganham. Valores de uma linha so (`KEY='valor'`), que e o formato usado pelo
# `.env.example`.
: "${VENICE_CANONICAL_ENV:=${XDG_CONFIG_HOME:-${HOME}/.config}/venice-stack/9router.env}"

if [[ -r "${VENICE_CANONICAL_ENV}" ]]; then
  while IFS= read -r _venice_line; do
    [[ "${_venice_line}" =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' ]] || continue
    _venice_key="${match[1]}"
    _venice_value="${match[2]%$'\r'}"
    # `(P)` expande pelo nome do que esta em `$_venice_key`; o `-` no fim evita
    # erro de "parameter not set" quando o script roda sob `set -u`.
    [[ -n "${(P)_venice_key-}" ]] && continue
    export "${_venice_key}=$(strip_quotes "${_venice_value}")"
  done < "${VENICE_CANONICAL_ENV}"
  unset _venice_line _venice_key _venice_value
fi
