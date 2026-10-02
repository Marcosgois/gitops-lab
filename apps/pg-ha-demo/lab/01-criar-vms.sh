#!/usr/bin/env bash
# Cria pg-lab-1/2/3 no namespace demos a partir da imagem gold `databases-gold`
# (CentOS Stream 9, PostgreSQL 16.8), na rede localnet `demos/rede-lab`.
#
# Executado no lone em 02/10/2026.
# Pré-requisitos: VPN do lab ligada, `oc` logado no cluster lone, chave SSH pública.
#
#   SSH_PUBKEY=~/.ssh/id_ed25519.pub ./lab/01-criar-vms.sh            # cria
#   DRY_RUN=1 ./lab/01-criar-vms.sh                                    # só mostra os YAMLs
set -euo pipefail

NS=${NS:-demos}
FIRST_IP=${FIRST_IP:-123}            # .123, .124, .125 (faixa de VMs .100–.139; Mongo usa .120–.122)
NET=${NET:-demos/rede-lab}
DS=${DS:-databases-gold}
DS_NS=openshift-virtualization-os-images
INSTANCETYPE=${INSTANCETYPE:-o1.large}   # 2 vCPU/8 GiB como o Mongo, mas reserva 4 GiB: as 3 cabem na cota do ns demos (48 GiB)
DISK=${DISK:-30Gi}
SC=${SC:-ocs-storagecluster-ceph-rbd-virtualization}
SSH_PUBKEY=${SSH_PUBKEY:-$(ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -1)}
DRY_RUN=${DRY_RUN:-0}

[ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ] || { echo "defina SSH_PUBKEY (arquivo .pub)"; exit 1; }
KEY=$(cat "$SSH_PUBKEY")

echo "== pré-voo"
oc whoami >/dev/null || { echo "oc sem login — ligue a VPN e faça oc login no lone"; exit 1; }
oc get datasource "$DS" -n "$DS_NS" >/dev/null || { echo "DataSource $DS não existe em $DS_NS"; exit 1; }
PREF=${PREF:-$(oc get datasource "$DS" -n "$DS_NS" -o jsonpath='{.metadata.labels.instancetype\.kubevirt\.io/default-preference}')}
[ -n "$PREF" ] || { echo "sem preference no rótulo do DataSource; defina PREF=..."; exit 1; }
echo "preference: $PREF   instancetype: $INSTANCETYPE"
oc get net-attach-def "${NET#*/}" -n "${NET%/*}" >/dev/null || { echo "NAD $NET não encontrada"; exit 1; }
oc get cephcluster -n openshift-storage -o jsonpath='{range .items[*]}ceph: {.status.ceph.health}{"\n"}{end}' 2>/dev/null || true

for i in 1 2 3; do
  ip=$((FIRST_IP + i - 1)); name=pg-lab-$i; mac=$(printf '02:00:00:00:05:%02x' "$ip")
  if oc get vm "$name" -n "$NS" >/dev/null 2>&1; then echo "$name já existe — pulando"; continue; fi
  if [ "$DRY_RUN" != 1 ] && ping -c1 -W1 "192.168.5.$ip" >/dev/null 2>&1; then
    echo "192.168.5.$ip já responde a ping — escolha outro FIRST_IP"; exit 1
  fi
  yaml=$(cat <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $name
  namespace: $NS
  labels: {app.kubernetes.io/part-of: pg-ha-demo, app: pg-lab}
spec:
  runStrategy: Always
  instancetype: {kind: VirtualMachineClusterInstancetype, name: $INSTANCETYPE}
  preference: {kind: VirtualMachineClusterPreference, name: $PREF}
  dataVolumeTemplates:
  - metadata: {name: $name-root}
    spec:
      sourceRef: {kind: DataSource, name: $DS, namespace: $DS_NS}
      storage:
        resources: {requests: {storage: $DISK}}
        storageClassName: $SC
  template:
    metadata:
      labels: {app: pg-lab, vm: $name}
    spec:
      # uma VM por worker: derrubar um nó físico tira só um membro do cluster
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector: {matchLabels: {app: pg-lab}}
              topologyKey: kubernetes.io/hostname
      domain:
        devices:
          interfaces: [{name: lab, bridge: {}, macAddress: "$mac"}]
      networks: [{name: lab, multus: {networkName: $NET}}]
      volumes:
      - {name: rootdisk, dataVolume: {name: $name-root}}
      - name: cloudinitdisk
        cloudInitNoCloud:
          networkData: |
            version: 2
            ethernets:
              lab0:
                match: {macaddress: "$mac"}
                set-name: lab0
                addresses: [192.168.5.$ip/24]
                gateway4: 192.168.5.1
                nameservers: {addresses: [192.168.5.1], search: [lone.sp1.tdsnxcoe.com]}
          userData: |
            #cloud-config
            user: cloud-user
            ssh_authorized_keys:
              - $KEY
EOF
)
  if [ "$DRY_RUN" = 1 ]; then echo "---"; echo "$yaml"; else echo "$yaml" | oc apply -f -; fi
done

[ "$DRY_RUN" = 1 ] && exit 0
echo "== aguardando as VMs"
for i in 1 2 3; do
  oc wait --for=condition=Ready "vmi/pg-lab-$i" -n "$NS" --timeout=180s
done
for i in 1 2 3; do
  ip=$((FIRST_IP + i - 1))
  for t in $(seq 1 40); do ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "cloud-user@192.168.5.$ip" true 2>/dev/null && break; sleep 3; done
  echo "pg-lab-$i  192.168.5.$ip  ssh ok"
done
echo "Próximo: ./lab/00-gerar-credenciais.sh && ./lab/02-configurar-replicacao.sh"
