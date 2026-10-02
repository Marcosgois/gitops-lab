#!/usr/bin/env bash
# Gera as senhas do laboratório em CREDENCIAIS-pg-lab.txt (na raiz de pg-ha-demo).
# Não sobrescreve se o arquivo já existir. Nada daqui vai para o Git nem para o vault.
set -euo pipefail
cd "$(dirname "$0")/.."
F=CREDENCIAIS-pg-lab.txt
if [ -f "$F" ]; then echo "$F já existe — mantido."; exit 0; fi
umask 077
{
  echo "PG_PASSWORD=$(openssl rand -hex 12)"        # usuário de aplicação 'demo'
  echo "PG_REPL_PASSWORD=$(openssl rand -hex 12)"   # usuário 'replicator'
} > "$F"
echo "criado $F (permissão 600). Guarde-o fora do Git."
