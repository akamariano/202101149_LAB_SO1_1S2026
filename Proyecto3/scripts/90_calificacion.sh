#!/usr/bin/env bash
# Calificación (pruebas/Official/Guía Proyecto 3 .pdf): el sistema debe estar desplegado ANTES
# del turno y durante el turno no se compila ni se despliega nada. Este script separa las dos cosas:
#
#   ./scripts/90_calificacion.sh            # TODO de una vez: levanta, abre las 3 pestañas
#                                           # (Locust, Zot, Grafana) y ejecuta las 4 vueltas + extra
#   ./scripts/90_calificacion.sh levantar   # solo levantar: enciende GCP, verifica y abre las pestañas
#   ./scripts/90_calificacion.sh vuelta1    # Infraestructura GCP, Zot y Gateway API
#   ./scripts/90_calificacion.sh vuelta2    # Locust, Rust, gRPC client/server y HPA
#   ./scripts/90_calificacion.sh vuelta3    # RabbitMQ, consumer, Operator (CRDs y CRs) y Valkey
#   ./scripts/90_calificacion.sh vuelta4    # Grafana, alertas de Falco y manual
#   ./scripts/90_calificacion.sh extra      # flujo Dapr /dapr-<carnet>
#   ./scripts/90_calificacion.sh todo       # ensayo: las 4 vueltas y el extra seguidos
#   ./scripts/90_calificacion.sh detener    # para la carga y cierra Locust y el port-forward (no apaga GCP)
#   ./scripts/90_calificacion.sh ayuda      # esta ayuda
#
# Las vueltas están en scripts/lib_calificacion.sh (las comparte 91_mostrar.sh, que solo lee).
# Cada una imprime primero lo que pide la guía, rotula [Guía, comando n de N] los comandos del
# PDF y [Evidencia adicional] el resto, y termina con un resumen ✔/✘ de las verificaciones.
#
# Variables opcionales:
#   PAUSA=vuelta  espera Enter entre vueltas (por defecto)
#   PAUSA=comando espera Enter después de cada comando
#   PAUSA=0       no espera nunca
#   USUARIOS=1000 usuarios de Locust en la vuelta 2 (lo que pide la guía de calificación)
#   SPAWN=50      usuarios nuevos por segundo (1000 en 20 s)
#   ESPERA=a,b    pausa en segundos entre reportes de cada usuario (por defecto la del OCI Artifact)
#   PROCESOS=4    procesos de Locust
# Con 2000 usuarios desde una red doméstica, el router se queda sin entradas NAT (2000 conexiones
# abiertas a la vez): hubo timeouts de conexión aunque el clúster estaba ocioso (sección 16).
# Si con 1000 aparecen ConnectTimeoutError, ESPERA=1,2 baja las req/s sin bajar los usuarios.
#
# Los nombres de los CRDs, de los CRs y del pod de Valkey NO están fijos: se leen del clúster
# (grupo mumnk8s.so1.usac), así que el script sigue sirviendo si se renombra el CR o el kind.
set -euo pipefail
# Ruta absoluta del script: después del cd, "$0" relativo (./90_calificacion.sh) ya no existe
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
source scripts/config.env
source "$SECRETS_DIR/zot.env"

MODO=calificar
source scripts/lib_calificacion.sh
export ESPERA="${ESPERA:-}"    # vacío: Locust usa wait_time_s del OCI Artifact
ESTADO="$P3_ROOT/.calificacion"   # PIDs y logs de los procesos en segundo plano (ignorado por git)
mkdir -p "$ESTADO"

