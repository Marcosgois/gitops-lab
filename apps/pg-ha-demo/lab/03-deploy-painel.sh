#!/usr/bin/env bash
# Publica o painel no OpenShift (namespace demos) pelo ArgoCD: cria o Secret com as senhas
# (fica fora do Git), aplica a Application pg-ha-demo e espera o primeiro build e o rollout.
# O ArgoCD aplica apps/pg-ha-demo/deploy/ (RBAC, build a partir do Git, Deployment, Service e Route).
#
# Executado no lone em 02/10/2026. O build S2I roda `npm install` dentro do cluster: precisa de
# saída para o GitHub e para o registry npm.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt
NS=${NS:-demos}

oc whoami >/dev/null || { echo "oc sem login"; exit 1; }
oc create secret generic pg-ha-demo -n "$NS" \
  --from-literal=PG_PASSWORD="$PG_PASSWORD" --from-literal=PG_REPL_PASSWORD="$PG_REPL_PASSWORD" \
  --dry-run=client -o yaml | oc apply -n "$NS" -f -
oc apply -f ../../application-pg-ha-demo.yaml

echo "== esperando o ArgoCD criar o BuildConfig"
for _ in $(seq 1 60); do oc get bc pg-ha-demo -n "$NS" >/dev/null 2>&1 && break; sleep 5; done
echo "== build (a partir do Git)"
for _ in $(seq 1 60); do b=$(oc get builds -n "$NS" -l buildconfig=pg-ha-demo --sort-by=.metadata.creationTimestamp -o name | tail -1); [ -n "$b" ] && break; sleep 5; done
oc logs -f "$b" -n "$NS" | tail -3
oc rollout restart deploy/pg-ha-demo -n "$NS"
oc rollout status deploy/pg-ha-demo -n "$NS" --timeout=180s
echo "painel: https://$(oc get route pg-ha-demo -n "$NS" -o jsonpath='{.spec.host}')"
