#!/usr/bin/env bash
# Apaga lo que cobra por hora al terminar cada sesión de trabajo.
# Los discos, la IP estática y los datos de Zot se conservan (cuestan centavos).
set -euo pipefail
source "$(dirname "$0")/config.env"

# Locust y el port-forward de 90_calificacion.sh quedan en segundo plano. Una carga olvidada
# sigue mandando tráfico, satura la red de casa y en la siguiente sesión todo responde 000.
curl -s -m 5 http://localhost:8089/stop >/dev/null 2>&1 || true
pkill -f 'bin/locust' 2>/dev/null || true
pkill -f 'while true; do kubectl -n mumnk8s port-forward' 2>/dev/null || true   # primero el bucle, si no lo reabre
pkill -f 'port-forward svc/grafana' 2>/dev/null || true
rm -f "$(dirname "$0")/../.calificacion/"{locust,grafana-pf}.pid
echo "✔ Locust y port-forward cerrados"

gcloud container clusters resize "$CLUSTER" --zone "$ZONE" --node-pool default-pool --num-nodes 0 --quiet || true
gcloud compute instances stop "$ZOT_VM" --zone "$(zot_zone)" --quiet || true
echo "✔ Clúster en 0 nodos y VM de Zot detenida"