# ---------- levantar (antes del turno) ----------
levantar() {
  titulo "LEVANTAR: todo debe quedar listo antes del turno"

  paso "1. VM de Zot y nodos de GKE"
  ./scripts/encender.sh
  until curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$ZOT_DOMAIN/v2/" | grep -qE '200|401'; do sleep 5; done
  ok "Zot responde por HTTPS en https://$ZOT_DOMAIN"

  paso "2. Componentes del proyecto (idempotente: si ya existen, no cambia nada)"
  kubectl apply -f k8s/00-namespace.yaml >/dev/null
  ./scripts/30_rabbitmq_secret.sh >/dev/null
  ./scripts/40_grafana_secret.sh >/dev/null
  if ! kubectl -n mumnk8s-operator-system get deploy mumnk8s-operator-controller-manager &>/dev/null; then
    falla "No está el operador. Instálalo con: TAG=v5 ./operator/build_deploy.sh"; exit 1
  fi
  helm status dapr -n dapr-system &>/dev/null || ./scripts/80_dapr.sh instalar
  kubectl apply -f k8s/ >/dev/null
  kubectl apply -f k8s/dapr/pubsub.yaml >/dev/null
  # Falco con http_output hacia falco-bridge (panel de alertas en Grafana)
  helm get values falco -n falco 2>/dev/null | grep -q falco-bridge || ./scripts/70_falco.sh instalar
  ok "manifiestos aplicados"

  paso "3. Esperando que todos los pods estén listos"
  for ns in mumnk8s-operator-system dapr-system falco $NS; do
    kubectl -n "$ns" wait --for=condition=Ready pods --all --timeout=600s >/dev/null && ok "$ns"
  done

  # Al encender, los nodos son nuevos y todos los pods arrancan a la vez. Si un pod de go-api o
  # go-writer se creó antes de que el dapr-sidecar-injector estuviera listo, quedó sin sidecar
  # (el webhook de Dapr deja pasar el pod si falla). Se detecta y se recrea.
  for d in go-api go-writer; do
    if ! kubectl -n $NS get pods -l app=$d -o jsonpath='{.items[*].spec.containers[*].name}' | grep -qw daprd; then
      aviso "$d sin sidecar de Dapr (arrancó antes que el injector): recreando"
      kubectl -n $NS rollout restart deploy/$d >/dev/null
      kubectl -n $NS rollout status deploy/$d --timeout=300s >/dev/null
    fi
    ok "$d con sidecar daprd ($(kubectl -n $NS get pods -l app=$d -o jsonpath='{.items[0].status.containerStatuses[*].name}' | wc -w | tr -d ' ') contenedores)"
  done
  kubectl -n $NS get pods

  paso "4. OCI Artifact (configuración de Locust) desde Zot"
  ./scripts/50_oci_artifact.sh pull | tail -1

  paso "5. Gateway: rutas públicas"
  until [ -n "$(gateway_ip)" ]; do sleep 10; done
  # Una carga de Locust que quedó corriendo satura la red de casa (NAT) y todo da 000
  if locust_vivo && curl -s -m 3 "http://localhost:$LOCUST_PORT/stats/requests" | jq -e '.state == "running" or .state == "spawning"' >/dev/null; then
    curl -s -m 10 "http://localhost:$LOCUST_PORT/stop" >/dev/null
    ok "se detuvo una carga de Locust que seguía corriendo"; sleep 10
  fi
  # Con nodos nuevos, el balanceador de Google tarda unos minutos en registrar los pods como
  # backends (NEG): mientras tanto responde timeout (000), 502 o 503. Se espera hasta 15 min.
  for ruta in "/grpc-$CARNET" "/dapr-$CARNET"; do
    local codigo inicio=$SECONDS
    while codigo=$(post "$ruta"); [ "$codigo" != 200 ] && [ $((SECONDS - inicio)) -lt 900 ]; do
      echo "  … $ruta responde $codigo, el balanceador aún registra los backends ($((SECONDS - inicio)) s)"
      sleep 15
    done
    [ "$codigo" = 200 ] && ok "POST http://$(gateway_ip)$ruta -> 200" || falla "$ruta no responde 200 tras 15 min"
  done

  paso "6. Locust con interfaz web (pestaña 1)"
  if locust_vivo; then
    ok "ya corre en http://localhost:$LOCUST_PORT"
  else
    nohup locust -f locust/locustfile.py --host "http://$(gateway_ip)" --web-port $LOCUST_PORT \
      --users "$USUARIOS" --spawn-rate "$SPAWN" --processes "$PROCESOS" > "$ESTADO/locust.log" 2>&1 &
    echo $! > "$ESTADO/locust.pid"
    for _ in $(seq 1 20); do locust_vivo && break; sleep 1; done
    locust_vivo && ok "http://localhost:$LOCUST_PORT (host $(gateway_ip), $USUARIOS usuarios, $PROCESOS procesos)" || falla "Locust no arrancó: $ESTADO/locust.log"
  fi

  paso "7. Grafana por el Gateway (pestaña 3)"
  # Antes era un kubectl port-forward: con 1000 usuarios se caía (Timeout occurred) y el
  # dashboard daba "Failed to fetch". La ruta grafana-route tarda unos minutos en propagarse.
  inicio=$SECONDS
  until grafana_vivo || [ $((SECONDS - inicio)) -ge 600 ]; do
    echo "  … $(grafana_url) aún no responde, el balanceador registra la ruta ($((SECONDS - inicio)) s)"
    sleep 15
  done
  grafana_vivo && ok "$(grafana_url)/d/mumnk8s" || falla "Grafana no responde por el Gateway tras 10 min"

  paso "8. Pestañas del navegador"
  source "$SECRETS_DIR/grafana.env"
  open "http://localhost:$LOCUST_PORT"                 # 1: Locust
  open "https://$ZOT_DOMAIN/home"                     # 2: catálogo de Zot
  open "$(grafana_url)/d/mumnk8s?refresh=5s"         # 3: dashboard
  ok "Grafana: usuario $GRAFANA_USER / clave $GRAFANA_PASS"

  titulo "LISTO: sistema desplegado y pestañas abiertas"
}

detener() {
  locust_vivo && curl -s -m 5 "http://localhost:$LOCUST_PORT/stop" >/dev/null && ok "carga detenida"
  for f in locust grafana-pf; do
    if [ -f "$ESTADO/$f.pid" ]; then
      pkill -P "$(cat "$ESTADO/$f.pid")" 2>/dev/null || true
      kill "$(cat "$ESTADO/$f.pid")" 2>/dev/null || true
      rm -f "$ESTADO/$f.pid"; ok "$f cerrado"
    fi
  done
  echo "  (GCP sigue encendido: ./scripts/apagar.sh para apagarlo)"
}

vueltas() {
  vuelta1; pausa_vuelta "fin de la vuelta 1"
  vuelta2; pausa_vuelta "fin de la vuelta 2"
  vuelta3; pausa_vuelta "fin de la vuelta 3"
  vuelta4; pausa_vuelta "fin de la vuelta 4"
  extra
  titulo "FIN DE LA REVISIÓN"
  echo "  La carga de Locust sigue activa para el dashboard. Al terminar el día:"
  echo "    ./scripts/90_calificacion.sh detener && ./scripts/apagar.sh"
}

case "${1:-completo}" in
  completo) levantar; pausa_vuelta "sistema listo, empieza la vuelta 1"; vueltas ;;
  levantar) levantar ;;
  vuelta1)  vuelta1 ;;
  vuelta2)  vuelta2 ;;
  vuelta3)  vuelta3 ;;
  vuelta4)  vuelta4 ;;
  extra)    extra ;;
  todo)     vueltas ;;
  detener)  detener ;;
  *) sed -n '2,33p' "$SCRIPT" | sed 's/^# \{0,1\}//'; [ "${1:-}" = ayuda ] || exit 1 ;;
esac
