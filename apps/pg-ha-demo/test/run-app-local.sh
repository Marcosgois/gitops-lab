#!/usr/bin/env bash
# Roda o painel contra o cluster local (local-up.sh). Abre em http://localhost:8080
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source .env.local
export PG_HOSTS=127.0.0.1:15432,127.0.0.1:15433,127.0.0.1:15434
export PG_PEER_HOSTS=pg-lab-1:5432,pg-lab-2:5432,pg-lab-3:5432
export PG_USER=demo PG_DB=demo PG_PASSWORD PG_REPL_PASSWORD
export CHAOS_CMD="podman {action} {name}"
export AUTO_PROMOTE=${AUTO_PROMOTE:-1}
export PORT=${PORT:-8080}
exec node ../src/server.js
