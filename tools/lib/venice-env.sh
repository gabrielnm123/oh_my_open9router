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
#   3. fallback historico em `~/.config/venice-stack/9router.env` (opcional).
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
VENICE_ENV_FILE="${VENICE_PROJECT_ROOT}/.env"

# Se o `.env` existir e for legivel, carrega com todas as variaveis exportadas.
# `set -a` (allexport) faz o `source` exportar o que foi definido no arquivo.
if [[ -r "${VENICE_ENV_FILE}" ]]; then
  set -a
  source "${VENICE_ENV_FILE}"
  set +a
fi

# Remove as aspas simples de um valor lido de um arquivo `KEY='valor'`.
# Usado quando o valor vem de `grep`/`cut` (que nao remove as aspas).
strip_quotes() {
  local value="${1:-}"
  value="${value%$'\n'}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}
