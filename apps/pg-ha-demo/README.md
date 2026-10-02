# pg-ha-demo — PostgreSQL com 3 réplicas: TPS, perdas e tempo de recuperação

Painel web + gerador de carga para demonstrar **alta disponibilidade de PostgreSQL em 3 VMs** no
OpenShift Virtualization (LinuxONE), do mesmo jeito que o replica set de MongoDB `rs0` já mostrado
no `lone`. Criado em 01/10/2026 depois da apresentação ao time do Binatto (SERPRO).

O painel mostra, ao vivo:

| Indicador | Como é medido |
| :--- | :--- |
| **Transações por segundo** | commits **confirmados** pelo banco por segundo (8 workers por padrão) |
| **Latência p95** | tempo do `INSERT` até a confirmação |
| **Perdidas** | transações que o banco **confirmou** e que **não existem** no primário atual. Depois de cada failover o painel confere, faixa por faixa, o que foi confirmado × o que está na tabela |
| **Tempo de recuperação (RTO)** | do **último commit confirmado antes da falha** ao **primeiro commit confirmado depois** — o que a aplicação sentiu, não o que o Patroni diz |
| Nós | papel (primário/standby/fora), LSN, timeline, atraso de replicação em bytes e tipo (`quorum`) |

Dois modos de confirmação: **síncrona (quórum)** — o `COMMIT` só volta depois de gravado em pelo menos
1 standby (2 das 3 cópias, como o Mongo) — e **assíncrona** — volta ao gravar só no primário.

## Estado: rodando no `lone` desde 02/10/2026

- ✅ **3 VMs no ar** no namespace `demos`, **uma em cada worker** (anti-afinidade), replicação em
  quórum, painel em **https://pg-ha-demo-demos.apps.lone.sp1.tdsnxcoe.com** (VPN do lab).
- ✅ Todos os cenários do `test/e2e.mjs` rodados contra o lab, incluindo a **partição** e a
  **reintegração** (`04-reintegrar-no.sh`) depois de cada failover.

### Números medidos no lab (s390x, 8 workers, VMs `o1.large`)

| Cenário | Modo | TPS em regime | p95 | RTO | Perdidas |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Queda do primário | Síncrona (quórum) | ~1.350–1.500 | ~8 ms | **6,2 s** | **0** |
| Queda do primário | Assíncrona | ~2.000–2.400 | ~5,5 ms | **6,2 s** | **0** *(standbys em dia)* |
| Partição dos standbys + queda do primário | Assíncrona | segue gravando na partição | — | 7,0 s | **15.993** |
| Partição dos standbys + queda do primário | Síncrona (quórum) | **0** durante a partição | — | 12,4 s *(inclui o tempo sem quórum)* | **0** |

Essa tabela é a mensagem da demo: **assíncrono** é mais rápido e continua gravando sem as
réplicas, mas **perde** o que gravou sozinho; **síncrono** custa TPS e **para** sem quórum, mas não
perde nada.

O RTO de ~6,2 s é ~1,5 s de *timeout* de consulta (o app perceber a falha) + 4 s de
`PROMOTE_AFTER_MS` + a promoção. Dá para reduzir com `QUERY_TIMEOUT_MS` e `PROMOTE_AFTER_MS`.

Medição local anterior (Podman no Mac, só para comparação): síncrona ~2.700 TPS, assíncrona
~3.500–4.700 TPS, mesmo RTO.

## Arquivos

