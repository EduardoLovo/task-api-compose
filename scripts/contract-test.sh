#!/usr/bin/env bash
#
# Teste de contrato: confere que as APIs Express e Flask, já rodando, respondem
# igual (status, code e details dos erros) e que os tokens de uma não valem na outra.
#
# Uso:  ./scripts/contract-test.sh [URL_EXPRESS] [URL_FLASK]
# Padrão: http://localhost:$EXPRESS_PORT (3000) e http://localhost:$FLASK_PORT (5000).
# Requer: bash, curl e node.

set -euo pipefail

EXPRESS_URL="${1:-http://localhost:${EXPRESS_PORT:-3000}}"
FLASK_URL="${2:-http://localhost:${FLASK_PORT:-5000}}"
RUN_ID="$(date +%s)-$RANDOM"
failures=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; failures=$((failures + 1)); }

# Lê um campo do JSON da entrada padrão: json_field data.accessToken
json_field() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const v = process.argv[1].split(".").reduce((o, k) => (o == null ? o : o[k]), JSON.parse(s || "null"));
      console.log(v !== null && typeof v === "object" ? JSON.stringify(v) : v ?? "");
    });
  ' "$1"
}

# Resposta resumida para comparar as APIs: status + code + details (sem requestId).
error_signature() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const [body, status] = [s.slice(0, s.lastIndexOf("\n")), s.slice(s.lastIndexOf("\n") + 1)];
      let e = {};
      try { e = JSON.parse(body).error ?? {}; } catch {}
      console.log(JSON.stringify({ status: Number(status), code: e.code, details: e.details }));
    });
  '
}

# call <base_url> <method> <path> [token] [json_body]  → corpo + "\n" + status
call() {
  local base=$1 method=$2 path=$3 token=${4:-} body=${5:-}
  local args=(-s -X "$method" -w '\n%{http_code}' "$base$path")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-raw "$body")
  curl "${args[@]}"
}

register() {
  call "$1" POST /auth/register "" "{\"name\":\"Contrato\",\"email\":\"$2\",\"password\":\"senha-segura-123\"}" \
    | head -n -1 | json_field data.accessToken
}

echo "Express: $EXPRESS_URL"
echo "Flask:   $FLASK_URL"

echo
echo "▶ Saúde"
for name in Express Flask; do
  url=$([ $name = Express ] && echo "$EXPRESS_URL" || echo "$FLASK_URL")
  status=$(call "$url" GET /health | tail -1)
  [ "$status" = 200 ] && pass "$name /health → 200" || fail "$name /health → $status"
done

echo
echo "▶ Cadastro"
T_EXPRESS=$(register "$EXPRESS_URL" "contrato-$RUN_ID@example.com")
T_FLASK=$(register "$FLASK_URL" "contrato-$RUN_ID@example.com")
[ -n "$T_EXPRESS" ] && pass "Express emitiu token" || fail "Express não emitiu token"
[ -n "$T_FLASK" ] && pass "Flask emitiu token" || fail "Flask não emitiu token"

echo
echo "▶ Tokens não valem na outra API"
code=$(call "$EXPRESS_URL" GET /auth/me "$T_FLASK" | head -n -1 | json_field error.code)
[ "$code" = INVALID_TOKEN ] && pass "token do Flask recusado pelo Express" || fail "Express aceitou token do Flask ($code)"
code=$(call "$FLASK_URL" GET /auth/me "$T_EXPRESS" | head -n -1 | json_field error.code)
[ "$code" = INVALID_TOKEN ] && pass "token do Express recusado pelo Flask" || fail "Flask aceitou token do Express ($code)"

echo
echo "▶ Mesmo contrato de erros"
# método | caminho | precisa de token? | corpo
CASES=(
  "GET|/tasks|no|"
  "GET|/tasks|yes|"
  "GET|/nao-existe|no|"
  "PUT|/tasks|no|"
  "GET|/tasks/abc|yes|"
  "GET|/tasks/999999|yes|"
  "GET|/tasks?page=0&status=feito|yes|"
  "POST|/tasks|yes|{\"title\":\"\",\"priority\":\"urgente\",\"extra\":1}"
  "POST|/tasks|yes|{\"title\":"
  "POST|/tasks|yes|[1,2]"
  "PATCH|/tasks/1|yes|{}"
  "POST|/auth/register|no|{\"name\":1,\"email\":\"x\",\"password\":\"123\"}"
  "POST|/auth/login|no|{\"email\":\"ninguem@example.com\",\"password\":\"errada\"}"
)
for case in "${CASES[@]}"; do
  IFS='|' read -r method path needs_token body <<< "$case"
  te=""; tf=""
  if [ "$needs_token" = yes ]; then te=$T_EXPRESS; tf=$T_FLASK; fi
  se=$(call "$EXPRESS_URL" "$method" "$path" "$te" "$body" | error_signature)
  sf=$(call "$FLASK_URL" "$method" "$path" "$tf" "$body" | error_signature)
  label="$method $path${body:+ $body}"
  if [ "$se" = "$sf" ]; then
    pass "$label → $(echo "$se" | json_field status) $(echo "$se" | json_field code)"
  else
    fail "$label"
    echo "       Express: $se"
    echo "       Flask:   $sf"
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "Contrato OK: as duas APIs respondem igual."
else
  echo "$failures verificação(ões) falharam."
  exit 1
fi
