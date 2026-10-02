#!/usr/bin/env bash
# Passa o cluster pg-lab-1/2/3 para o Patroni, com etcd nas próprias 3 VMs.
#
# Depois disso quem elege o primário e reintegra o antigo é o Patroni: o painel suspende o failover
# dele sozinho ao detectar o Patroni (API :8008) e o pg-autorejoin é desligado.
# Para voltar ao modo sem Patroni: 07-remover-patroni.sh.
#
# O que muda na demo: com o etcd nas mesmas VMs, pausar 2 das 3 derruba o quórum do etcd e o
# Patroni REBAIXA o primário isolado — ele para de gravar mesmo em assíncrono. É a proteção
# contra dois primários; o cenário de "perdidas" do assíncrono quase some.
#
# Verificado em 02/10/2026 (CentOS Stream 9 s390x): não há pacote de Patroni nem de etcd no
# CentOS nem no EPEL. etcd = binário oficial s390x do GitHub (sha256 conferido); Patroni = pip
# num venv que usa psutil/psycopg2/libpq dos pacotes do CentOS (o PyPI não tem psutil s390x).
#
# Interrompe as gravações por ~1 min (o PostgreSQL é parado e o Patroni o religa). Pare a carga
# no painel e retome VMs pausadas antes de rodar.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source CREDENCIAIS-pg-lab.txt
FIRST_IP=${FIRST_IP:-123}
IPS=("192.168.5.$FIRST_IP" "192.168.5.$((FIRST_IP + 1))" "192.168.5.$((FIRST_IP + 2))")
NAMES=(pg-lab-1 pg-lab-2 pg-lab-3)
ETCD_VER=${ETCD_VER:-v3.7.2}
PATRONI_VER=${PATRONI_VER:-4.1.5}
# failover em ~ttl. Mínimo do Patroni: ttl 20 (por isso o RTO fica acima dos ~6 s do failover do
# painel). Regra: loop_wait + 2*retry_timeout <= ttl
TTL=${TTL:-20}; LOOP_WAIT=${LOOP_WAIT:-2}; RETRY_TIMEOUT=${RETRY_TIMEOUT:-5}
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
rsh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "cloud-user@$ip" "$@"; }
ETCD_CLUSTER=""; ETCD_HOSTS=""
for i in 0 1 2; do
  ETCD_CLUSTER+="${ETCD_CLUSTER:+,}${NAMES[$i]}=http://${IPS[$i]}:2380"
  ETCD_HOSTS+="${ETCD_HOSTS:+,}${IPS[$i]}:2379"
done

echo "== 0/6 pré-voo"
for ip in "${IPS[@]}"; do rsh "$ip" true || { echo "$ip inacessível (VM pausada?)"; exit 1; }; done
PRIMARY=""; PRIMARY_NAME=""
for i in 0 1 2; do
  [ "$(rsh "${IPS[$i]}" "sudo -u postgres psql -XAtqc 'select pg_is_in_recovery()'" 2>/dev/null)" = f ] && { PRIMARY=${IPS[$i]}; PRIMARY_NAME=${NAMES[$i]}; }
done
[ -n "$PRIMARY" ] || { echo "nenhum primário encontrado"; exit 1; }
echo "primário atual: $PRIMARY_NAME ($PRIMARY)"
if rsh "$PRIMARY" "systemctl is-active -q patroni" 2>/dev/null; then echo "Patroni já está ativo — nada a fazer"; exit 0; fi

echo "== 1/6 pacotes do CentOS (psutil, psycopg2, libpq)"
for ip in "${IPS[@]}"; do rsh "$ip" "sudo dnf -y -q install python3-psutil python3-psycopg2 libpq >/dev/null && echo \"  $ip ok\""; done

echo "== 2/6 etcd $ETCD_VER (binário oficial s390x, sha256 conferido)"
for i in 0 1 2; do
  ip=${IPS[$i]}; nm=${NAMES[$i]}
  rsh "$ip" "set -e; cd /tmp; f=etcd-$ETCD_VER-linux-s390x.tar.gz
    curl -sSLO https://github.com/etcd-io/etcd/releases/download/$ETCD_VER/\$f
    curl -sSL https://github.com/etcd-io/etcd/releases/download/$ETCD_VER/SHA256SUMS | grep \" \$f\$\" | sha256sum -c --quiet
    tar xzf \$f; sudo install -m 755 etcd-$ETCD_VER-linux-s390x/etcd etcd-$ETCD_VER-linux-s390x/etcdctl /usr/local/bin/
    rm -rf \$f etcd-$ETCD_VER-linux-s390x
    id etcd >/dev/null 2>&1 || sudo useradd -r -s /sbin/nologin -d /var/lib/etcd etcd
    sudo install -d -o etcd -g etcd -m 700 /var/lib/etcd"
  rsh "$ip" "sudo tee /etc/systemd/system/etcd.service >/dev/null" <<UNIT
[Unit]
Description=etcd ($nm) — guarda o líder do Patroni
After=network-online.target
Wants=network-online.target

