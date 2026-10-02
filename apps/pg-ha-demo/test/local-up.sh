#!/usr/bin/env bash
# Sobe 3 PostgreSQL 16 com replicação em streaming (podman) para testar o painel localmente.
# Primário pg-lab-1 e standbys pg-lab-2/3. Portas no host: 15432, 15433, 15434.
# Senhas aleatórias em test/.env.local (não vai para o Git).
set -euo pipefail
cd "$(dirname "$0")"
IMG=docker.io/library/postgres:16
NET=pgha
[ -f .env.local ] || {
  { echo "PG_PASSWORD=$(openssl rand -hex 10)"; echo "PG_REPL_PASSWORD=$(openssl rand -hex 10)"; echo "PG_SUPER_PASSWORD=$(openssl rand -hex 10)"; } > .env.local
}
# shellcheck disable=SC1091
source .env.local
./local-down.sh >/dev/null 2>&1 || true
podman network create $NET >/dev/null

COMMON=(-c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 -c hot_standby=on
  -c listen_addresses='*' -c wal_keep_size=512MB -c wal_log_hints=on
  -c 'synchronous_standby_names=ANY 1 ("pg-lab-1","pg-lab-2","pg-lab-3")' -c synchronous_commit=on
  -c max_connections=200)

mkdir -p init
cat > init/00-setup.sh <<SH
#!/usr/bin/env bash
set -e
psql -v ON_ERROR_STOP=1 -U postgres <<SQL
-- sem standby ainda: sem isto o COMMIT esperaria a replicação síncrona para sempre
SET synchronous_commit = local;
CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '${PG_REPL_PASSWORD}';
CREATE ROLE demo WITH LOGIN PASSWORD '${PG_PASSWORD}';
CREATE DATABASE demo OWNER demo;
GRANT pg_monitor TO demo;
GRANT ALTER SYSTEM ON PARAMETER primary_conninfo TO demo;
-- o ACL de função de sistema é por banco: conceder dentro do banco que o app usa
\\c demo
SET synchronous_commit = local;
GRANT EXECUTE ON FUNCTION pg_promote(boolean, integer) TO demo;
GRANT EXECUTE ON FUNCTION pg_reload_conf() TO demo;
SQL
echo "host replication replicator all scram-sha-256" >> "\$PGDATA/pg_hba.conf"
SH
chmod +x init/00-setup.sh

echo "== primário pg-lab-1"
podman run -d --name pg-lab-1 --network $NET -p 15432:5432 -e POSTGRES_PASSWORD="$PG_SUPER_PASSWORD" \
  -v "$PWD/init:/docker-entrypoint-initdb.d:ro,Z" -v pgha1:/var/lib/postgresql/data $IMG "${COMMON[@]}" >/dev/null
# o entrypoint sobe um servidor temporário só em socket, roda o init e reinicia: espere o TCP
for i in $(seq 1 90); do podman exec pg-lab-1 pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done

for n in 2 3; do
  echo "== standby pg-lab-$n (pg_basebackup)"
  podman volume create pgha$n >/dev/null
  podman run --rm --network $NET -e PGPASSWORD="$PG_REPL_PASSWORD" -v pgha$n:/var/lib/postgresql/data $IMG bash -c "
    rm -rf /var/lib/postgresql/data/* &&
    pg_basebackup -h pg-lab-1 -U replicator -D /var/lib/postgresql/data -R -X stream -P \
      -d 'host=pg-lab-1 user=replicator application_name=pg-lab-$n' &&
    chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data" >/dev/null
  podman run -d --name pg-lab-$n --network $NET -p 1543$((n+1)):5432 -v pgha$n:/var/lib/postgresql/data $IMG "${COMMON[@]}" >/dev/null
done
sleep 4
echo "== replicação"
podman exec pg-lab-1 psql -U postgres -h 127.0.0.1 -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
