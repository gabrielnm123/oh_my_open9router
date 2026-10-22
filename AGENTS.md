# **PLANO DE EXECUÇÃO — AGENTS.md**

Este documento estabelece o fluxo de trabalho detalhado para subida, hardening e validação do servidor **9router** (IP `${VENICE_STACK_SSH_HOST}`), bem como a integração do ecossistema local utilizando **OpenCode** e **oh-my-opencode-slim**.

---

# **0\. Contexto, Convenções e Regras Não-Negociáveis**

## **Estado Atual**

* **9router:** Desligado voluntariamente no servidor. O túnel nativo encontra-se inativo até a inicialização da aplicação.  
* **Ambiente Servidor:** Usuário `${VENICE_STACK_SSH_USER}`, sem sessão SSH ativa no momento.  
* **Ambiente Local:** OpenCode v2 instalado (WSL/zsh). A chave SSH requer autenticação via passphrase.

## **Diretrizes de Ambiente e Shell**

| Ambiente | Shell / Contexto | Arquivo de Carga | Diretriz de Execução |
| :---- | :---- | :---- | :---- |
| **Local** | `zsh` (WSL / OpenCode) | `~/.zshenv` | Variáveis de ambiente *devem* residir em `~/.zshenv` (não em `.zshrc`) para suportar shells não-interativos (`zsh -c`). |
| **Servidor** | `bash` (Ubuntu) | Service-bound | Configurações globais injetadas via `systemd` (`EnvironmentFile=`). Sem alteração de perfil do shell. |

## **Regras de Execução e Segurança**

