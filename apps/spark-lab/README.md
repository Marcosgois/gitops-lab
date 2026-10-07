# spark-lab — Spark SQL em s390x lendo e gravando Parquet no S3

Prova de viabilidade de **processamento desacoplado do armazenamento** no OpenShift do LinuxONE:
**Spark SQL** em pods s390x lendo e gravando **Parquet (SNAPPY e ZSTD) num S3** — no lab, o Ceph RGW do
próprio cluster. Só **dado sintético**. Criado em 07/10/2026.

**Por que Spark e não Trino:** o Trino (e o Presto) **não roda em s390x**. O código recusa a arquitetura
e exige processador little-endian em todas as versões, da 360 à 484. Testado: o Trino 483 com Java 25
encerra com `Trino requires amd64, aarch64, or ppc64le on Linux (found s390x)`. O Spark é a alternativa com
receita de build oficial da IBM para Linux on Z (Spark 4.0.1).

## Resultado (07/10/2026)

| Teste | Resultado |
| :--- | :--- |
| Imagem | **Não existe imagem oficial s390x** (`apache/spark` só tem amd64 e arm64). Construída no cluster: tarball oficial do Spark 4.0.1 (**sha512 conferido**) + `hadoop-aws` 3.4.1 + AWS SDK 2.24.6, sobre o OpenJDK 21 da UBI 9. A JVM roda em `s390x`, **big-endian** |
| Codecs nativos | `snappy-java` 1.1.10.7, `zstd-jni` 1.5.6-9 e `lz4-java` 1.8.0 da imagem trazem `.so` para Linux s390x |
| 1 pod (`local[8]`), 20 milhões de linhas | Gravou e releu Parquet **SNAPPY e ZSTD** no S3. O resumo (contagem, somas exatas, distintos, datas, tamanho de texto, soma de `double`) **bateu exatamente** com o dado gerado |
| Distribuído: driver + **3 executores em pods**, 100 milhões de linhas | O mesmo teste, **tudo confere**. Gravação de 100 milhões de linhas: 47,7 s (SNAPPY) e 24,6 s (ZSTD); reler e resumir: 8,9 s e 6,2 s |
| **Arquivos entre arquiteturas, little-endian → s390x** | O Spark em s390x leu Parquet gravado pelo `pyarrow` num ARM little-endian, com as mesmas fórmulas, e **confere** |
| **Arquivos entre arquiteturas, s390x → little-endian** | O `pyarrow` no ARM leu o Parquet gravado pelo Spark em s390x (`parquet-mr 1.15.2`) e conferiu contra as fórmulas calculadas lá, **sem Spark**. Confere |

Os tempos valem só para este laboratório: os executores ficaram todos no mesmo worker, o S3 é o Ceph do
próprio cluster e o dado é sintético. **Não servem de comparação** com outro cluster.

## Arquivos

```
apps/spark-lab/
├── 10-s3-e-imagem.yaml        ObjectBucketClaim `dados` (Ceph RGW) + ImageStream + BuildConfig da imagem s390x
├── 20-job-teste.yaml          Job: Spark em 1 pod (local[8])
├── 30-job-distribuido.yaml    ServiceAccount/Role + Job: driver que cria 3 executores como pods
├── 40-console-demo.yaml       pod `spark-console` + init.scala (tabela `vendas`, `q`, `gravar`) + template que espalha os executores
├── console.sh                 abre o spark-shell da demo (3 executores; --local = plano B)
├── espiar.sh                  lado do Mac: abre no S3 o que o s390x gravou (credenciais tiradas do cluster)
├── teste-parquet-s3.scala     o teste (grava, relê, confere; lê os arquivos little-endian; 2 consultas)
└── cruzado_little_endian.py   o lado x86/ARM: grava os arquivos little-endian e confere os do s390x
```

## Rodar

