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

## Deploy no Render

O [`render.yaml`](render.yaml) (*Blueprint*) cria as duas APIs no Render, cada uma a partir do `Dockerfile` do
próprio repositório: projeto **Task API**, ambiente **Production**, plano **free**, região **virginia**.

1. No Render: **New → Blueprint**, conecte o GitHub e escolha este repositório.
2. Confira os dois serviços listados e clique em **Deploy Blueprint**.
3. Cada API ganha um `JWT_SECRET` próprio, gerado pelo Render (cada uma tem o seu banco de usuários).

Depois disso, cada push na `main` de uma API dispara o deploy dela, **só depois que o CI passar**
(`autoDeployTrigger: checksPass`).

**Limitações do plano free:** o serviço dorme após 15 minutos sem acesso e leva cerca de 1 minuto para acordar. O
disco é temporário, então o banco SQLite começa vazio a cada deploy, reinício ou soneca. As 750 horas gratuitas por
mês são somadas entre todos os serviços: não use serviços que "pingam" a API para mantê-la acordada.

### Conferir o `TRUST_PROXY`

No Render, as requisições chegam por proxies. O `TRUST_PROXY` diz quantos deles a API deve atravessar para achar o IP
real do cliente, que o rate limit usa.

**Valor atual: `3`** (Cloudflare e proxies internos do Render). Medido em 2026-10-08: com `1`, as APIs viam IPs
internos `10.x` que mudavam a cada requisição; com `3`, viam o IP real e ignoravam um `X-Forwarded-For` forjado.
O Render não documenta esse número, então vale conferir de novo se o comportamento mudar.

**Conferência rápida, sem os logs:** o cabeçalho `RateLimit` informa quantas requisições restam (`r=`). Com o valor
certo, ele cai de 1 em 1 em requisições seguidas, mesmo com IPs forjados:

```bash
for ip in "" 1.2.3.4 5.6.7.8; do
  curl -s -D - -o /dev/null ${ip:+-H "X-Forwarded-For: $ip"} https://task-api-express-2pva.onrender.com/tasks \
    | grep -i '^ratelimit:'
done
```

Se o `r=` pular ou voltar a subir, cada requisição está caindo num "balde" diferente: o valor está errado.

**Conferência completa, pelos logs:** envie requisições marcadas (as APIs reaproveitam o `X-Request-Id`) e procure a
marca em **Logs**, no painel do serviço:

```bash
curl -4 https://ifconfig.me                                         # seu IP público (IPv4)
curl -H "X-Request-Id: sonda-1" -H "X-Forwarded-For: 1.2.3.4" \
  https://task-api-express-2pva.onrender.com/tasks
```

| O campo `ip` mostra | Significa | Ação |
|---|---|---|
| O seu IP público | Valor certo | Nada a fazer |
| `1.2.3.4` | Alto demais: o cliente consegue forjar o IP | Diminuir o `TRUST_PROXY` |
| Um IP interno (`10.x`, `172.x`...) | Baixo demais: todos os clientes parecem um só | Aumentar o `TRUST_PROXY` |

Altere o valor no `render.yaml` e faça o merge. Uma mudança feita só no painel é sobrescrita na próxima
sincronização do Blueprint.

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
