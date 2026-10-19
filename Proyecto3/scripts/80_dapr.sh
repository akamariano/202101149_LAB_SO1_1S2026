#!/usr/bin/env bash
# Dapr: flujo alternativo /dapr-202101149 con pub/sub sobre RabbitMQ.
# Uso: ./scripts/80_dapr.sh instalar   # plano de control (chart oficial, imágenes de Zot) + Component
#      ./scripts/80_dapr.sh probar     # un reporte por /dapr-<carnet> y lo que pasó en cada salto
#      ./scripts/80_dapr.sh estado     # pods con sidecar, Component y colas de RabbitMQ
#      ./scripts/80_dapr.sh borrar
set -euo pipefail
source "$(dirname "$0")/config.env"

NS=mumnk8s
CHART_VERSION=1.18.7
GATEWAY="${GATEWAY:-http://34.54.242.227}"
DIR="$P3_ROOT/k8s"

case "${1:-}" in
  instalar)
    helm repo add dapr https://dapr.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update dapr >/dev/null
    helm upgrade --install dapr dapr/dapr --version $CHART_VERSION \
      -n dapr-system --create-namespace -f "$DIR/dapr/values.yaml" --wait
    kubectl -n dapr-system get pods
    kubectl apply -f "$DIR/dapr/pubsub.yaml"
    # Los Deployments con anotaciones dapr.io/* reciben el sidecar al crearse sus pods. Si ya
    # existían antes de instalar Dapr, apply no cambia nada: el restart los recrea.
    kubectl apply -f "$DIR/10-rust-api.yaml" -f "$DIR/20-go-api.yaml" -f "$DIR/30-go-writer.yaml" -f "$DIR/40-gateway.yaml"
    kubectl -n $NS rollout restart deploy/go-api deploy/go-writer
    kubectl -n $NS rollout status deploy/go-api --timeout=180s
    kubectl -n $NS rollout status deploy/go-writer --timeout=180s
    kubectl -n $NS rollout status deploy/rust-api --timeout=180s
    ;;
  probar)
    body="{\"country\":\"GTM\",\"warplanes_in_air\":7,\"warships_in_water\":3,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    echo "→ POST $GATEWAY/dapr-$CARNET"
    curl -s -w '  (HTTP %{http_code})\n' -H 'Content-Type: application/json' -d "$body" "$GATEWAY/dapr-$CARNET"
    sleep 12   # el resumen de grpc-server se imprime cada 10 s
    echo "--- sidecar daprd de go-api (publicador)"
    kubectl -n $NS logs deploy/go-api -c daprd --tail=200 | grep -i -E "pubsub|component|error" | tail -3 || true
    echo "--- grpc-server de go-writer (suscriptor)"
    kubectl -n $NS logs deploy/go-writer -c grpc-server --tail=20 | grep -i dapr | tail -4 || true
    "$0" estado | tail -6
    ;;
  estado)
    kubectl -n $NS get pods -l 'app in (go-api,go-writer)'
    kubectl -n $NS get components.dapr.io
    echo "--- colas en RabbitMQ"
    kubectl -n $NS exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages consumers
    ;;
  borrar)
    kubectl delete -f "$DIR/dapr/pubsub.yaml" --ignore-not-found
    helm uninstall dapr -n dapr-system
    ;;
  *)
    echo "Uso: $0 instalar|probar|estado|borrar"; exit 1 ;;
esac
