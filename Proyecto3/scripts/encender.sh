#!/usr/bin/env bash
# Enciende la VM de Zot y vuelve a escalar el clúster para trabajar.
set -euo pipefail
source "$(dirname "$0")/config.env"

gcloud compute instances start "$ZOT_VM" --zone "$(zot_zone)" --quiet || true
gcloud container clusters resize "$CLUSTER" --zone "$ZONE" --node-pool default-pool --num-nodes "$NODE_COUNT" --quiet || true
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE"
kubectl get nodes
