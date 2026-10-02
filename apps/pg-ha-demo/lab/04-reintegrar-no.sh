#!/usr/bin/env bash
# Reintegra como STANDBY um nó que era primário (ou ficou para trás) depois de um failover:
# APAGA o diretório de dados do nó e reclona do primário atual com pg_basebackup.
#
# Por que não deixar o antigo primário voltar sozinho: depois do failover ele tem uma timeline
# mais antiga e pode ter transações que o novo primário não tem (split-brain). O painel mostra
# "primário obsoleto" e a aplicação o ignora, mas ele precisa ser reconstruído antes de voltar.
#
# Uso: ./lab/04-reintegrar-no.sh pg-lab-1 192.168.5.124     (nó a reconstruir, IP do primário atual)
#
# Executado no lone em 02/10/2026 (reintegrou pg-lab-1/2/3 várias vezes nos testes).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt
NODE=${1:?nome do nó (pg-lab-1|2|3)}; PRIMARY_IP=${2:?IP do primário atual}
FIRST_IP=${FIRST_IP:-123}
case "$NODE" in pg-lab-1) IP=192.168.5.$FIRST_IP;; pg-lab-2) IP=192.168.5.$((FIRST_IP + 1));; pg-lab-3) IP=192.168.5.$((FIRST_IP + 2));; *) echo "nó inválido"; exit 1;; esac
[ "$IP" != "$PRIMARY_IP" ] || { echo "$NODE é o próprio primário informado"; exit 1; }
PGD=/var/lib/pgsql/data
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

echo "ATENÇÃO: vou APAGAR $PGD em $NODE ($IP) e reclonar de $PRIMARY_IP."
read -r -p "Digite o nome do nó para confirmar: " ok
[ "$ok" = "$NODE" ] || { echo "cancelado"; exit 1; }

ssh "${SSH_OPTS[@]}" "cloud-user@$IP" "sudo systemctl stop postgresql; sudo -u postgres bash -c 'rm -rf $PGD/*'"
ssh "${SSH_OPTS[@]}" "cloud-user@$IP" "sudo -u postgres env PGPASSWORD='$PG_REPL_PASSWORD' pg_basebackup -h $PRIMARY_IP -U replicator -D $PGD -R -X stream -P -d 'host=$PRIMARY_IP user=replicator application_name=$NODE'"
ssh "${SSH_OPTS[@]}" "cloud-user@$IP" "sudo restorecon -R $PGD >/dev/null 2>&1 || true; sudo systemctl start postgresql"
sleep 3
ssh "${SSH_OPTS[@]}" "cloud-user@$PRIMARY_IP" "sudo -u postgres psql -X -c \"SELECT application_name, state, sync_state FROM pg_stat_replication;\""
