#!/usr/bin/env bash
# Despliega Grafana (bloque 6) y abre el dashboard en el navegador.
#
# Uso:
#   ./scripts/41_grafana_deploy.sh        # todo: imagen en Zot, operador v4, consumer v3, Secret, CR y dashboard
#   ./scripts/41_grafana_deploy.sh ver    # solo abre el dashboard (Grafana ya desplegado)
#
# Variables opcionales:
#   TAG=v3  tag de la imagen del operador (por defecto v5). Súbelo si vuelves a cambiar un chart:
#           con el mismo tag el clúster no descarga la imagen nueva.
#   FORCE=1 reconstruye el operador aunque ya corra con ese tag.
#   PORT=3300 puerto local del dashboard (3300 y no 3000, que suelen usar los servidores de desarrollo).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.env
source "$SECRETS_DIR/zot.env"

NS=mumnk8s
TAG="${TAG:-v5}"
PORT="${PORT:-3300}"
GRAFANA_IMG="$ZOT_DOMAIN/mumnk8s/grafana:12.4.13"
OPERATOR_IMG="$ZOT_DOMAIN/mumnk8s/mumnk8s-operator:$TAG"
CONSUMER_IMG="$ZOT_DOMAIN/mumnk8s/consumer:v3"   # debe coincidir con k8s/60-consumer.yaml

paso() { echo; echo "==> $*"; }

ver_dashboard() {
  source "$SECRETS_DIR/grafana.env"
  paso "Valores en Valkey (compáralos con los paneles)"
  kubectl -n "$NS" exec valkey-0 -- sh -c '
    for k in max:planes min:planes max:ships min:ships mode:planes mode:ships mode:planes:GTM mode:ships:GTM reports:GTM; do
      echo "  $k = $(valkey-cli get $k)"
    done
    echo "  top:planes = $(valkey-cli zrange top:planes 0 4 rev withscores | paste -sd " " -)"
    echo "  top:ships  = $(valkey-cli zrange top:ships 0 4 rev withscores | paste -sd " " -)"
    echo "  ts:GTM     = $(valkey-cli xlen ts:GTM) entradas"'

  local url="http://localhost:$PORT"
  paso "Dashboard en $url"
  echo "  usuario: $GRAFANA_USER"
  echo "  clave:   $GRAFANA_PASS"
  # Si en ese puerto ya responde Grafana (otro port-forward abierto), se reutiliza
  if curl -s "$url/api/health" 2>/dev/null | grep -q '"database"'; then
    echo "  (ya hay un port-forward a Grafana en el puerto $PORT; se reutiliza)"
    open "$url"
    return
  fi
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null; then
    echo "El puerto $PORT lo usa otro programa. Usa otro: PORT=3400 $0 ver"
    exit 1
  fi
  echo "  (Ctrl+C para cerrar el port-forward)"
  # Abre el navegador cuando el port-forward ya está escuchando
  (sleep 3 && open "$url") &
  kubectl -n "$NS" port-forward svc/grafana "$PORT":80
}

if [ "${1:-}" = "ver" ]; then
  ver_dashboard
  exit 0
fi

docker info &>/dev/null || { echo "Abre Docker Desktop primero."; exit 1; }

# 1. La imagen de Grafana debe estar en Zot: el clúster descarga todo de ahí
paso "1/6 Imagen de Grafana en Zot"
echo "$ZOT_PASS" | docker login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null
if docker buildx imagetools inspect "$GRAFANA_IMG" &>/dev/null; then
  echo "  ya existe $GRAFANA_IMG"
else
  ./scripts/11_mirror_externas.sh
fi

# 2. Los charts viajan dentro de la imagen del operador: la v1 solo conoce Valkey
paso "2/6 Operador $TAG (con el kind GrafanaInstance)"
ACTUAL=$(kubectl -n mumnk8s-operator-system get deploy mumnk8s-operator-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}' 2>/dev/null || true)
if [ "$ACTUAL" = "$OPERATOR_IMG" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  ya corre $OPERATOR_IMG (FORCE=1 para reconstruir)"
else
  TAG="$TAG" ./operator/build_deploy.sh
fi
kubectl get crd grafanainstances.mumnk8s.so1.usac >/dev/null

# 3. Consumer v3: además de la moda general calcula la moda por país (mode:planes:<PAIS>)
paso "3/6 Consumer v3"
if docker buildx imagetools inspect "$CONSUMER_IMG" &>/dev/null && [ "${FORCE:-0}" != "1" ]; then
  echo "  ya existe $CONSUMER_IMG"
else
  TAG=v3 ./scripts/10_build_push.sh consumer
fi
kubectl apply -f k8s/60-consumer.yaml
kubectl -n "$NS" rollout status deploy/consumer --timeout=120s

# 4. Usuario y clave del admin
paso "4/6 Secret grafana-admin"
./scripts/40_grafana_secret.sh

# 5. El CR: el operador crea Deployment, Service y ConfigMaps
paso "5/6 CR GrafanaInstance"
kubectl apply -f k8s/80-grafana.yaml
echo "  esperando a que el operador cree el Deployment..."
for _ in $(seq 1 60); do
  kubectl -n "$NS" get deploy grafana &>/dev/null && break
  sleep 2
done
kubectl -n "$NS" get deploy grafana >/dev/null || {
  echo "El operador no creó el Deployment. Revisa:"
  echo "  kubectl -n $NS describe grafanainstance grafana"
  echo "  kubectl -n mumnk8s-operator-system logs deploy/mumnk8s-operator-controller-manager"
  exit 1
}

# 6. Pod listo (el initContainer descarga el plugin de Redis antes de arrancar)
paso "6/6 Esperando el pod de Grafana"
kubectl -n "$NS" rollout status deploy/grafana --timeout=300s || {
  echo "Grafana no quedó listo. Logs del initContainer:"
  kubectl -n "$NS" logs deploy/grafana -c install-plugins --tail=20 || true
  exit 1
}
kubectl -n "$NS" get grafanainstance grafana
kubectl -n "$NS" get deploy,svc,pod -l app.kubernetes.io/name=grafana

ver_dashboard
