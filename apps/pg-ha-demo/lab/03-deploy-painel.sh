#!/usr/bin/env bash
# Publica o painel no OpenShift (namespace demos): RBAC, build binário (S2I Node.js 20),
# Deployment, Service e Route. O código é enviado direto da pasta src/ — não precisa de Git.
#
# Executado no lone em 02/10/2026. O build S2I roda `npm install` dentro do cluster: precisa de
# saída para o registry npm. Se o lab não tiver, a pasta src/node_modules já vai junto
# (a dependência `pg` é JavaScript puro, serve em qualquer arquitetura).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt
NS=${NS:-demos}

oc whoami >/dev/null || { echo "oc sem login"; exit 1; }
[ -d src/node_modules ] || (cd src && npm install --no-audit --no-fund)

oc apply -n "$NS" -f deploy/00-rbac.yaml -f deploy/10-build.yaml
oc create secret generic pg-ha-demo -n "$NS" \
  --from-literal=PG_PASSWORD="$PG_PASSWORD" --from-literal=PG_REPL_PASSWORD="$PG_REPL_PASSWORD" \
  --dry-run=client -o yaml | oc apply -n "$NS" -f -
echo "== build"
oc start-build pg-ha-demo -n "$NS" --from-dir=src --follow
oc apply -n "$NS" -f deploy/20-app.yaml
oc rollout status deploy/pg-ha-demo -n "$NS" --timeout=180s
echo "painel: https://$(oc get route pg-ha-demo -n "$NS" -o jsonpath='{.spec.host}')"
