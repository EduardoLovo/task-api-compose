# Task API — Compose

[![CI](https://github.com/EduardoLovo/task-api-compose/actions/workflows/ci.yml/badge.svg)](https://github.com/EduardoLovo/task-api-compose/actions/workflows/ci.yml)

Sobe as duas versões da API de tarefas juntas com Docker:

| API | Repositório | Porta |
|---|---|---|
| Node.js + Express | `task-api-express` | http://localhost:3000 (docs em `/docs`) |
| Python + Flask | `task-api-flask` | http://localhost:5000 (docs em `/docs`) |

Este repositório não tem código: ele reaproveita o `docker-compose.yml` de cada projeto com o recurso
[`include`](https://docs.docker.com/compose/how-tos/multiple-compose-files/include/) do Compose.

## Pré-requisitos

- Docker com Compose 2.20 ou mais recente (Docker Desktop atual já atende).
- Os três repositórios lado a lado:

```
Dev/
├── task-api-compose/   ← este
├── task-api-express/
└── task-api-flask/
```

## Como rodar

```bash
cp .env.example .env   # edite o JWT_SECRET
docker compose up --build -d
```

```bash
docker compose ps          # estado e health check de cada API
docker compose logs -f     # logs das duas (em JSON)
docker compose down        # para e remove os containers (os dados ficam)
docker compose down -v     # também apaga os bancos de dados (volumes)
```

## Teste de contrato

Com as duas APIs no ar, este script confere que elas respondem **igual** (status, `code` e `details` dos erros)
e que o token de uma é recusado pela outra:

```bash
./scripts/contract-test.sh
```

Ele roda no CI a cada push, em pull requests e toda segunda-feira, já que mudanças nos repositórios das APIs
não disparam o CI deste. Também dá para rodar manualmente pela aba **Actions → CI → Run workflow**.

## Como funciona

- **Uma configuração, duas APIs**: as variáveis do `.env` desta pasta valem para as duas (`include` com `env_file`).
- **Bancos separados**: cada API guarda seu SQLite num volume próprio (`express-data` e `flask-data`), então os
  dados sobrevivem a reinícios e a `docker compose down`.
- **Tokens não se misturam**: mesmo com o `JWT_SECRET` em comum, cada API marca o emissor no token (`iss`) e
  recusa tokens da outra. Como os bancos são separados, o usuário `id = 1` de uma API é outra pessoa na outra.
- **Health check**: o Docker consulta `/health` a cada 30 s; `docker compose ps` mostra `healthy`.
- **Encerramento controlado**: `docker compose stop` envia SIGTERM; as APIs terminam as requisições em andamento,
  fecham o banco e saem com código 0.
- **Sem root**: os containers rodam com usuários sem privilégios (`node` e `appuser`).

## Variáveis

Veja [.env.example](.env.example). Só `JWT_SECRET` (mínimo de 32 caracteres) é obrigatória; sem ela o Compose
nem inicia e mostra o motivo.

| Variável | Padrão | Para quê |
|---|---|---|
| `JWT_SECRET` | — | Segredo de assinatura dos tokens |
| `EXPRESS_PORT` / `FLASK_PORT` | `3000` / `5000` | Portas no seu computador |
| `PYTHON_IMAGE` | `python:3.14-slim` | Imagem base do Flask |
| `JWT_EXPIRES_IN`, `BCRYPT_ROUNDS`, `CORS_ORIGIN`, `BODY_LIMIT`, `RATE_LIMIT_*` | ver `.env.example` | Repassadas às duas APIs |

Se a porta 3000 ou 5000 já estiver em uso (por exemplo, por um `npm run dev`), troque `EXPRESS_PORT` ou
`FLASK_PORT` no `.env`.
