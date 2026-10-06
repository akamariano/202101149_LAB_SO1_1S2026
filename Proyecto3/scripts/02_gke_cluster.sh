#!/usr/bin/env bash
# Bloque 1b: crea el clúster GKE Standard (zonal) con nodos N1 y Gateway API habilitado.
set -euo pipefail
source "$(dirname "$0")/config.env"

# Notas de diseño:
# - Zonal (no regional): un clúster zonal entra en el free tier de gestión de GKE.
# - pd-standard 50GB: el disco por defecto es pd-balanced de 100GB y cuenta contra la
#   cuota SSD (250GB); 3 nodos x 100GB = 300GB y la creación fallaría.
# - --gateway-api=standard: instala los CRDs de Gateway API y las GatewayClass de GKE
#   (gke-l7-global-external-managed, etc.). Sustituye a un Ingress Controller.
# - metrics-server viene incluido en GKE (lo necesita el HPA del bloque 3).
if ! gcloud container clusters describe "$CLUSTER" --zone "$ZONE" &>/dev/null; then
  gcloud container clusters create "$CLUSTER" \
    --zone "$ZONE" \
    --machine-type "$NODE_MACHINE" \
    --num-nodes "$NODE_COUNT" \
    --disk-type pd-standard --disk-size 50 \
    --release-channel regular \
    --gateway-api standard
fi

echo "→ Credenciales para kubectl"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE"

kubectl get nodes -o wide
echo
echo "→ GatewayClasses disponibles:"
kubectl get gatewayclass
