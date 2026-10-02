#!/usr/bin/env bash
for n in 1 2 3; do podman rm -f pg-lab-$n >/dev/null 2>&1; podman volume rm -f pgha$n >/dev/null 2>&1; done
podman network rm -f pgha >/dev/null 2>&1
rm -rf "$(dirname "$0")/init"
echo "ambiente local removido"
