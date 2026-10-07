#!/usr/bin/env bash
# Lado little-endian da demo (Mac x86/ARM): abre o que o Spark em s390x gravou no S3 do lab.
#   ./espiar.sh demo/faturamento_mensal       # mostra quem gravou, compressão e as primeiras linhas
#   ./espiar.sh ler 20000000                  # conferência completa de de_s390x/ (lenta pela VPN)
# Requer: VPN, kubeconfig do lone e um Python com pyarrow+numpy (padrão: ~/.venvs/spark-lab).
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/lone.kubeconfig}
PY=${PY:-$HOME/.venvs/spark-lab/bin/python}
export AWS_ACCESS_KEY_ID=$(oc get secret dados -n spark-lab -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(oc get secret dados -n spark-lab -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
export BUCKET_NAME=$(oc get cm dados -n spark-lab -o jsonpath='{.data.BUCKET_NAME}')
export S3_ENDPOINT=http://$(oc get route ocs-storagecluster-cephobjectstore -n openshift-storage -o jsonpath='{.spec.host}')
cd "$(dirname "$0")"
if [[ "${1:-}" == ler || "${1:-}" == gravar ]]; then exec "$PY" cruzado_little_endian.py "$@"; fi
exec "$PY" cruzado_little_endian.py espiar "${1:-demo/faturamento_mensal}"
