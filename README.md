# gitops-lab

Repositório de exercício para aprender ArgoCD no cluster IBM Z.

## A ideia em uma frase

O Git descreve o estado desejado. O ArgoCD compara com o estado real do cluster,
continuamente, e corrige a diferença.

## Estrutura

    apps/hello/          os manifestos da aplicação — o que deve existir no cluster
    application.yaml     o CR Application — só diz ao ArgoCD onde procurar

O `application.yaml` NÃO vai dentro de `apps/hello/`. Se fosse, o ArgoCD tentaria
gerenciar a si mesmo. Ele vive fora, ou num repo separado.

## Imagens em s390x

Nem toda imagem pública tem build para s390x. Verifique ANTES de usar:

    oc image info <imagem> --filter-by-os=linux/s390x

Conhecidas neste lab:

    registry.access.redhat.com/ubi9/httpd-24     TEM
    registry.access.redhat.com/ubi9/nodejs-20    TEM
    quay.io/openshift/origin-hello-openshift     NÃO
    docker.io/library/mongo:8.0                  NÃO

O guestbook, exemplo canônico do ArgoCD, usa imagem amd64 e falha aqui. O sintoma
é `no matching manifest for linux/s390x` — parece bug do ArgoCD, é arquitetura.

## Três armadilhas encontradas na prática

### 1. `permission denied: applications, create` — RBAC do ArgoCD é separado do OpenShift

Ser `cluster-admin` no OpenShift **não dá nada** dentro do ArgoCD. Ele mantém a própria
camada de autorização. A política padrão só reconhece os grupos `system:cluster-admins`
e `cluster-admins`; e como `policy.default` vem vazio, quem não casa não recebe papel
nenhum — o erro é negação, não uma tela em modo leitura.

Se o cluster usa grupos próprios (aqui: `ocp-admins`, `ocp-devs`, `ocp-viewers`),
mapeie-os:

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
  -p '{"spec":{"rbac":{"policy":"g, system:cluster-admins, role:admin\ng, ocp-admins, role:admin\n"}}}'
```

**Edite o CR `ArgoCD`, nunca o ConfigMap `argocd-rbac-cm`** — o operador regenera o
ConfigMap a partir do CR e desfaz sua mudança sem avisar.

### 2. `deployments.apps is forbidden` — o controller não pode implantar aplicações

O ClusterRole padrão do OpenShift GitOps dá **leitura em tudo**, mas escrita só em
grupos de API de configuração de cluster (operators, MachineConfig, RBAC, storage). No
grupo core, só `namespaces`, `configmaps` e PVCs.

Não há `apps/Deployment`, `Service` nem `Route`. É deliberado: a instância padrão serve
GitOps *de configuração de cluster*, não implantação de aplicação.

A correção idiomática **não** é dar cluster-admin — é rotular o namespace de destino:

```yaml
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

O operador detecta o rótulo e cria, dentro daquele namespace, os RoleBindings
`openshift-gitops-argocd-application-controller` e `openshift-gitops-argocd-server`.
Permissão fica restrita ao namespace, e a correção viaja pelo Git como todo o resto.

Sintoma característico: `Namespace` e `ConfigMap` ficam **Synced**, e `Deployment`,
`Service` e `Route` ficam **SyncFailed / Missing**. A fronteira entre o que sincroniza e
o que falha desenha exatamente o limite da permissão.

### 3. `oc get application` mente quando o ACM está instalado

O ACM registra um CRD `Application` no grupo `app.k8s.io`, que colide com o
`argoproj.io` do ArgoCD:

```
app.k8s.io/v1beta1      Application   <- ACM
argoproj.io/v1alpha1    Application   <- ArgoCD
```

`oc get application` resolve para o do ACM e responde **"No resources found"** mesmo com
Applications do ArgoCD existindo. Use sempre o nome completo:

```bash
oc get applications.argoproj.io -A
```

Isso causou um diagnóstico errado aqui: o `oc apply` respondia `configured` (existia)
enquanto o `oc get` dizia que não havia nada.

## apps/estoque — app com MongoDB, build no cluster e dados que sobrevivem

Estoque de peças com **dados fictícios**, gravado no replica set MongoDB de 3 VMs.
A página mostra de qual pod e nó veio a resposta, em qual arquitetura, e qual membro do
MongoDB é o primário. Dá para somar, subtrair, digitar quantidade (duplo clique), criar
e remover itens.

    apps/estoque/*.yaml        manifestos que o ArgoCD aplica
    apps/estoque/src/          código Node.js — o BuildConfig constrói no cluster (S2I)
    application-estoque.yaml   o CR Application

### O Secret não vai para o Git

O app lê `MONGODB_URI` do Secret `estoque-mongodb`, criado à mão depois que o ArgoCD
cria o namespace. Recursos criados fora do Git não têm a anotação de tracking, então o
`prune` do ArgoCD não os apaga.

```bash
oc create secret generic estoque-mongodb -n estoque-demo \
  --from-literal=MONGODB_URI='mongodb://<usuario>:<senha>@<host1>,<host2>,<host3>/estoque?replicaSet=<rs>&authSource=estoque'
oc rollout restart deploy/estoque -n estoque-demo
```

Sem o Secret, a página sobe e diz o que falta — não fica em `CreateContainerConfigError`.

### O que demonstrar

| Ação | O que prova |
|---|---|
| F5 várias vezes | o pod muda, o dado não |
| `+` / `−` e F5 | a gravação está no banco, não no navegador |
| `oc delete pod -l app=estoque -n estoque-demo` | pod novo, mesmo dado |
| migrar uma VM do replica set | o app segue gravando; nada se perde |
| mudar `APP_VERSAO` e `APP_COR` no `deployment.yaml`, push | o ArgoCD aplica sozinho: versão e cor novas, mesmos dados |
| `oc scale deploy/estoque --replicas=5 -n estoque-demo` | o `selfHeal` volta para 2 — o Git manda |

### Build

O `BuildConfig` roda uma vez quando é criado. Mudou o código em `src/`? Faça push e:

```bash
oc start-build estoque -n estoque-demo --follow
oc rollout restart deploy/estoque -n estoque-demo
```

O S2I roda `npm install`, então o build precisa de saída para `registry.npmjs.org`.
A imagem já construída fica no registry interno e não depende mais de internet.
