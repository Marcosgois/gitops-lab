#!/usr/bin/env bash
# Volta do Patroni para o modo "normal": PostgreSQL no systemd, failover assistido do painel e
# pg-autorejoin. O caminho de ida é o 06-instalar-patroni.sh — dá para alternar quantas vezes quiser.
#
#   1. switchover para o pg-lab-1 (os scripts 02/05 assumem que ele é o primário)
#   2. para e desabilita o Patroni (standbys primeiro) — isso também para o PostgreSQL — e o etcd;
#      apaga os dados do etcd, para o 06 formar um cluster novo e limpo
#   3. devolve a configuração: o Patroni renomeou o postgresql.conf para postgresql.base.conf
#   4. religa o postgresql.service no pg-lab-1 e apaga os slots de replicação do Patroni (sem
#      consumidor, eles reteriam WAL até encher o disco)
#   5. refaz a replicação (02, reclona os standbys) e religa o pg-autorejoin (05)
#
# Ficam instalados (inertes): binários do etcd, venv /opt/patroni e /etc/patroni.
# O painel religa o failover dele sozinho ~60 s depois que o Patroni para de responder.
# Interrompe as gravações por ~1–2 min. Pare a carga no painel e retome VMs pausadas antes.
set -euo pipefail
cd "$(dirname "$0")/.."
FIRST_IP=${FIRST_IP:-123}
IPS=("192.168.5.$FIRST_IP" "192.168.5.$((FIRST_IP + 1))" "192.168.5.$((FIRST_IP + 2))")
NAMES=(pg-lab-1 pg-lab-2 pg-lab-3)
PGD=/var/lib/pgsql/data
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
rsh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "cloud-user@$ip" "$@"; }
ctl() { rsh "${IPS[0]}" "sudo -u postgres /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml $*"; }

echo "== 0/5 pré-voo"
for ip in "${IPS[@]}"; do rsh "$ip" true || { echo "$ip inacessível (VM pausada?)"; exit 1; }; done
for ip in "${IPS[@]}"; do
  rsh "$ip" "systemctl is-active -q patroni" || { echo "Patroni não está ativo em $ip — nada a remover (ou estado misto: confira à mão)"; exit 1; }
done
ctl list

echo "== 1/5 líder no pg-lab-1"
if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://${IPS[0]}:8008/primary")" != 200 ]; then
  ctl "switchover --candidate pg-lab-1 --force"
  for _ in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://${IPS[0]}:8008/primary")" = 200 ] && break; sleep 2; done
fi
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://${IPS[0]}:8008/primary")" = 200 ] || { echo "pg-lab-1 não virou líder"; exit 1; }
echo "  pg-lab-1 é o líder"

echo "== 2/5 Patroni e etcd fora (standbys primeiro)"
for ip in "${IPS[2]}" "${IPS[1]}" "${IPS[0]}"; do rsh "$ip" "sudo systemctl disable -q --now patroni"; done
for ip in "${IPS[@]}"; do
  rsh "$ip" "sudo -u postgres pg_ctl -D $PGD status >/dev/null 2>&1 && { echo 'PostgreSQL ainda de pé em $ip'; exit 1; } || true"
done
for ip in "${IPS[@]}"; do rsh "$ip" "sudo systemctl disable -q --now etcd && sudo find /var/lib/etcd -mindepth 1 -delete"; done

echo "== 3/5 configuração original de volta"
for ip in "${IPS[@]}"; do
  rsh "$ip" "sudo -u postgres bash -c 'cd $PGD && [ -f postgresql.base.conf ] && mv -f postgresql.base.conf postgresql.conf; rm -f patroni.dynamic.json *.conf.backup'"
done
rsh "${IPS[0]}" "sudo -u postgres rm -f $PGD/standby.signal $PGD/recovery.signal"
# o 06 desabilitou o serviço; o 02 só dá start — sem enable, os standbys não voltariam num reboot
for ip in "${IPS[@]}"; do rsh "$ip" "sudo systemctl enable -q postgresql"; done

echo "== 4/5 PostgreSQL do systemd no pg-lab-1; slots do Patroni apagados"
rsh "${IPS[0]}" "sudo systemctl start postgresql"
for _ in $(seq 1 15); do [ "$(rsh "${IPS[0]}" "sudo -u postgres psql -XAtqc 'select pg_is_in_recovery()'" 2>/dev/null)" = f ] && break; sleep 2; done
[ "$(rsh "${IPS[0]}" "sudo -u postgres psql -XAtqc 'select pg_is_in_recovery()'")" = f ] || { echo "pg-lab-1 não subiu como primário"; exit 1; }
rsh "${IPS[0]}" "sudo -u postgres psql -XAtqc \"select pg_drop_replication_slot(slot_name) from pg_replication_slots where not active\"" >/dev/null
echo "  slots restantes: $(rsh "${IPS[0]}" "sudo -u postgres psql -XAtqc 'select count(*) from pg_replication_slots'")"

echo "== 5/5 replicação (02) e pg-autorejoin (05)"
./lab/02-configurar-replicacao.sh
./lab/05-instalar-autorejoin.sh
echo "pronto: modo sem Patroni. O painel religa o failover dele em ~60 s. Para voltar ao Patroni: ./lab/06-instalar-patroni.sh"
