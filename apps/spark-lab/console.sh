#!/usr/bin/env bash
# Abre o spark-shell da demo dentro do pod spark-console, com EXECUTORES pods de executor no cluster.
# Ao sair (:quit), os executores são apagados sozinhos. Cada sessão tem nomes de executor e portas
# próprios, então duas sessões abertas ao mesmo tempo não colidem (mas dividem a cota do projeto).
#
#   ./console.sh            # 3 executores
#   EXECUTORES=2 ./console.sh
#   ./console.sh --local    # plano B: sem executores, tudo no pod do console
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/lone.kubeconfig}
NS=spark-lab
IMG=image-registry.openshift-image-registry.svc:5000/spark-lab/spark-s390x:4.0.1
S3="--conf spark.hadoop.fs.s3a.endpoint=http://rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc:80
    --conf spark.hadoop.fs.s3a.endpoint.region=us-east-1 --conf spark.hadoop.fs.s3a.path.style.access=true
    --conf spark.hadoop.fs.s3a.connection.ssl.enabled=false"
COMUM="--conf spark.ui.enabled=false --conf spark.sql.catalogImplementation=in-memory $S3"

if [[ "${1:-}" == "--local" ]]; then
  MODO="--master local[2] --driver-memory 4g"
else
  MODO="--master k8s://https://kubernetes.default.svc:443 --deploy-mode client --driver-memory 4g
    --conf spark.driver.host=\$POD_IP
    --conf spark.kubernetes.namespace=$NS --conf spark.kubernetes.container.image=$IMG
    --conf spark.kubernetes.authenticate.driver.serviceAccountName=spark
    --conf spark.kubernetes.executor.podNamePrefix=demo-$(date +%H%M%S)
    --conf spark.kubernetes.executor.podTemplateFile=/demo/executor-template.yaml
    --conf spark.executor.instances=${EXECUTORES:-3} --conf spark.executor.cores=4 --conf spark.executor.memory=6g
    --conf spark.kubernetes.executor.request.cores=2 --conf spark.kubernetes.executor.limit.cores=4
    --conf spark.kubernetes.executor.secretKeyRef.AWS_ACCESS_KEY_ID=dados:AWS_ACCESS_KEY_ID
    --conf spark.kubernetes.executor.secretKeyRef.AWS_SECRET_ACCESS_KEY=dados:AWS_SECRET_ACCESS_KEY
    --conf spark.scheduler.minRegisteredResourcesRatio=1.0 --conf spark.scheduler.maxRegisteredResourcesWaitingTime=120s"
fi

oc wait -n $NS --for=condition=Ready pod/spark-console --timeout=120s >/dev/null
# Uma sessão por vez: o pod tem limite de 6 GiB e cada spark-shell reserva 4 GiB de heap
if oc exec -n $NS spark-console -- pgrep -f org.apache.spark.repl.Main >/dev/null 2>&1; then
  echo "Já existe uma sessão do spark-shell aberta no spark-console. Feche-a (:quit) antes de abrir outra." >&2
  exit 1
fi
# -t só com terminal de verdade (o ensaio automático passa os comandos pela entrada padrão)
TTY=$([[ -t 0 ]] && echo "-it" || echo "-i")
# O REPL do Spark 4 (Scala 2.13) ignora -i e -I sem avisar. Por isso o init.scala entra como primeiro
# comando (:load) e depois o `cat` repassa o que for digitado. Sem histórico nem Tab, mas colar e Enter
# funcionam. Saia com :quit ou Ctrl-D.
oc exec $TTY -n $NS spark-console -- bash -c "(echo ':load /demo/init.scala'; cat) | /opt/spark/bin/spark-shell $(echo $MODO $COMUM) 2> >(grep -v -E 'WARN|incubator|jline|SLF4J' >&2)"