[Service]
User=etcd
ExecStart=/usr/local/bin/etcd --name $nm --data-dir /var/lib/etcd \\
  --listen-client-urls http://$ip:2379,http://127.0.0.1:2379 --advertise-client-urls http://$ip:2379 \\
  --listen-peer-urls http://$ip:2380 --initial-advertise-peer-urls http://$ip:2380 \\
  --initial-cluster $ETCD_CLUSTER --initial-cluster-state new --initial-cluster-token pg-lab
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
done
# os três sobem juntos (cada um espera os pares para formar o cluster)
for ip in "${IPS[@]}"; do rsh "$ip" "sudo systemctl daemon-reload && sudo systemctl enable -q etcd && sudo systemctl start --no-block etcd"; done
for _ in $(seq 1 30); do rsh "$PRIMARY" "etcdctl --endpoints=$ETCD_HOSTS endpoint health" >/dev/null 2>&1 && break; sleep 2; done
rsh "$PRIMARY" "etcdctl --endpoints=$ETCD_HOSTS endpoint health"

echo "== 3/6 Patroni $PATRONI_VER em /opt/patroni"
for ip in "${IPS[@]}"; do
  rsh "$ip" "sudo python3 -m venv --system-site-packages /opt/patroni && sudo /opt/patroni/bin/pip install -q -U pip && sudo /opt/patroni/bin/pip install -q 'patroni[etcd3]==$PATRONI_VER' && /opt/patroni/bin/patroni --version"
done

echo "== 4/6 configuração (/etc/patroni/patroni.yml, só o postgres lê — tem a senha do replicator)"
for i in 0 1 2; do
  ip=${IPS[$i]}; nm=${NAMES[$i]}
  rsh "$ip" "sudo install -d -o postgres -g postgres -m 700 /etc/patroni && sudo -u postgres tee /etc/patroni/patroni.yml >/dev/null && sudo chmod 600 /etc/patroni/patroni.yml" <<YML
scope: pg-lab
name: $nm
restapi:
  listen: $ip:8008
  connect_address: $ip:8008
etcd3:
  hosts: $ETCD_HOSTS
bootstrap:
  dcs:
    ttl: $TTL
    loop_wait: $LOOP_WAIT
    retry_timeout: $RETRY_TIMEOUT
    maximum_lag_on_failover: 1048576
    # quórum como antes: COMMIT confirma com 1 standby (2 das 3 cópias); strict = sem standby, não grava
    synchronous_mode: quorum
    synchronous_node_count: 1
    synchronous_mode_strict: true
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        wal_log_hints: 'on'
        wal_sender_timeout: 5s
        wal_receiver_timeout: 5s
        synchronous_commit: 'on'
postgresql:
  listen: $ip,127.0.0.1:5432
  connect_address: $ip:5432
  data_dir: /var/lib/pgsql/data
  bin_dir: /usr/bin
  pgpass: /var/lib/pgsql/.pgpass-patroni
  use_unix_socket: true
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      password: '$PG_REPL_PASSWORD'
    rewind:
      username: replicator
      password: '$PG_REPL_PASSWORD'
YML
  rsh "$ip" "sudo tee /etc/systemd/system/patroni.service >/dev/null" <<'UNIT'
[Unit]
Description=Patroni (PostgreSQL com failover automático)
After=network-online.target etcd.service
Wants=network-online.target

[Service]
User=postgres
Group=postgres
ExecStart=/opt/patroni/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  rsh "$ip" "sudo /opt/patroni/bin/patroni --validate-config --ignore-listen-port /etc/patroni/patroni.yml >/dev/null && echo '  $nm: configuração válida'" || rsh "$ip" "sudo -u postgres /opt/patroni/bin/patroni --validate-config --ignore-listen-port /etc/patroni/patroni.yml"
done

echo "== 5/6 troca: PostgreSQL do systemd sai, Patroni assume (gravações param ~1 min)"
for ip in "${IPS[@]}"; do rsh "$ip" "sudo systemctl disable -q --now pg-autorejoin 2>/dev/null || true"; done
# parâmetros vão para o Patroni: o postgresql.auto.conf (ALTER SYSTEM) passaria por cima dele
rsh "$PRIMARY" "sudo -u postgres psql -XAtqc 'ALTER SYSTEM RESET ALL'" >/dev/null
for i in 0 1 2; do [ "${IPS[$i]}" = "$PRIMARY" ] || rsh "${IPS[$i]}" "sudo systemctl disable -q --now postgresql"; done
rsh "$PRIMARY" "sudo systemctl disable -q --now postgresql"
for i in 0 1 2; do
  [ "${IPS[$i]}" = "$PRIMARY" ] && continue
  rsh "${IPS[$i]}" "echo '# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.' | sudo -u postgres tee /var/lib/pgsql/data/postgresql.auto.conf >/dev/null"
done
rsh "$PRIMARY" "sudo systemctl daemon-reload && sudo systemctl enable -q --now patroni"
for _ in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$PRIMARY:8008/primary")" = 200 ] && break; sleep 2; done
echo "  $PRIMARY_NAME é o líder"
for ip in "${IPS[@]}"; do [ "$ip" = "$PRIMARY" ] || rsh "$ip" "sudo systemctl daemon-reload && sudo systemctl enable -q --now patroni"; done

echo "== 6/6 conferência"
for _ in $(seq 1 40); do
  n=$(rsh "$PRIMARY" "sudo -u postgres psql -XAtqc \"select count(*) from pg_stat_replication where state='streaming'\"" 2>/dev/null || echo 0)
  [ "$n" = 2 ] && break; sleep 3
done
rsh "$PRIMARY" "sudo -u postgres /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list"
rsh "$PRIMARY" "sudo -u postgres psql -XAtqc 'show synchronous_standby_names'"
echo "pronto. O painel detecta o Patroni em ~10 s e suspende o failover dele. Log: journalctl -u patroni -f"