```bash
export KUBECONFIG=~/.kube/lone.kubeconfig
cd gitops-lab/apps/spark-lab
oc new-project spark-lab
oc apply -n spark-lab -f 10-s3-e-imagem.yaml
oc start-build spark-s390x -n spark-lab --follow          # ~5 min

# (opcional) arquivos little-endian, numa máquina x86/ARM com pyarrow e numpy:
export AWS_ACCESS_KEY_ID=$(oc get secret dados -n spark-lab -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(oc get secret dados -n spark-lab -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
export BUCKET_NAME=$(oc get cm dados -n spark-lab -o jsonpath='{.data.BUCKET_NAME}')
export S3_ENDPOINT=http://$(oc get route ocs-storagecluster-cephobjectstore -n openshift-storage -o jsonpath='{.spec.host}')
python3 cruzado_little_endian.py gravar 5000000

oc create configmap teste-parquet-s3 -n spark-lab --from-file=teste-parquet-s3.scala --dry-run=client -o yaml | oc apply -f -
oc apply -n spark-lab -f 20-job-teste.yaml                # 1 pod
oc apply -n spark-lab -f 30-job-distribuido.yaml          # driver + 3 executores
oc logs -n spark-lab -f job/teste-distribuido | grep '###'

python3 cruzado_little_endian.py ler 20000000             # confere, em little-endian, o que o s390x gravou
```

Para limpar: `oc delete project spark-lab` (o bucket some junto com o ObjectBucketClaim).

## Roteiro da demo (~8 min)

Ensaiado em 07/10/2026: os 3 executores subiram um em cada worker, as consultas sobre 100 milhões de linhas
levaram ~3 s e a gravação ~9 s. A leitura no Mac é instantânea.

### Antes (15 min antes, sem plateia)

```bash
export KUBECONFIG=~/.kube/lone.kubeconfig
cd gitops-lab/apps/spark-lab
oc get pod spark-console -n spark-lab          # Running; se não existir: oc apply -n spark-lab -f 40-console-demo.yaml
./console.sh                                   # ensaio: espere o banner com "executores: 3", depois :quit
./espiar.sh demo/faturamento_mensal            # o Mac lê o S3 do lab (precisa de ~/.venvs/spark-lab, ver abaixo)
```

- **Terminal 2**, deixado aberto: `oc get pods -n spark-lab -l spark-role=executor -o wide -w`, onde os executores aparecem e somem ao vivo.
- **Console do OpenShift:** projeto `spark-lab`, em *Workloads → Pods* ou *Topology*.
- Num slide, a mensagem de erro do Trino: `Trino requires amd64, aarch64, or ppc64le on Linux (found s390x)`.
- Ambiente Python do Mac, só uma vez: `python3 -m venv ~/.venvs/spark-lab && ~/.venvs/spark-lab/bin/pip install pyarrow numpy`.

### Passo a passo

1. **O ponto de partida (1 min).** Slide com o erro do Trino.
   **Diga:** "Testamos o Trino no LinuxONE: ele recusa a arquitetura em todas as versões e ainda exige
   processador little-endian. O que vocês querem não é o Trino em si, é **separar processamento e
   armazenamento**. Então trocamos o motor e mantivemos o dado."
2. **A imagem (1 min).** `oc get istag -n spark-lab` e `oc get builds -n spark-lab`.
   **Diga:** "Não existe imagem oficial do Spark para s390x. Construímos no próprio cluster, a partir do
   pacote oficial da Apache com o checksum conferido, sobre o Java da Red Hat. É a mesma versão que a IBM
   documenta para Linux on Z."
3. **Abrir o console (1 min).** `./console.sh`. No terminal 2 aparecem **3 executores, um em cada
   servidor**. O banner mostra `s390x (BIG_ENDIAN)`.
   **Diga:** "O Spark pede os executores à API do OpenShift, como faria num cluster x86. Cada um é um pod
   num nó diferente."
4. **Consultas (2 min).** Cole uma de cada vez:
   ```scala
   q("select count(*) linhas, sum(valor) total from vendas")
   q("select cliente, sum(valor) total from vendas where data between date'2021-01-01' and date'2021-12-31' group by cliente order by total desc limit 5")
   q("select date_trunc('month', data) mes, sum(valor) total from vendas group by 1 order by 1")
   ```
   **Diga:** "São 100 milhões de linhas em Parquet comprimido, lidas direto do S3. Nada foi copiado para o
   cluster antes."
