#!/usr/bin/env bash
# Instala o pg-autorejoin nas 3 VMs: o antigo primário volta sozinho ao pool como standby
# (pg_rewind), como o MongoDB faz. Rode depois do 02-configurar-replicacao.sh.
#
# Para desligar (voltar à reintegração manual com 04-reintegrar-no.sh), em cada VM:
#   sudo systemctl disable --now pg-autorejoin
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt
FIRST_IP=${FIRST_IP:-123}
IPS=("192.168.5.$FIRST_IP" "192.168.5.$((FIRST_IP + 1))" "192.168.5.$((FIRST_IP + 2))")
NAMES=(pg-lab-1 pg-lab-2 pg-lab-3)
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
rsh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "cloud-user@$ip" "$@"; }

# pg_rewind lê arquivos do primário pela conexão: o replicator precisa destas funções, no banco
# que ele usa (postgres). Roda no primário atual; a permissão replica para os standbys.
PRIMARY=""
for ip in "${IPS[@]}"; do
  [ "$(rsh "$ip" "sudo -u postgres psql -XAtqc 'select pg_is_in_recovery()'" 2>/dev/null)" = f ] && { PRIMARY=$ip; break; }
done
[ -n "$PRIMARY" ] || { echo "nenhum primário encontrado"; exit 1; }
echo "== permissões do pg_rewind para o replicator (primário $PRIMARY)"
rsh "$PRIMARY" "sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q -d postgres" <<'SQL'
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
SQL

for i in 0 1 2; do
  ip=${IPS[$i]}; nm=${NAMES[$i]}
  echo "== $nm ($ip)"
  rsh "$ip" true 2>/dev/null || { echo "   inacessível (VM pausada?) — rode este script de novo depois"; continue; }
  rsh "$ip" "sudo tee /usr/local/sbin/pg-autorejoin >/dev/null && sudo chmod 755 /usr/local/sbin/pg-autorejoin" < lab/pg-autorejoin.sh
  rsh "$ip" "printf 'SELF_NAME=%s\nSELF_IP=%s\nPEERS=\"%s\"\n' '$nm' '$ip' '${IPS[*]}' | sudo tee /etc/pg-autorejoin.conf >/dev/null"
  # senha só por stdin; .pgpass do usuário postgres (o walreceiver também usa)
  printf '*:5432:*:replicator:%s\n' "$PG_REPL_PASSWORD" | rsh "$ip" "sudo -u postgres tee /var/lib/pgsql/.pgpass >/dev/null && sudo chmod 600 /var/lib/pgsql/.pgpass"
  rsh "$ip" "sudo tee /etc/systemd/system/pg-autorejoin.service >/dev/null" <<'UNIT'
[Unit]
Description=Reintegra o antigo primário do PostgreSQL como standby (pg_rewind)
After=postgresql.service network-online.target

[Service]
ExecStart=/usr/local/sbin/pg-autorejoin
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  rsh "$ip" "sudo systemctl daemon-reload && sudo systemctl enable --now pg-autorejoin && systemctl is-active pg-autorejoin"
done
echo "pronto. Log: journalctl -u pg-autorejoin -f (em qualquer VM)"
