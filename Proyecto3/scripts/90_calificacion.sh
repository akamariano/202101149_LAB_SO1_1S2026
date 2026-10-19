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
# Variables opcionales:
#   PAUSA=vuelta  espera Enter entre vueltas (por defecto)
#   PAUSA=comando espera Enter después de cada comando
#   PAUSA=0       no espera nunca
#   USUARIOS=200  usuarios de Locust en la vuelta 2 (~450 req/s: el HPA escala de 1 a 3, 0 fallos)
#   ESPERA=a,b    pausa en segundos entre reportes de cada usuario (por defecto la del OCI Artifact)
#   PROCESOS=2    procesos de Locust
# Con 2000 usuarios desde una red doméstica, el router se queda sin entradas NAT (2000 conexiones
# abiertas a la vez): hubo timeouts de conexión aunque el clúster estaba ocioso (sección 16).
#   PORT=3300     puerto local de Grafana
#
# Los nombres de los CRDs, de los CRs y del pod de Valkey NO están fijos: se leen del clúster
# (grupo mumnk8s.so1.usac), así que el script sigue sirviendo si se renombra el CR o el kind.
set -euo pipefail
# Ruta absoluta del script: después del cd, "$0" relativo (./90_calificacion.sh) ya no existe
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
source scripts/config.env
source "$SECRETS_DIR/zot.env"

NS=mumnk8s
GRUPO=mumnk8s.so1.usac
PORT="${PORT:-3300}"
LOCUST_PORT=8089
USUARIOS="${USUARIOS:-200}"
SPAWN="${SPAWN:-20}"           # usuarios nuevos por segundo (200 en 10 s)
export ESPERA="${ESPERA:-}"    # vacío: Locust usa wait_time_s del OCI Artifact
PROCESOS="${PROCESOS:-2}"
ESTADO="$P3_ROOT/.calificacion"   # PIDs y logs de los procesos en segundo plano (ignorado por git)
mkdir -p "$ESTADO"

# ---------- utilidades ----------
B=$'\e[1m'; C=$'\e[36m'; V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; N=$'\e[0m'
titulo() { echo; echo "${B}════════ $* ════════${N}"; }
paso()   { echo; echo "${B}==> $*${N}"; }
ok()     { echo "  ${V}✔${N} $*"; }
falla()  { echo "  ${R}✘ $*${N}"; }
aviso()  { echo "  ${A}!${N} $*"; }
PAUSA="${PAUSA:-vuelta}"
esperar_enter() { [ -t 0 ] && read -r -p "  ${C}[$1 — Enter para seguir]${N} " _ || true; }
pausa()        { [ "$PAUSA" = "comando" ] && esperar_enter "siguiente comando"; return 0; }
pausa_vuelta() { [ "$PAUSA" != "0" ] && esperar_enter "$1"; return 0; }
# Muestra el comando tal cual (para que el auxiliar lo lea) y lo ejecuta
cmd() { echo; echo "${C}\$ $*${N}"; eval "$@" || true; pausa; }

