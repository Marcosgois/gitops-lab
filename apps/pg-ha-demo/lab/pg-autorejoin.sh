#!/usr/bin/env bash
# pg-autorejoin — roda em cada VM pg-lab-* (serviço systemd, como root).
#
# Faz o que o MongoDB faz sozinho: um primário que volta depois de um failover (VM retomada)
# percebe que existe outro primário com timeline MAIOR e se reintegra como standby dele.
#   1. pg_rewind: desfaz só o que divergiu (rápido). As transações que só ele tinha — as
#      "perdidas" do modo assíncrono — são descartadas, como no rollback do Mongo.
#   2. se o pg_rewind falhar: reclona inteiro com pg_basebackup.
#
# Só age quando: o PostgreSQL local está de pé, é primário, e um par responde como primário
# com timeline maior. Com o PostgreSQL parado (manutenção manual), não faz nada.
# Senha do replicator: /var/lib/pgsql/.pgpass (lida pelo libpq, também pelo walreceiver).
# Configuração: /etc/pg-autorejoin.conf (SELF_NAME, SELF_IP, PEERS).
set -u
# shellcheck disable=SC1091
source /etc/pg-autorejoin.conf
PGD=/var/lib/pgsql/data
INTERVAL=${INTERVAL:-3}
TL_SQL="SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary:' || ('x' || substring(pg_walfile_name(pg_current_wal_lsn()) from 1 for 8))::bit(32)::int END"

# setpriv e não runuser/sudo: esses abrem sessão PAM e encheriam o journal a cada volta
pg() { setpriv --reuid=postgres --regid=postgres --init-groups env HOME=/var/lib/pgsql "$@"; }
log() { echo "pg-autorejoin: $*"; }

rejoin() {
  local src=$1 conn="host=$1 user=replicator dbname=postgres application_name=$SELF_NAME connect_timeout=5"
  log "sou primário obsoleto; reintegrando como standby de $src"
  systemctl stop postgresql
  if pg pg_rewind -D "$PGD" --source-server="$conn" -R; then
    log "pg_rewind concluído"
  else
    log "pg_rewind falhou — reclonando com pg_basebackup"
    pg bash -c "rm -rf '$PGD'/*"
    pg pg_basebackup -c fast -h "$src" -U replicator -D "$PGD" -R -X stream -d "$conn" || { log "pg_basebackup falhou"; return 1; }
  fi
  restorecon -R "$PGD" >/dev/null 2>&1 || true
  systemctl start postgresql && log "de volta ao pool como standby de $src"
}

while sleep "$INTERVAL"; do
  systemctl is-active -q postgresql || continue
  me=$(pg psql -XAtqc "$TL_SQL" 2>/dev/null) || continue
  [ "${me%%:*}" = primary ] || continue
  mytl=${me#primary:}
  for p in $PEERS; do
    [ "$p" = "$SELF_IP" ] && continue
    peer=$(pg psql -XAtq "host=$p user=replicator dbname=postgres connect_timeout=2" -c "$TL_SQL" 2>/dev/null) || continue
    [ "${peer%%:*}" = primary ] || continue
    if [ "${peer#primary:}" -gt "$mytl" ]; then rejoin "$p"; break; fi
  done
done
