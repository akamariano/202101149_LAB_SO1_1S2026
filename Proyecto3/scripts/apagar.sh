#!/usr/bin/env bash
# Apaga lo que cobra por hora al terminar cada sesión de trabajo.
# Los discos, la IP estática y los datos de Zot se conservan (cuestan centavos).
set -euo pipefail
source "$(dirname "$0")/config.env"

gcloud container clusters resize "$CLUSTER" --zone "$ZONE" --node-pool default-pool --num-nodes 0 --quiet || true
gcloud compute instances stop "$ZOT_VM" --zone "$(zot_zone)" --quiet || true
echo "✔ Clúster en 0 nodos y VM de Zot detenida"