```
pg-ha-demo/
├── README.md                  este arquivo
├── src/
│   ├── server.js              gerador de carga, medição, monitor, failover assistido, API
│   ├── public/index.html      o front (TPS, perdas, RTO, nós, histórico)
│   └── package.json           única dependência: pg
├── deploy/                    manifestos do painel — aplicados pelo ArgoCD (Application pg-ha-demo)
│   ├── kustomization.yaml     o que o Argo aplica (Secret e VMs ficam fora do Git)
│   ├── 00-rbac.yaml           ServiceAccount + permissão de pausar/retomar só as VMs pg-lab-*
│   ├── 10-build.yaml          ImageStream + BuildConfig a partir do Git (S2I Node.js 20)
│   └── 20-app.yaml            Deployment (1 réplica) + Service + Route
├── lab/                       passo a passo do laboratório (numerados)
│   ├── 00-gerar-credenciais.sh   senhas aleatórias em CREDENCIAIS-pg-lab.txt
│   ├── 01-criar-vms.sh           cria pg-lab-1/2/3 da imagem gold databases-gold
│   ├── 02-configurar-replicacao.sh  1 primário + 2 standbys, sync em quórum
│   ├── 03-deploy-painel.sh       Secret + Application do Argo; espera o build e o rollout
│   ├── 04-reintegrar-no.sh       reconstrói um nó como standby à mão (reclona inteiro)
│   ├── 05-instalar-autorejoin.sh instala o pg-autorejoin nas 3 VMs
│   └── pg-autorejoin.sh          serviço da VM: antigo primário volta sozinho ao pool (pg_rewind)
└── test/                      ambiente local de teste (Podman)
    ├── local-up.sh / local-down.sh   sobe/derruba 3 PostgreSQL com replicação
    ├── run-app-local.sh              roda o painel contra eles (http://localhost:8080)
    └── e2e.mjs                       teste de ponta a ponta: carga → pausa o primário → mede
```

## O desenho

| VM | IP | MAC | Papel inicial |
| :--- | :--- | :--- | :--- |
| `pg-lab-1` | `192.168.5.123` | `02:00:00:00:05:7b` | primário |
| `pg-lab-2` | `192.168.5.124` | `02:00:00:00:05:7c` | standby |
| `pg-lab-3` | `192.168.5.125` | `02:00:00:00:05:7d` | standby |

- Imagem `databases-gold` (CentOS Stream 9, PostgreSQL 16.8; o MongoDB que vem nela é desligado),
  **`o1.large`** (2 vCPU / 8 GiB, reservando 4 GiB — com `u1.large` a terceira VM estoura a cota de
  48 GiB do namespace), **uma VM por worker** (anti-afinidade), rede `demos/rede-lab`, namespace `demos`. Faixa `.123–.125`: livre na documentação de 25/08 — **reconfirme** (o script
  testa com ping e aborta se o IP já responder). MAC = `02:00:00:00:05:` + IP em hexadecimal.
- **Replicação**: streaming nativo. `synchronous_standby_names = 'ANY 1 ("pg-lab-1","pg-lab-2","pg-lab-3")'`
  em **todos** os nós (lista simétrica, com aspas por causa dos hífens): a gravação confirma com
  primário + 1 standby = 2 das 3, igual ao Mongo.
- **Failover**: o PostgreSQL **não elege sozinho** como o Mongo. Duas opções:
  1. **Failover assistido do painel** (`AUTO_PROMOTE=1`, padrão no `20-app.yaml`): sem primário por
     ~4 s, promove o standby com maior LSN (`pg_promote()`) e reaponta o outro (`ALTER SYSTEM SET
     primary_conninfo` + reload). É um plano B de laboratório — **não é um produto de HA**.
  2. **Patroni + etcd** nas mesmas VMs: o que reproduz a demo do Mongo de verdade. Não foi
     instalado nem testado; falta confirmar se `patroni` e `etcd` instalam em CentOS Stream 9 s390x.
     Com Patroni, ponha `AUTO_PROMOTE=0`.
- Usuários: `demo` (app; recebe `pg_monitor`, `EXECUTE` em `pg_promote`/`pg_reload_conf` **no banco
  `demo`**, e `ALTER SYSTEM` só em `primary_conninfo`) e `replicator` (só replicação). Nada de
  superusuário pela rede.
- O app descobre o primário sozinho (tenta os 3 IPs, ignora standby e **primário de timeline antiga**).
- Em **síncrono sem nenhum standby no quórum**, o app **segura as gravações** ("gravações em espera")
  em vez de mandar `COMMIT`s que ficariam presos no servidor.
- `wal_sender_timeout` / `wal_receiver_timeout` = **5 s**: uma VM pausada não fecha o TCP, e com o
  padrão de 60 s o primário seguiria contando o standby congelado no quórum.

## Passo a passo no laboratório

