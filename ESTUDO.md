# Task API Compose — Anotações de estudo

> **Data:** 2026-10-06 · **Stack:** Docker Compose · Bash · GitHub Actions · ShellCheck

---

## 1. Visão geral

Repositório **sem código de aplicação**: ele sobe juntas as duas versões da API de tarefas, a Express
(`task-api-express`, porta 3000) e a Flask (`task-api-flask`, porta 5000), e verifica com um **teste de contrato**
que as duas respondem igual.

Ele existe porque as APIs vivem em repositórios separados. Só um terceiro repositório, que enxerga os dois, consegue
testar a comparação entre eles.

---

## 2. Arquitetura

```mermaid
flowchart LR
    subgraph compose[task-api-compose]
        DC[docker-compose.yml<br/>include + .env]
        CT[scripts/contract-test.sh]
    end
    DC -- include --> E[task-api-express/<br/>docker-compose.yml]
    DC -- include --> F[task-api-flask/<br/>docker-compose.yml]
    E --> EC[(container express<br/>:3000 · volume express-data)]
    F --> FC[(container flask<br/>:5000 · volume flask-data)]
    CT -- mesmas requisições --> EC
    CT -- mesmas requisições --> FC
```

Os três repositórios precisam estar **lado a lado**, porque o `include` usa caminhos relativos (`../task-api-express`):

```
Dev/
├── task-api-compose/        ← este repositório
│   ├── docker-compose.yml   # include dos composes das duas APIs
│   ├── .env.example         # variáveis para as duas APIs (o .env real não vai para o Git)
│   ├── scripts/
│   │   └── contract-test.sh # teste de contrato entre as duas
│   ├── .github/             # CI e Dependabot
│   └── .gitattributes       # scripts .sh sempre com LF
├── task-api-express/
└── task-api-flask/
```

---

## 3. Fases e etapas

### Fase 1 — Onde colocar o docker-compose
- **Decisão:** cada API tem o próprio `Dockerfile` e `docker-compose.yml` (sobe sozinha), e um **terceiro
  repositório** sobe as duas juntas.
- **Alternativa descartada:** só um compose em cada repositório, sem nada para subir as duas juntas. Seria mais
  simples, mas perderia a comparação entre elas.

### Fase 2 — `include` em vez de copiar a configuração
- **O que foi feito:** o `docker-compose.yml` daqui só tem um `include` de cada compose das APIs, cada um com
  `env_file: .env`, para que as variáveis **desta pasta** valham para as duas.
- **Por quê:** a configuração de cada API (portas, volumes, health check, variáveis) fica num lugar só: no
  repositório dela. Se a API mudar, este compose acompanha sem ser editado.
- **Cuidado:** com `include`, os nomes de serviços e volumes não podem se repetir. Por isso os serviços se chamam
  `express` e `flask`, e os volumes `express-data` e `flask-data`.

### Fase 3 — Primeiro teste com containers (e o disco cheio)
- **O que aconteceu:** as imagens foram construídas, mas a criação dos containers falhou com
  `read-only file system`. O disco **C: estava com 0 GB livres**, e o Docker Desktop, que guarda o disco virtual no
  C:, passou a tratá-lo como somente leitura.
- **Consequências, depois de liberar espaço:**
  - A imagem do Flask ficou **corrompida**: sem o usuário `root` e, depois, com `exec format error`. Investigando
    com `docker cp`, o `/usr/bin/dash` da imagem tinha **0 bytes**: as camadas da `python:3.14-slim` foram gravadas
    pela metade.
  - Nem `--no-cache --pull`, nem `docker builder prune` (16,9 GB de cache), nem reiniciar o Docker resolveram. Como
    as camadas são identificadas por hash, o Docker continuava achando que já tinha os arquivos.
  - **Contorno:** a imagem base do Flask virou configurável (`PYTHON_IMAGE`), e só o `.env` desta máquina usa a
    variante `python:3.14-slim-bookworm`, que não foi afetada. A solução definitiva é o **Clean / Purge data** do
    Docker Desktop (que apaga todas as imagens, containers e volumes).

### Fase 4 — Falha de segurança encontrada no teste conjunto
- **O que aconteceu:** um token emitido pelo Flask funcionou no Express e devolveu o usuário do banco do Express. As
  duas APIs compartilhavam o `JWT_SECRET`, mas têm bancos separados: o usuário `id = 1` é uma pessoa diferente em cada
  uma.
- **Solução (nas APIs):** cada uma marca o emissor no token (`iss`) e recusa tokens da outra.
- **Por que importa:** essa falha só apareceu porque as duas APIs rodaram juntas. Os testes de cada repositório,
  isolados, nunca a pegariam.

