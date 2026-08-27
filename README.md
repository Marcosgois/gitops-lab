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