Pré-requisitos: **VPN FortiClient ligada** (porta **11443**, ver a nota do laboratório), `oc login` no
cluster `lone`, uma chave SSH pública, `ssh` e `openssl` na máquina.

```bash
cd gitops-lab/apps/pg-ha-demo
./lab/00-gerar-credenciais.sh                 # cria CREDENCIAIS-pg-lab.txt (não vai para o Git)
DRY_RUN=1 ./lab/01-criar-vms.sh               # confira os YAMLs gerados
./lab/01-criar-vms.sh                         # cria as 3 VMs e espera o SSH
./lab/02-configurar-replicacao.sh             # replicação; termina mostrando pg-lab-2/3 em "quorum"
./lab/03-deploy-painel.sh                     # Secret + Application do Argo; imprime a URL do painel
./lab/05-instalar-autorejoin.sh               # antigo primário volta sozinho ao pool
```

O painel é gerenciado pelo **ArgoCD** (`application-pg-ha-demo.yaml` na raiz do repositório, mesmo
molde do `estoque`). Para publicar código novo: commit + push, depois

```bash
oc start-build pg-ha-demo -n demos --follow && oc rollout restart deploy/pg-ha-demo -n demos
```

Nomes no DNS (`pg-lab-1.lone.sp1.tdsnxcoe.com`) **não existem**: o painel usa IP. Se quiser nomes,
crie os Host Overrides no OPNsense (a mesma pendência do Mongo).

## Roteiro da demo

1. Abra o painel. **Iniciar carga** em modo **síncrona**: TPS estável, 0 perdidas.
2. **Pausar o primário** (congela a VM sem aviso). O gráfico cai a zero, o cartão mostra "sem gravar
   há…", um standby é promovido, o TPS volta. A tabela de eventos registra o **tempo de recuperação**
   e as **perdidas** — em síncrono, **0**.
3. **Retomar VM**: o antigo primário volta com timeline velha — o painel o marca **primário obsoleto**
   por alguns segundos e, sozinho, ele **volta ao pool como standby** (~10 s): o `pg-autorejoin` da VM
   roda `pg_rewind` contra o novo primário, como o MongoDB faz no rollback. Em assíncrono, o que só
   ele tinha (as **perdidas**) é descartado nesse momento.
4. Repita em modo **assíncrona** e compare: TPS maior, e perdas **se** houver atraso na réplica.
5. *(cenário de partição)* pause os dois standbys, deixe o primário gravar, pause o
   primário e retome os standbys: em assíncrono, o que foi gravado na partição **se perde**; em
   síncrono, as gravações **param** (nenhuma perda, mas sem disponibilidade).

## Pegadinhas já encontradas (corrigidas nos scripts)

Encontradas na primeira execução no lab (02/10):

- **Cota do namespace `demos`** (`default-quota`, 48 GiB de memória reservada): com o Mongo e as VMs
  de demo, a terceira VM `u1.large` não sobe (`exceeded quota`). Por isso `o1.large`.
- **Conexões esgotadas em síncrono sem quórum**: cada `COMMIT` esperando standby fica preso no
  servidor; o app desistia em 1,5 s, abria outra conexão, e em segundos estourava o
  `max_connections` (`remaining connection slots are reserved…`) — nem o monitor entrava mais.
  Corrigido no app (espera o quórum) + `wal_sender_timeout` de 5 s.
- **Primário antigo de pé bloqueava o failover**: com o `pg-lab-3` antigo ligado (timeline 11) e o
  primário atual (`pg-lab-2`, timeline 12) pausado, o painel via "um primário" e não promovia o
  standby — 35 s parado até o `pg-lab-2` voltar. Agora "obsoleto" é comparado com a **maior timeline
  já vista**, não só com as visíveis.
- **Reintegração lenta**: o `pg_basebackup` esperava o checkpoint espaçado padrão (até ~4,5 min).
  Agora usa `-c fast` (checkpoint imediato).
- O `02-…sh` lia o `pg_hba.conf` sem `sudo` (`Permission denied`) e duplicava a linha da rede.
- No `e2e.mjs`, rodar a queda do primário e a partição em sequência deixava o primário do primeiro
  cenário pausado — a partição começava com um nó a menos. Agora `split` roda só a partição.