gateway_ip() { kubectl -n $NS get gateway mumnk8s-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null; }
reporte()    { printf '{"country":"GTM","warplanes_in_air":%d,"warships_in_water":%d,"timestamp":"%s"}' \
                 $((RANDOM % 51)) $((RANDOM % 31)) "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
post()       { curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Content-Type: application/json' -d "$(reporte)" "http://$(gateway_ip)$1"; }

# Plural del CRD del grupo cuyo kind contiene $1 (Valkey -> valkeyinstances)
crd_plural() {
  kubectl get crd -o jsonpath="{range .items[?(@.spec.group==\"$GRUPO\")]}{.spec.names.kind} {.spec.names.plural}{\"\\n\"}{end}" \
    | awk -v k="$1" 'tolower($1) ~ tolower(k) {print $2; exit}'
}
# Nombre del primer CR de ese CRD
cr_nombre() { kubectl -n $NS get "$(crd_plural "$1")" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
# Pod primario de Valkey: el operador usa el nombre del CR como release, el primario es el índice 0
pod_valkey() {
  local cr; cr=$(cr_nombre Valkey)
  kubectl -n $NS get pods -l "app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$cr" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | head -1
}

locust_vivo()  { curl -s -m 3 "http://localhost:$LOCUST_PORT/stats/requests" >/dev/null 2>&1; }
grafana_vivo() { curl -s -m 3 "http://localhost:$PORT/api/health" 2>/dev/null | grep -q database; }

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

  paso "7. Port-forward a Grafana (pestaña 3)"
  if grafana_vivo; then
    ok "ya responde en http://localhost:$PORT"
  else
    # En un bucle: si el pod de Grafana se reinicia, el port-forward se vuelve a abrir solo
    nohup bash -c "while true; do kubectl -n $NS port-forward svc/grafana $PORT:80; sleep 2; done" \
      > "$ESTADO/grafana-pf.log" 2>&1 &
    echo $! > "$ESTADO/grafana-pf.pid"
    for _ in $(seq 1 20); do grafana_vivo && break; sleep 1; done
    grafana_vivo && ok "http://localhost:$PORT" || falla "Grafana no responde: $ESTADO/grafana-pf.log"
  fi

  paso "8. Pestañas del navegador"
  source "$SECRETS_DIR/grafana.env"
  open "http://localhost:$LOCUST_PORT"                 # 1: Locust
  open "https://$ZOT_DOMAIN/home"                     # 2: catálogo de Zot
  open "http://localhost:$PORT/d/mumnk8s?refresh=5s"  # 3: dashboard
  ok "Grafana: usuario $GRAFANA_USER / clave $GRAFANA_PASS"

  titulo "LISTO: sistema desplegado y pestañas abiertas"
}

# ---------- vueltas ----------
vuelta1() {
  titulo "VUELTA 1: Infraestructura GCP, Zot y Gateway API"
  cmd kubectl get nodes -o wide
  cmd kubectl get gateway,httproute -n $NS
  cmd "kubectl get httproute grpc-route -n $NS -o jsonpath='{range .spec.rules[*]}{.matches[0].path.value}{\" -> \"}{.backendRefs[0].name}:{.backendRefs[0].port}{\"\\n\"}{end}'"
  cmd "kubectl get ingress -A 2>&1 | head -3   # no se usa Ingress"
  paso "Zot en una VM de GCP, fuera del clúster"
  cmd gcloud compute instances list --filter="name=$ZOT_VM" --format="'table(name,zone.basename(),machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'"
  cmd "curl -s https://$ZOT_DOMAIN/v2/_catalog | jq"
  cmd "echo | openssl s_client -connect $ZOT_DOMAIN:443 -servername $ZOT_DOMAIN 2>/dev/null | openssl x509 -noout -subject -issuer -dates"
  cmd "kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{end}' | sort -u | grep -v -E 'gke.gcr.io|gcr.io/gke|registry.k8s.io'   # imágenes del proyecto: todas desde Zot"
}

vuelta2() {
  titulo "VUELTA 2: Locust, Rust, gRPC client/server y HPA"
  if locust_vivo; then
    paso "Iniciando la carga en Locust ($USUARIOS usuarios) — se ve en la pestaña 1"
    curl -s -m 10 -X POST "http://localhost:$LOCUST_PORT/swarm" \
      -d "user_count=$USUARIOS&spawn_rate=$SPAWN&host=http://$(gateway_ip)" | jq -c '{success, message}' || true
  else
    aviso "Locust no está corriendo (./scripts/90_calificacion.sh levantar). Se usa headless 60 s."
    locust -f locust/locustfile.py --host "http://$(gateway_ip)" --headless -u "$USUARIOS" -r "$SPAWN" -t 120s --processes "$PROCESOS" --only-summary &
  fi
  echo "  Ejemplo del JSON que envía Locust: $(reporte)"
  sleep 20   # los usuarios entran en ~10 s y el HPA mide cada 15 s
  cmd kubectl get hpa,deployments -n $NS
  cmd kubectl logs -l app=rust-api -n $NS --tail=10 --prefix
  paso "Siguientes saltos: Go gRPC client (go-api) -> Go gRPC server + writer (go-writer)"
  cmd kubectl logs -l app=go-api -n $NS -c grpc-client --tail=5 --prefix
  cmd kubectl logs -l app=go-writer -n $NS -c grpc-server --tail=5 --prefix
  cmd kubectl logs -l app=go-writer -n $NS -c rabbit-writer --tail=5 --prefix
  paso "Escalado del HPA (1 -> 3 réplicas con CPU > 30 %), una muestra cada 15 s"
  for _ in 1 2 3 4 5 6; do
    kubectl get hpa rust-api -n $NS --no-headers -o custom-columns='HORA:.metadata.name,CPU:.status.currentMetrics[0].resource.current.averageUtilization,OBJ:.spec.metrics[0].resource.target.averageUtilization,REPLICAS:.status.currentReplicas,DESEADAS:.status.desiredReplicas' \
      | awk -v t="$(date +%H:%M:%S)" '{printf "  %s  cpu=%s%% (objetivo %s%%)  réplicas=%s -> %s\n", t, $2, $3, $4, $5}'
    sleep 15
  done
  cmd kubectl top pods -n $NS -l app=rust-api
  if locust_vivo; then
    curl -s "http://localhost:$LOCUST_PORT/stats/requests" \
      | jq -r '"  Locust: \(.state), \(.user_count) usuarios, \(.total_rps|floor) req/s, fallos \(.fail_ratio*100|floor) %"'
    echo "  (la carga sigue corriendo para la vuelta 4; se detiene con: ./scripts/90_calificacion.sh detener)"
  fi
}

vuelta3() {
  titulo "VUELTA 3: RabbitMQ, consumer, Operator SDK (Helm) y Valkey"
  local pv_plural gf_plural pod
  pv_plural=$(crd_plural Valkey); gf_plural=$(crd_plural Grafana); pod=$(pod_valkey)
  echo "  CRDs del grupo $GRUPO en este clúster: $pv_plural, $gf_plural (pod primario de Valkey: $pod)"
  cmd kubectl get crd
  cmd "kubectl get crd | grep -E 'NAME|$GRUPO'   # los CRDs propios del operador"
  cmd kubectl get "$pv_plural,$gf_plural" -n $NS
  cmd kubectl get pods -n $NS
  cmd kubectl exec "$pod" -n $NS -- valkey-cli DBSIZE
  paso "Operador: el controlador y lo que creó a partir de los CRs"
  cmd kubectl get deploy -n mumnk8s-operator-system
  cmd "kubectl get sts,deploy,svc,cm,pvc -n $NS -l app.kubernetes.io/instance=$(cr_nombre Valkey)"
  cmd "kubectl get deploy,svc,cm -n $NS -l app.kubernetes.io/instance=$(cr_nombre Grafana)"
  cmd "kubectl get sts $(cr_nombre Valkey) -n $NS -o jsonpath='{.metadata.annotations.meta\\.helm\\.sh/release-name}{\" (release Helm del operador)\\n\"}'"
  paso "RabbitMQ (broker principal) y consumer"
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_queues name messages consumers
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_exchanges name type
  cmd kubectl logs -l app=consumer -n $NS --tail=5 --prefix
  paso "Datos en Valkey"
  cmd "kubectl exec $pod -n $NS -- sh -c 'for k in max:planes min:planes mode:planes max:ships min:ships mode:ships reports:GTM; do echo \"\$k = \$(valkey-cli get \$k)\"; done; echo \"top:planes = \$(valkey-cli zrange top:planes 0 4 rev withscores | paste -sd \" \" -)\"; echo \"ts:GTM = \$(valkey-cli xlen ts:GTM) puntos\"'"
}

vuelta4() {
  titulo "VUELTA 4: Grafana, Falco y manual"
  if grafana_vivo; then
    ok "Dashboard en la pestaña 3 (http://localhost:$PORT/d/mumnk8s): máx./mín./moda de aviones y barcos, top 5, serie y total de GTM"
  else
    aviso "Grafana no responde en localhost:$PORT (./scripts/90_calificacion.sh levantar)"
  fi
  cmd kubectl get "$(crd_plural Grafana)" -n $NS
  paso "Falco: DaemonSet, regla propia y simulación de la amenaza"
  cmd kubectl get pods -n falco -o wide
  cmd "kubectl get cm -n falco falco-rules -o jsonpath='{.data.reglas-mumnk8s\\.yaml}' 2>/dev/null || cat k8s/falco/reglas-mumnk8s.yaml"
  local p; p=$(kubectl -n $NS get pods -l app=rust-api -o jsonpath='{.items[0].metadata.name}')
  cmd kubectl exec "$p" -n $NS -- cat /etc/shadow
  sleep 3
  cmd "DESDE=1m ./scripts/70_falco.sh logs   # alertas de todos los nodos en el último minuto"
  paso "La misma alerta en Grafana: Falco (http_output) -> falco-bridge -> Valkey -> panel 'Últimas alertas de Falco'"
  cmd kubectl logs -l app=falco-bridge -n $NS --tail=3
  cmd "kubectl exec $(pod_valkey) -n $NS -- sh -c 'echo \"falco:total:mumnk8s = \$(valkey-cli get falco:total:mumnk8s)\"; valkey-cli xrevrange falco:alertas + - count 1'"
  ok "Panel en el dashboard (pestaña 3), abajo: contadores y tabla de las últimas alertas"
  paso "Manual técnico y guía de instalación"
  echo "  README.md: sección 11 (HPA), 14 (pruebas de carga y análisis de réplicas), 15.2 (Falco)"
  echo "  GuiaDeInstalacion.md"
}

extra() {
  titulo "EXTRA: flujo Dapr /dapr-$CARNET"
  cmd kubectl get pods -n dapr-system
  cmd kubectl get components.dapr.io -n $NS
  cmd "kubectl get pods -n $NS -l 'app in (go-api,go-writer)' -o custom-columns='POD:.metadata.name,LISTOS:.status.containerStatuses[*].ready,CONTENEDORES:.spec.containers[*].name'"
  cmd "curl -s -w '  (HTTP %{http_code})\\n' -H 'Content-Type: application/json' -d '$(reporte)' http://$(gateway_ip)/dapr-$CARNET"
  sleep 11
  cmd kubectl logs -l app=go-api -n $NS -c grpc-client --tail=3 --prefix
  cmd "kubectl logs -l app=go-writer -n $NS -c grpc-server --tail=20 | grep -i dapr | tail -3"
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_queues name messages consumers
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
  *) sed -n '2,25p' "$SCRIPT" | sed 's/^# \{0,1\}//'; [ "${1:-}" = ayuda ] || exit 1 ;;
esac
