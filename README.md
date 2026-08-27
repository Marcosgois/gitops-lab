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