Já conhecidas do teste local:

- `synchronous_standby_names` com hífen **precisa de aspas**: `ANY 1 ("pg-lab-1","pg-lab-2","pg-lab-3")`.
  Sem elas o PostgreSQL recusa o valor e **não sobe**.
- Com a replicação síncrona ligada e **nenhum standby**, todo `COMMIT` **trava**. Aplique a lista só
  depois que os standbys estiverem em `streaming` (o `02-…sh` faz assim).
- O ACL de função de sistema (`pg_promote`) é **por banco**: o `GRANT` precisa rodar no banco `demo`.
- Se o cluster for recriado, a "timeline de referência" do app fica velha e ele recusa o primário novo
  como "obsoleto": **Iniciar carga** recalcula a referência (corrigido).
- A imagem gold sai **aberta** (usuário `demo` com senha conhecida, PostgreSQL aceitando a rede toda).
  O `02-…sh` troca a senha, mas o `pg_hba.conf` continua aceitando a `192.168.5.0/24` — só no lab.

## Testar contra o lab (sem abrir o navegador)

```bash
oc port-forward -n demos deploy/pg-ha-demo 18080:8080 &
cd test && PORT=18080 node e2e.mjs sync        # ou: async | sync split | async split
```

Depois de cada teste, retome as VMs pausadas e reintegre o antigo primário com
`./lab/04-reintegrar-no.sh <nó> <IP do primário atual>` (o painel mostra quem é o primário).

## Rodar localmente (sem laboratório)

```bash
podman machine start                 # se estiver parado
cd test && ./local-up.sh             # 3 PostgreSQL 16 com replicação (portas 15432–15434)
./run-app-local.sh                   # painel em http://localhost:8080 (nova aba de terminal)
node e2e.mjs sync                    # carga + pausa do primário + mede RTO e perdas
node e2e.mjs async split             # só a partição (rode com os 3 nós saudáveis)
./local-down.sh                      # remove tudo
```

## Variáveis de ambiente do app

| Variável | Padrão | Para quê |
| :--- | :--- | :--- |
| `PG_HOSTS` | `192.168.5.123,…124,…125` | nós, `host[:porta]` |
| `PG_NAMES` | `pg-lab-1,pg-lab-2,pg-lab-3` | nomes (= `application_name` e nome da VM) |
| `PG_USER` / `PG_DB` / `PG_PASSWORD` | `demo` / `demo` / — | credencial do app (a senha vem do Secret) |
| `PG_REPL_PASSWORD` | — | usada só no failover assistido |
| `AUTO_PROMOTE` | `0` (no Deployment: `1`) | failover assistido |
| `PROMOTE_AFTER_MS` | `4000` | quanto esperar sem primário antes de promover |
| `QUERY_TIMEOUT_MS` / `CONNECT_TIMEOUT_MS` | `1500` / `1000` | quanto o app espera antes de dar a falha por detectada |
| `VM_NAMESPACE` | `demos` | onde estão as VMs (botões de queda) |
| `CHAOS_CMD` | — | só testes locais, ex.: `podman {action} {name}` |

## Limitações

- **O retorno ao pool depende do `pg-autorejoin`** (`lab/05-instalar-autorejoin.sh`). O PostgreSQL,
  sozinho, não reintegra o antigo primário — de propósito, porque ele pode ter transações que o novo
  primário não tem. O serviço só age quando o nó local é primário **e** um par responde como
  primário de timeline maior; com o PostgreSQL parado não faz nada. Sem ele (ou desligado com
  `systemctl disable --now pg-autorejoin`), use `./lab/04-reintegrar-no.sh`. Em produção, quem faz
  isso (e a eleição, no lugar do failover assistido do painel) é o **Patroni**.
- O gerador de carga e a contagem de perdas ficam **em memória**: uma réplica só, e reiniciar o pod zera.
- A verificação de perdas roda 1,5 s depois de cada recuperação e ao parar a carga, no primário atual.
- O RTO inclui o tempo que o **app** leva para notar a falha (`QUERY_TIMEOUT_MS`).
- Dado **sintético** (tabela `ledger`); nada do SERPRO entra no laboratório.