### Fase 5 — Teste de contrato (`scripts/contract-test.sh`)
- **O que faz:** com as duas APIs no ar, envia as **mesmas requisições** para as duas e compara status, `code` e
  `details` dos erros (o `requestId` fica de fora, porque é sempre diferente). Também confere que o token de uma é
  recusado pela outra.
- **Casos cobertos:** sem token, rota inexistente, método errado, ID inválido, tarefa inexistente, query inválida,
  corpo inválido, JSON quebrado, corpo em array, PATCH vazio, 32 e 33 níveis de aninhamento, cadastro inválido e
  login errado.
- **Divergências que ele já encontrou:**
  1. Corpo em array (`[1,2]`): o Express respondia com a mensagem genérica do Zod. Foi alinhado com a do Flask.
  2. JSON com 33+ níveis de aninhamento: passou a ser recusado com a mesma mensagem nas duas.
- Também roda no seu computador: `./scripts/contract-test.sh`.

### Fase 6 — CI
- **O que foi feito:** o workflow faz checkout dos **três repositórios** nas mesmas posições de pasta do ambiente
  local, cria um `.env` com segredo aleatório (`openssl rand`), sobe tudo com `docker compose up --wait` (espera os
  health checks), roda o teste de contrato, confere que `docker compose stop` termina com código 0 e sempre limpa
  tudo no fim (`if: always()`).
- **Gatilhos:** push, pull request, execução manual e **toda segunda às 9h**. O agendamento existe porque um push no
  Express ou no Flask **não** dispara o CI deste repositório.
- **Primeira falha:** o compose foi enviado ao GitHub 50 segundos **antes** da correção no Express. O CI baixou a
  versão antiga do Express e o contrato falhou. Bastou rodar de novo. Lição: quando a mudança atravessa repositórios,
  envie primeiro as APIs e depois o compose.

### Fase 7 — Dependabot, proteção da `main` e lint
- **Dependabot** só para GitHub Actions (as dependências das APIs são atualizadas nos repositórios delas).
- **Ruleset na `main`:** exige PR e os checks `Contrato Express × Flask` e `Lint`.
- **Job Lint:** **ShellCheck** no script e **actionlint** nos workflows. O ShellCheck apontou o padrão
  `A && B || C`, que não é um if/else de verdade (se `B` falhar, `C` também roda); foi trocado por uma função
  `check` com `if` explícito.

---

## 4. Ferramentas e tecnologias

| Ferramenta | Para que serve (em geral) | Como foi usada aqui | Por que foi escolhida |
|---|---|---|---|
| **Docker Compose** | Subir vários containers com um arquivo | Sobe as duas APIs | Padrão para ambientes com mais de um serviço |
| **`include` do Compose** | Reaproveitar arquivos compose de outros lugares | Inclui o compose de cada API | Evita duplicar configuração (exige Compose 2.20+) |
| **Bash + curl + node** | Script de linha de comando | Teste de contrato | Roda igual no CI (Linux) e no Git Bash do Windows; o `node` lê o JSON (o `jq` não vem no Git Bash) |
| **GitHub Actions** | CI | Checkout dos 3 repos, compose, contrato | Integrado ao GitHub |
| **ShellCheck** | Lint de scripts shell | Job Lint | Pega armadilhas do Bash que passam despercebidas |
| **actionlint** | Lint de workflows | Job Lint | Valida sintaxe e os scripts dentro dos workflows |
| **Dependabot** | PRs automáticos de atualização | Versões das actions | Mantém o CI atualizado |

### Explicando as principais

- **Docker Compose:** descreve serviços, portas, volumes e variáveis num YAML. `docker compose up --build -d` constrói
  as imagens e sobe tudo em segundo plano; `--wait` espera os health checks ficarem `healthy`.
- **Interpolação de variáveis:** `${JWT_SECRET:?mensagem}` falha com a mensagem se a variável não existir;
  `${EXPRESS_PORT:-3000}` usa 3000 como padrão.
- **`set -euo pipefail`:** faz o script parar no primeiro erro (`-e`), em variável não definida (`-u`) e em falhas
  no meio de um pipe (`pipefail`). É mais seguro, mas tem pegadinhas (veja a seção 7).

---

## 5. Comandos usados

