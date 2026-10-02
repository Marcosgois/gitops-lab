#!/usr/bin/env bash
# Configura a replicação em streaming entre pg-lab-1 (primário), pg-lab-2 e pg-lab-3 (standbys),
# por SSH como cloud-user (sudo). Idempotente o bastante para rodar de novo se algo falhar no meio,
# MAS recria os standbys do zero (apaga o diretório de dados deles).
#
# Executado no lone em 02/10/2026. A lógica foi validada antes com 3 PostgreSQL 16 em contêineres
# (test/local-up.sh); aqui muda a imagem (CentOS Stream 9: /var/lib/pgsql/data, serviço `postgresql`).
#
# Lições do teste local, já aplicadas abaixo:
#   * application_name com hífen precisa de aspas em synchronous_standby_names: ANY 1 ("pg-lab-1",...)
#   * com synchronous_standby_names ligado e SEM standby, todo COMMIT trava — por isso a lista
#     só é aplicada depois que os dois standbys estão em streaming
#   * ACL de função de sistema (pg_promote, pg_reload_conf) é por banco: o GRANT vai no banco `demo`
#   * a lista de nomes é SIMÉTRICA (os três) e vai em TODOS os nós: o nó que for promovido já nasce
#     com a regra certa
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt            # PG_PASSWORD, PG_REPL_PASSWORD

FIRST_IP=${FIRST_IP:-123}
IPS=("192.168.5.$FIRST_IP" "192.168.5.$((FIRST_IP + 1))" "192.168.5.$((FIRST_IP + 2))")
NAMES=(pg-lab-1 pg-lab-2 pg-lab-3)
SUBNET=${SUBNET:-192.168.5.0/24}
PGD=/var/lib/pgsql/data
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
SYNC_NAMES='ANY 1 ("pg-lab-1","pg-lab-2","pg-lab-3")'

rsh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "cloud-user@$ip" "$@"; }
psql_pg() { local ip=$1; shift; rsh "$ip" "sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q $*"; }

# a imagem databases-gold sobe o MongoDB também; aqui ele só gastaria memória
for ip in "${IPS[@]}"; do rsh "$ip" "sudo systemctl disable --now mongod >/dev/null 2>&1 || true"; done

echo "== 1/5 primário ${NAMES[0]} (${IPS[0]})"
rsh "${IPS[0]}" "sudo systemctl is-active postgresql" >/dev/null || rsh "${IPS[0]}" "sudo systemctl start postgresql"
# senhas entram por stdin (não aparecem em argumentos de processo)
rsh "${IPS[0]}" "sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q" <<SQL
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET hot_standby = 'on';
ALTER SYSTEM SET wal_keep_size = '1GB';
ALTER SYSTEM SET wal_log_hints = 'on';
-- VM pausada não fecha o TCP: com o padrão (60 s) o primário seguiria contando o standby
-- congelado no quórum. 5 s faz o painel ver a perda do quórum quase na hora.
ALTER SYSTEM SET wal_sender_timeout = '5s';
ALTER SYSTEM SET wal_receiver_timeout = '5s';
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN CREATE ROLE replicator LOGIN REPLICATION; END IF;
END \$\$;
ALTER ROLE replicator WITH LOGIN REPLICATION PASSWORD '${PG_REPL_PASSWORD}';
ALTER ROLE demo WITH PASSWORD '${PG_PASSWORD}';          -- troca a senha conhecida gravada na imagem
GRANT pg_monitor TO demo;
GRANT ALTER SYSTEM ON PARAMETER primary_conninfo TO demo;
SQL
rsh "${IPS[0]}" "sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q -d demo" <<'SQL'
GRANT EXECUTE ON FUNCTION pg_promote(boolean, integer) TO demo;
GRANT EXECUTE ON FUNCTION pg_reload_conf() TO demo;
SQL
# pg_hba: replicação e aplicação vindas da rede do lab
rsh "${IPS[0]}" "sudo grep -q '^host *replication *replicator' $PGD/pg_hba.conf || echo 'host  replication  replicator  $SUBNET  scram-sha-256' | sudo tee -a $PGD/pg_hba.conf >/dev/null"
rsh "${IPS[0]}" "sudo grep -q '^host *all *all *$SUBNET' $PGD/pg_hba.conf || echo 'host  all  all  $SUBNET  scram-sha-256' | sudo tee -a $PGD/pg_hba.conf >/dev/null"
rsh "${IPS[0]}" "sudo systemctl restart postgresql"
sleep 3

for n in 1 2; do
  ip=${IPS[$n]}; nm=${NAMES[$n]}
  echo "== $((n + 1))/5 standby $nm ($ip) — pg_basebackup do primário"
  rsh "$ip" "sudo systemctl stop postgresql; sudo -u postgres bash -c 'rm -rf $PGD/*'"
  rsh "$ip" "sudo -u postgres env PGPASSWORD='$PG_REPL_PASSWORD' pg_basebackup -c fast -h ${IPS[0]} -U replicator -D $PGD -R -X stream -P -d 'host=${IPS[0]} user=replicator application_name=$nm'"
  rsh "$ip" "sudo restorecon -R $PGD >/dev/null 2>&1 || true; sudo systemctl start postgresql"
done

echo "== 4/5 esperando os dois standbys em streaming"
for t in $(seq 1 30); do
  c=$(rsh "${IPS[0]}" "sudo -u postgres psql -Atqc \"SELECT count(*) FROM pg_stat_replication WHERE state='streaming'\"" || echo 0)
  [ "$c" = 2 ] && break; sleep 2
done
[ "$c" = 2 ] || { echo "só $c standby(s) em streaming — veja journalctl -u postgresql nas VMs"; exit 1; }

echo "== 5/5 replicação síncrona em quórum, em TODOS os nós (agora que há standbys)"
for ip in "${IPS[@]}"; do
  rsh "$ip" "sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q" <<SQL
ALTER SYSTEM SET synchronous_standby_names = '$SYNC_NAMES';
ALTER SYSTEM SET synchronous_commit = 'on';
SELECT pg_reload_conf();
SQL
done
sleep 2
rsh "${IPS[0]}" "sudo -u postgres psql -X -c \"SELECT application_name, state, sync_state FROM pg_stat_replication;\""
echo "pronto. Esperado: pg-lab-2 e pg-lab-3 em 'streaming' / 'quorum'."
echo "Próximo: ./lab/03-deploy-painel.sh"