5. **Gravar um resultado (1 min).**
   ```scala
   gravar("select date_trunc('month', data) mes, count(*) vendas, sum(valor) total from vendas group by 1 order by 1", "faturamento_ao_vivo")
   ```
6. **A prova cruzada (1 min).** No Mac: `./espiar.sh demo/faturamento_ao_vivo`. A saída mostra
   `arm64, byteorder=little` e `gravado por: parquet-mr`, com as mesmas linhas.
   **Diga:** "O arquivo que o LinuxONE acabou de gravar, em big-endian, foi lido aqui, numa máquina
   little-endian, sem conversão. Conferimos os dois sentidos com 100 milhões de linhas. O mesmo Parquet
   serve ao Trino x86 que vocês já têm e ao Spark no Z: dá para mover o processamento sem mover nem
   converter o dado."
7. **Encerrar (30 s).** `:quit`. Os executores somem no terminal 2.
   **Diga:** "Os recursos só existem durante o trabalho; depois voltam para o cluster."

### Se algo der errado

| Sintoma | O que fazer |
| :--- | :--- |
| Banner com `executores: 0`, ou o console demora mais de 2 min | No terminal 2, procure executor em `Pending`: falta CPU ou memória, ou a cota do projeto (`oc describe quota -n spark-lab`). Saia e rode `./console.sh --local`, que roda tudo no pod do console, só mais devagar |
| `AccessDenied` ou `UnknownHost` no S3 | `oc get obc dados -n spark-lab` precisa estar `Bound`; `oc get pods -n openshift-storage \| grep rgw`, com o RGW `Running` |
| `./espiar.sh` falha | VPN ou o kubeconfig. Mostre o print do ensaio e siga |
| O pod `spark-console` sumiu | `oc apply -n spark-lab -f 40-console-demo.yaml`, ~30 s |

### Perguntas prováveis

- **"É suportado em produção?"** O Spark funciona e tem receita de build da IBM para s390x, mas não há
  imagem oficial. A imagem foi montada por nós. O caminho de suporte é uma conversa com a IBM e a Red Hat.
- **"Quanto mais rápido que o nosso Trino?"** Não dá para comparar com este teste: dado sintético, S3 no
  próprio cluster. Para comparar de verdade, precisamos de 3 a 5 consultas de vocês e do formato dos dados.
- **"E o catálogo, o Hive Metastore?"** O teste usa caminho direto no S3. O próximo passo é o Iceberg com
  catálogo JDBC num PostgreSQL. O Hive, a própria IBM avisa, tem problemas com big-endian.
- **"Dá para manter o Trino?"** Sim: o Spark no Z faz o processamento pesado, o Trino x86 continua nas
  consultas interativas, e os dois leem o mesmo Parquet.

## Pegadinhas encontradas

- **`spark-shell -i script` num Job sai sem rodar** o script, porque não há terminal e ele lê o fim da
  entrada antes. Use `spark-shell < script`.
- **No REPL, um erro aborta só a instrução** em que ocorreu e o resto segue. O teste chegou a terminar
  "verde" com o S3 falhando. Por isso o teste roda num único `try` que sai com código ≠ 0.
- **Hadoop 3.4 usa o AWS SDK v2.** A classe antiga `org.apache.hadoop.fs.s3a.auth.EnvironmentVariableCredentialsProvider`
  não existe mais. Deixe a cadeia padrão do S3A, que já lê `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`.
- **Use o endpoint HTTP interno** do RGW (`...svc:80`). O `BUCKET_PORT` do ObjectBucketClaim é 443, com
  certificado da CA de serviço do cluster, que a JVM não reconhece por padrão.
- **`catalogImplementation=in-memory`:** sem Hive. A própria receita da IBM avisa que o Hive não suporta
  totalmente big-endian.
- O `entrypoint.sh` do Spark chama `tini`, que a UBI não tem. A imagem remove a chamada.

## Próximos passos (não feitos)

- **Catálogo de tabelas** sem Hive Metastore: Iceberg com catálogo JDBC no PostgreSQL do `pg-ha-demo`.
- **Consultas reais do cliente:** só elas permitem uma comparação que faça sentido.
- Espalhar os executores pelos workers (anti-afinidade em *pod template*) e medir com mais dados.