```bash
# Cria o .env (depois edite o JWT_SECRET)
cp .env.example .env

# Sobe as duas APIs (constrói as imagens) e espera os health checks
docker compose up --build -d --wait

# Estado, logs e parada
docker compose ps
docker compose logs -f
docker compose down        # remove os containers (os dados ficam nos volumes)
docker compose down -v     # também apaga os bancos

# Teste de contrato (com as APIs no ar)
./scripts/contract-test.sh

# Testar em outras portas e com outro nome de projeto, sem conflitar com o ambiente principal
EXPRESS_PORT=3100 FLASK_PORT=5100 docker compose -p task-api-smoke up -d --build --wait
EXPRESS_PORT=3100 FLASK_PORT=5100 ./scripts/contract-test.sh
docker compose -p task-api-smoke down -v

# Validar o compose sem subir nada
docker compose config --quiet

# Diagnóstico do Docker (usado no problema do disco cheio)
docker system df
docker builder prune -a -f   # apaga o cache de build (não apaga imagens nem volumes)
```

---

## 6. Conceitos-chave

- **Teste de contrato:** em vez de testar o código por dentro, testa o comportamento visível (requisição → resposta)
  e compara duas implementações que deveriam ser equivalentes.
- **Teste de integração entre serviços:** alguns problemas só aparecem com os sistemas rodando juntos, como a falha
  do token compartilhado.
- **Volume do Docker:** área de dados fora do container. Os bancos sobrevivem a `docker compose down` e só somem com
  `down -v`.
- **Health check e `--wait`:** o Docker pergunta periodicamente à API se ela está bem (`/health`), e o `--wait` só
  libera o próximo passo quando as duas estão `healthy`.
- **Armazenamento por conteúdo (hash):** o Docker identifica cada camada pelo hash do conteúdo. Se uma camada fica
  corrompida mas o registro dela continua, o Docker não baixa de novo.
- **Quebras de linha (LF × CRLF):** o Windows usa CRLF; o Bash não aceita CRLF em scripts (`\r: command not found`).
  O `.gitattributes` com `*.sh text eol=lf` garante LF.

---

## 7. Problemas encontrados e soluções

| Problema | Causa | Solução |
|---|---|---|
| `read-only file system` ao criar containers | Disco C: com 0 GB livres | Liberar espaço no C: |
| Imagem do Flask sem `root` e com `exec format error` | Camadas da `python:3.14-slim` gravadas pela metade quando o disco encheu (`dash` com 0 bytes) | `PYTHON_IMAGE=python:3.14-slim-bookworm` no `.env` local; definitivo: Clean / Purge data do Docker Desktop |
| Porta 3000 ocupada no teste | Um `npm run dev` rodando no computador | `EXPRESS_PORT`/`FLASK_PORT` e um nome de projeto separado (`-p task-api-smoke`) |
| Token de uma API aceito pela outra | `JWT_SECRET` compartilhado com bancos separados | Claim `iss` nas duas APIs |
| Script parava em silêncio no primeiro caso | `label="$( [ -n "$body" ] && echo ... )"` devolve código 1 com o corpo vazio, e o `set -e` encerra o script | `${body:+ $body}` (expansão de parâmetro, sem subshell) |
| Diferença de mensagem para corpo em array | Express e Flask usavam mensagens diferentes | Alinhar o Express (achado pelo próprio teste de contrato) |
| CI do compose falhou no primeiro push | O compose subiu antes da correção do Express chegar | Rodar de novo; enviar as APIs antes do compose |
| `A && B \|\| C` apontado pelo ShellCheck | Não é if/else: `C` roda se `B` falhar | Função `check` com `if` explícito |
| Script poderia quebrar no Windows | O Git converte LF → CRLF ao baixar | `.gitattributes` com `*.sh text eol=lf` |

---

## 8. O que aprendi

- Organizar vários repositórios que dependem uns dos outros sem duplicar configuração (`include`).
- Escrever um teste de contrato que compara duas implementações e acha divergências reais.
- Que testar sistemas juntos revela problemas invisíveis nos testes isolados (a falha do token).
- Diagnosticar o Docker de verdade: disco cheio, camadas corrompidas, o que o cache resolve e o que não resolve.
- Pegadinhas de Bash: `set -e` com subshell, `A && B || C`, quebras de linha CRLF.
- CI que depende de outros repositórios: checkout múltiplo, execução agendada e ordem dos pushes.

---

## 9. Próximos passos / para estudar mais

- Disparar este CI automaticamente quando o Express ou o Flask mudarem (`repository_dispatch`).
- Incluir o frontend Angular (`task-app-angular`) no compose.
- Mais casos no teste de contrato (fluxos de sucesso completos, paginação, ordenação).

**Documentação oficial**
- Docker Compose `include`: https://docs.docker.com/compose/how-tos/multiple-compose-files/include/
- Docker Compose (referência): https://docs.docker.com/reference/compose-file/
- GitHub Actions (checkout de vários repositórios): https://github.com/actions/checkout
- ShellCheck: https://www.shellcheck.net/
- Bash `set` e expansão de parâmetros: https://www.gnu.org/software/bash/manual/bash.html
