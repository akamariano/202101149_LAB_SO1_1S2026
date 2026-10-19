#!/usr/bin/env bash
# Pruebas de rendimiento con 1 y 2 réplicas en go-writer (gRPC server + writer RabbitMQ)
# y en Valkey (primario solo vs. primario + réplica).
#
# Cada escenario: fija las réplicas, espera a que estén listas, corre Locust headless y
# en paralelo toma una muestra cada 5 s de la cola de RabbitMQ y de la CPU/memoria de
# los pods. Todo queda en pruebas/<escenario>/.
#
# rust-api se fija en 3 réplicas (HPA min=max=3) mientras duran las pruebas, para que el
# HPA no escale a mitad de una corrida y la única variable sea la que se está midiendo.
#
# Uso: ./scripts/60_pruebas_replicas.sh                 # los 4 escenarios
#      ./scripts/60_pruebas_replicas.sh w2-v1           # solo uno
#      USUARIOS=200 DURACION=3m ./scripts/60_pruebas_replicas.sh
# Alta carga (ronda 2): Locust en varios procesos y go-api fijo en 2 réplicas para que el
# Deployment 1 no sea el cuello de botella:
#      PREFIJO=alta- USUARIOS=600 TASA=50 PROCESOS=4 GO_API=2 ./scripts/60_pruebas_replicas.sh w1-v1 w2-v1
set -euo pipefail
source "$(dirname "$0")/config.env"

NS=mumnk8s
GATEWAY="${GATEWAY:-http://34.54.242.227}"
USUARIOS="${USUARIOS:-150}"
TASA="${TASA:-25}"
DURACION="${DURACION:-2m}"
FLUJO="${FLUJO:-grpc}"
PROCESOS="${PROCESOS:-1}"   # procesos de Locust (uno solo satura un núcleo de la Mac)
GO_API="${GO_API:-}"        # réplicas fijas de go-api durante la prueba (vacío = no se toca)
PREFIJO="${PREFIJO:-}"      # prefijo de la carpeta de resultados
OUT="$P3_ROOT/pruebas"
ESCENARIOS="${*:-w1-v1 w2-v1 w1-v2 w2-v2}"

[ -f "$P3_ROOT/locust/.artifact/war-config.json" ] || "$P3_ROOT/scripts/50_oci_artifact.sh" pull

restaurar_hpa() {
  kubectl -n $NS patch hpa rust-api --type merge -p '{"spec":{"minReplicas":1,"maxReplicas":3}}' >/dev/null
  [ -z "$GO_API" ] || kubectl -n $NS scale deploy/go-api --replicas=1 >/dev/null
  echo "HPA de rust-api restaurado (1-3)"
}
trap restaurar_hpa EXIT
kubectl -n $NS patch hpa rust-api --type merge -p '{"spec":{"minReplicas":3,"maxReplicas":3}}' >/dev/null
kubectl -n $NS rollout status deploy/rust-api --timeout=180s
if [ -n "$GO_API" ]; then
  kubectl -n $NS scale deploy/go-api --replicas="$GO_API" >/dev/null
  kubectl -n $NS rollout status deploy/go-api --timeout=180s
fi

muestrear() {  # $1 = carpeta del escenario; corre hasta que lo maten
  local dir=$1
  # mensajes_en_cola = war_reports (flujo principal); cola_dapr = go-writer-war_reports_dapr
  echo "hora,mensajes_en_cola,sin_ack,cola_dapr" > "$dir/cola.csv"
  while true; do
    local t; t=$(date +%H:%M:%S)
    kubectl -n $NS exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages messages_unacknowledged 2>/dev/null \
      | awk -v t="$t" '$1=="war_reports"{m=$2;u=$3} $1=="go-writer-war_reports_dapr"{d=$2} END{if(m!="")print t","m","u","d+0}' >> "$dir/cola.csv" || true
    { echo "# $t"; kubectl -n $NS top pods --containers 2>/dev/null; } >> "$dir/cpu.txt" || true
    sleep 5
  done
}

for esc in $ESCENARIOS; do
  w=${esc#w}; w=${w%%-*}      # w2-v1 -> 2
  v=${esc##*-v}               # w2-v1 -> 1
  dir="$OUT/$PREFIJO$esc"; rm -rf "$dir"; mkdir -p "$dir"
  echo "=== $esc: go-writer=$w réplica(s), Valkey=$v réplica(s) ==="

  kubectl -n $NS scale deploy/go-writer --replicas="$w" >/dev/null
  kubectl -n $NS patch valkeyinstance valkey --type merge -p "{\"spec\":{\"replicas\":$v}}" >/dev/null
  kubectl -n $NS rollout status deploy/go-writer --timeout=180s
  # El operador reconcilia el CR por su cuenta; se espera a que el StatefulSet tenga v pods listos.
  until [ "$(kubectl -n $NS get sts valkey -o jsonpath='{.status.readyReplicas}')" = "$v" ]; do sleep 3; done
  # El cliente gRPC re-resuelve el DNS headless al expirar MaxConnectionAge (sección 8.5)
  sleep 35
  kubectl -n $NS get pods -o wide > "$dir/pods.txt"

  muestrear "$dir" & PID=$!
  FLUJO=$FLUJO locust -f "$P3_ROOT/locust/locustfile.py" --host "$GATEWAY" --headless \
    -u "$USUARIOS" -r "$TASA" -t "$DURACION" --processes "$PROCESOS" --csv "$dir/locust" --only-summary \
    > "$dir/locust.log" 2>&1 || true
  sleep 10   # deja que el consumer vacíe la cola y queda registrado
  kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true

  # Resumen: req/s, p50, p95, fallos (fila Aggregated del CSV de Locust)
  awk -F, -v e="$PREFIJO$esc" 'NR>1 && $2=="Aggregated"{printf "%s  req=%s fallos=%s  p50=%sms p95=%sms  req/s=%.1f\n", e,$3,$4,$12,$17,$10}' \
    "$dir/locust_stats.csv" | tee "$dir/resumen.txt"
  echo "  máximo en cola: $(awk -F, 'NR>1 && $2>m{m=$2} END{print m+0}' "$dir/cola.csv") (Dapr: $(awk -F, 'NR>1 && $4>m{m=$4} END{print m+0}' "$dir/cola.csv"))"
done

# Se deja todo como estaba: 1 go-writer y 1 Valkey
kubectl -n $NS scale deploy/go-writer --replicas=1 >/dev/null
kubectl -n $NS patch valkeyinstance valkey --type merge -p '{"spec":{"replicas":1}}' >/dev/null
echo "Resultados en $OUT/"
