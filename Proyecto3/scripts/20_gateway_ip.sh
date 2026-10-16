#!/usr/bin/env bash
# Espera a que el Gateway tenga IP pública y prueba la ruta /grpc-<carnet>.
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "→ Esperando la IP del Gateway (el balanceador tarda unos minutos)"
until IP=$(kubectl -n mumnk8s get gateway mumnk8s-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null) && [ -n "$IP" ]; do
  sleep 10
done
echo "IP del Gateway: $IP"

echo "→ Probando POST /grpc-$CARNET (puede dar 404/502 mientras el balanceador termina de configurarse)"
until curl -sf -X POST "http://$IP/grpc-$CARNET" -H 'content-type: application/json' \
  -d '{"country":"GTM","warplanes_in_air":42,"warships_in_water":14,"timestamp":"2026-10-13T12:00:00Z"}'; do
  sleep 15
done
echo
echo "Locust: locust -f locust/locustfile.py --host http://$IP"
