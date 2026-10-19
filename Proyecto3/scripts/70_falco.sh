#!/usr/bin/env bash
# Falco: seguridad en tiempo real a nivel de syscalls.
# Uso: ./scripts/70_falco.sh instalar   # chart oficial + regla propia (imágenes desde Zot)
#      ./scripts/70_falco.sh probar     # kubectl exec en un pod y cat /etc/shadow
#      ./scripts/70_falco.sh logs       # alertas de la regla propia (DESDE=1m para las recientes)
#      ./scripts/70_falco.sh borrar
set -euo pipefail
source "$(dirname "$0")/config.env"

NS_FALCO=falco
CHART_VERSION=9.2.0
DIR="$P3_ROOT/k8s/falco"

case "${1:-}" in
  instalar)
    helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
    helm repo update falcosecurity >/dev/null
    helm upgrade --install falco falcosecurity/falco --version $CHART_VERSION \
      -n $NS_FALCO --create-namespace \
      -f "$DIR/values.yaml" \
      --set-file "customRules.reglas-mumnk8s\.yaml=$DIR/reglas-mumnk8s.yaml"
    kubectl -n $NS_FALCO rollout status ds/falco --timeout=300s
    kubectl -n $NS_FALCO get pods -o wide
    ;;
  probar)
    POD=$(kubectl -n mumnk8s get pods -l app=rust-api -o jsonpath='{.items[0].metadata.name}')
    echo "→ kubectl exec $POD -- cat /etc/shadow"
    kubectl -n mumnk8s exec "$POD" -- cat /etc/shadow || true
    POD=$(kubectl -n mumnk8s get pods -l app=go-writer -o jsonpath='{.items[0].metadata.name}')
    echo "→ kubectl exec $POD -c grpc-server -- cat /etc/gshadow"
    kubectl -n mumnk8s exec "$POD" -c grpc-server -- cat /etc/gshadow || true
    sleep 3
    "$0" logs
    ;;
  logs)
    # Cada pod de Falco solo ve su nodo: se juntan las alertas de todos y se ordenan por hora.
    # DESDE=1m ./scripts/70_falco.sh logs  -> solo las del último minuto (por defecto 30m)
    for p in $(kubectl -n $NS_FALCO get pods -l app.kubernetes.io/name=falco -o name); do
      kubectl -n $NS_FALCO logs "$p" -c falco --since="${DESDE:-30m}" | grep '\[MUMNK8s\]' || true
    done | jq -r '"[\(.hostname)] \(.output)"' | sort -t' ' -k2
    ;;
  borrar)
    helm uninstall falco -n $NS_FALCO
    ;;
  *)
    echo "Uso: $0 instalar|probar|logs|borrar"; exit 1 ;;
esac