1. **Comandos com PATH Explicito:** Invocar dependências do Node.js/npm no servidor usando `bash -lc`.  
2. **Sintaxe Zsh Local:** Utilizar `printf` em vez de `echo` para strings contendo barras invertidas (`\`). Manter aspas em variáveis para prevenir expansões indevidas.  
3. **Isolamento de Túnel:** O túnel nativo do 9router é intocável. Proibido criar instâncias paralelas do Cloudflared/Ngrok ou alterar a URL de roteamento.  
4. **Segurança de Porta:** A porta `20128` não deve ser exposta externamente. Todo o tráfego externo deve transitar obrigatoriamente pelo túnel.  
5. **Resiliência e Registro:** Efetuar backup dos arquivos críticos (`data.sqlite`, `opencode.json`, `oh-my-opencode-slim.json`) antes de alterações. Garantir idempotência em todas as fases e registrar logs em `PLAN.md`.

---

# **1\. Referência Rápida: Endpoints Internos do 9router**

Chamadas locais via SSH no servidor possuem acesso direto aos endpoints administrativos internos (restritos à interface local):

| Método | Endpoint | Função / Finalidade |
| :---- | :---- | :---- |
| `GET` | `/api/health` | Verificação de liveness do serviço. |
| `GET` | `/api/version` | Retorna a versão instalada da aplicação. |
| `GET` | `/api/providers` | Lista as conexões de provedores configuradas. |
| `GET` | `/api/models` | Consulta o catálogo de modelos roteáveis. |
| `GET` | `/api/keys` | Gerenciamento de chaves de API de clientes. |
| `POST` | `/api/tunnel/enable` | Habilita e força a inicialização do túnel nativo. |
| `POST` | `/api/tunnel/disable` | Desativa a conexão do túnel nativo. |

---

# **2\. Fases de Execução**

## **Fase 0 — Preparação, Descoberta, Hardening e Partida**

### **0.0 Autenticação SSH Não-Interativa (Local)**

Configurar o `~/.zshenv` local para carregar o `ssh-agent` e inicializar a chave SSH com suporte a askpass sem intervenção manual.\# Validação da sessão SSH não-interativa

ssh-add \-l

ssh \-o BatchMode=yes ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST} 'echo SSH\_OK'

zsh \-c 'ssh \-o BatchMode=yes ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST} "echo NONINTERACTIVE\_OK"'

### **0.1 Mapeamento e Diagnóstico do Servidor**

Coletar métricas do ambiente remoto:ssh ${VENICE_STACK_SSH_USER}@${VENICE_STACK_SSH_HOST} 'bash \-lc "uname \-a; node \-v; npm \-v; nproc; free \-h; df \-h /"'

### **0.2 Configuração do Daemon Systemd**

Criar e provisionar a unidade de serviço `/etc/systemd/system/9router.service` no servidor com as variáveis operacionais mínimas (PORT=20128, NODE\_ENV=production, Restart=always).\# Comandos de inicialização no servidor

sudo systemctl daemon-reload

sudo systemctl enable 9router.service

sudo systemctl start 9router.service

### **0.3 Hardening de Segurança**

Editar o arquivo `~/9router/.env` para garantir a aplicação das políticas de segurança:

* Definir `REQUIRE_API_KEY=true`  
* Alterar o valor padrão de `INITIAL_PASSWORD`  
* Definir uma chave secreta robusta em `JWT_SECRET`

Reiniciar o serviço e validar a restrição de acesso (requisições sem chave devem retornar código `401 Unauthorized`).

### **0.4 Restabelecimento do Túnel Nativo**

Criar o script local tools/wait-tunnel.sh. O script efetuará chamadas via SSH para a rota local POST /api/tunnel/enable até que a URL pública do túnel responda com código HTTP 200 ou `401`.

---

## **Fase 1 — Configuração do Provedor no OpenCode**

1. Persistir a chave de API no ambiente local executando a gravação em `~/.zshenv`:export NINEROUTER\_API\_KEY="sua\_chave\_aqui"  
2. Atualizar a configuração do cliente em `~/.config/opencode/opencode.json` apontando para o provedor `9router` com o endpoint resolvido do túnel nativo.

---

## **Fase 2 — Instalação do Framework de Agentes**

Executar o setup do ambiente e verificar a integridade da instalação dos subagentes:h

# **Instalação do ecossistema de agentes em background**

npx oh-my-opencode-slim@latest install \--no-tui \--background-subagents=yes

# **Diagnóstico e validação da instalação**

npx oh-my-opencode-slim@latest doctor

\---

\#\#\# Fase 3 — Sondagem e Validação de Modelos

1\. Obter a lista completa de modelos disponíveis via API do 9router.

2\. Desenvolver o script de benchmark \`tools/probe-models.sh\`.

3\. Executar o script enviando requisições contendo payload estruturado com \`tool\_choice=auto\` e a definição da função \`get\_weather\`.

4\. Mapear a telemetria no arquivo de saída \`probe.jsonl\` contendo:

   \* Tempo de resposta (latência)

   \* Status HTTP retornado

   \* Confirmação de disparo correto de \*Tool Calling\*

\---

\#\#\# Fase 4 — Mapeamento e Atribuição de Agentes

Com base nos dados coletados na fase de sondagem, estruturar o arquivo de configuração \`\~/.config/opencode/oh-my-opencode-slim.json\` vinculando os modelos aprovados a cada papel especializado:

\* \*\*Orchestrator:\*\* Gestão e distribuição de tarefas complexas.

\* \*\*Oracle:\*\* Consultas de alto nível e raciocínio analítico.

\* \*\*Explorer:\*\* Varredura, leitura e contexto de código.

\* \*\*Designer:\*\* Arquitetura de interface e padrões estéticos.

\* \*\*Fixer:\*\* Resolução de bugs e refatoração direta.

\* \*\*Observer:\*\* Auditoria e acompanhamento de execução.

\* \*\*Council:\*\* Validação cruzada e consenso de decisões.

\---

\#\#\# Fase 5 — Homologação Final

Executar a bateria de testes integrados para garantir o alinhamento da pilha:

\`\`\`bash

\# Validação da suíte do plugin e conectividade do catálogo

npx oh-my-opencode-slim doctor

opencode models  
