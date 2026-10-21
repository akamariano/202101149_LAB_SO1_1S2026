# Vueltas de la calificación, compartidas por 90_calificacion.sh y 91_mostrar.sh.
# Cada vuelta sigue el orden de pruebas/Official/Guía Proyecto 3 .pdf:
#   1. imprime lo que pide la guía (pantallas, comandos, verificaciones y puntos)
#   2. ejecuta los comandos de la guía, rotulados [Guía n/N], y después la evidencia adicional
#   3. cierra con un resumen ✔/✘ de las verificaciones de la guía, comprobadas contra el clúster
#
# MODO=calificar (90_calificacion.sh): hace las acciones de la demo (iniciar la carga en Locust,
#   cat /etc/shadow para Falco, un reporte por /dapr-<carnet>).
# MODO=mostrar (91_mostrar.sh): solo lee. Las acciones se omiten salvo con SIMULAR=1.
#
# Uso: source scripts/lib_calificacion.sh (después de config.env y .secrets/zot.env)

NS=mumnk8s
GRUPO=mumnk8s.so1.usac
PORT="${PORT:-3300}"
LOCUST_PORT=8089
USUARIOS="${USUARIOS:-1000}"   # la guía de calificación pide 1000 usuarios
SPAWN="${SPAWN:-50}"           # usuarios nuevos por segundo (1000 en 20 s)
PROCESOS="${PROCESOS:-4}"
MODO="${MODO:-calificar}"
SIMULAR="${SIMULAR:-0}"
PAUSA="${PAUSA:-vuelta}"
# País asignado según el último dígito del carnet (enunciado 4.3.2)
case ${CARNET: -1} in 0|1) PAIS=USA ;; 2|3) PAIS=RUS ;; 4|5) PAIS=CHN ;; 6|7) PAIS=ESP ;; *) PAIS=GTM ;; esac
# Ventana de los logs de Falco: en la demo, solo la alerta recién generada
[ "$MODO" = calificar ] && DESDE_FALCO="${DESDE_FALCO:-1m}" || DESDE_FALCO="${DESDE_FALCO:-30m}"

# ---------- salida ----------
B=$'\e[1m'; D=$'\e[2m'; C=$'\e[36m'; V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; M=$'\e[35m'; N=$'\e[0m'
titulo() { echo; echo "${B}════════════ $* ════════════${N}"; }
paso()   { echo; echo "${B}==> $*${N}"; }
ok()     { echo "  ${V}✔${N} $*"; }
falla()  { echo "  ${R}✘ $*${N}"; }
aviso()  { echo "  ${A}!${N} $*"; }
esperar_enter() { [ -t 0 ] && read -r -p "  ${C}[$1 — Enter para seguir]${N} " _ || true; }
pausa()        { [ "$PAUSA" = "comando" ] && esperar_enter "siguiente comando"; return 0; }
pausa_vuelta() { [ "$PAUSA" != "0" ] && esperar_enter "$1"; return 0; }

# Muestra el comando tal cual (para que el auxiliar lo lea) y lo ejecuta
cmd() { echo "${C}\$ $*${N}"; eval "$@" || true; pausa; }
# Encabezado de un comando que la guía pide literalmente: guia_cmd 1 2 "Verificar clúster GKE"
guia_cmd() { echo; echo "${M}${B}── [Guía, comando $1 de $2] $3${N}"; }
# Encabezado de evidencia que la guía no pide literalmente pero respalda una verificación
evidencia() { echo; echo "${B}── [Evidencia adicional] $*${N}"; }
# Qué debe ver el auxiliar en la salida anterior
se_ve() { echo "  ${D}↳ Se ve:${N} $*"; }
# Una acción (cambia algo) solo corre en MODO=calificar o con SIMULAR=1
puede_actuar() { [ "$MODO" = calificar ] || [ "$SIMULAR" = 1 ]; }
omitida() { aviso "omitido en modo solo lectura: $* (SIMULAR=1 para hacerlo, o ./scripts/90_calificacion.sh)"; }

# Bloque con lo que pide la guía para la vuelta. Lee líneas "clave|texto" de la entrada estándar:
#   tiempo|…  puntos|…  pantalla|…  comando|…  verifica|…
guia() {
  local tiempo="" puntos="" linea clave resto
  local pantallas=() comandos=() verifs=()
  while IFS= read -r linea; do
    clave=${linea%%|*}; resto=${linea#*|}
    case $clave in
      tiempo)   tiempo=$resto ;;
      puntos)   puntos=$resto ;;
      pantalla) pantallas+=("$resto") ;;
      comando)  comandos+=("$resto") ;;
      verifica) verifs+=("$resto") ;;
    esac
  done
  echo "  ${D}Guía oficial (pruebas/Official/Guía Proyecto 3 .pdf) · $tiempo · Puntos: $puntos${N}"
  if [ ${#pantallas[@]} -gt 0 ]; then
    echo "  ${B}Pantallas del navegador:${N}"
    for l in "${pantallas[@]}"; do echo "    • $l"; done
  fi
  if [ ${#comandos[@]} -gt 0 ]; then
    echo "  ${B}Comandos que pide la guía:${N}"
    local i=1; for l in "${comandos[@]}"; do echo "    $i. $l"; i=$((i + 1)); done
  fi
  echo "  ${B}Verificaciones del auxiliar:${N}"
  for l in "${verifs[@]}"; do echo "    • $l"; done
}

# Verificaciones automáticas: check "descripción" 'condición' (se evalúa en silencio, en una subshell)
RESUMEN=()
check() {
  # Con la carga de Locust activa, una llamada a kubectl puede fallar por timeout: se reintenta
  local i; for i in 1 2 3; do
    if ( eval "$2" ) >/dev/null 2>&1; then RESUMEN+=("${V}✔${N} $1"); return; fi
    sleep 3
  done
  RESUMEN+=("${R}✘${N} $1")
}
resumen() {
  echo; echo "${B}── Resumen de $1 (verificaciones de la guía, comprobadas en el clúster)${N}"
  local l; for l in ${RESUMEN[@]+"${RESUMEN[@]}"}; do echo "  $l"; done
  RESUMEN=()
}

# ---------- consultas al clúster ----------
# Con la carga de Locust activa, kubectl puede dar timeout una vez: se reintenta antes de
# concluir que el clúster está apagado (si no, la vuelta entera se saltaría)
cluster_ok() {
  local i; for i in 1 2 3; do
    [ "$(kubectl get nodes --request-timeout=10s --no-headers 2>/dev/null | grep -c ' Ready')" -gt 0 ] && return 0
    sleep 3
  done
  return 1
}
gateway_ip() {
  local i ip; for i in 1 2 3; do
    ip=$(kubectl -n $NS get gateway mumnk8s-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null) || true
    [ -n "$ip" ] && break; sleep 3
  done
  echo "$ip"
}
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
vk() { kubectl exec "$(pod_valkey)" -n $NS -- valkey-cli "$@" 2>/dev/null; }
# Imágenes de todos los pods del proyecto (incluye operador, Dapr y Falco)
imagenes() {
  local ns
  for ns in $NS mumnk8s-operator-system dapr-system falco; do
    kubectl get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | sort -u
}
# Últimas líneas de un contenedor muestran actividad en los últimos 10 s: "(+N" con N > 0
activo() { kubectl logs -l app="$1" -n $NS -c "$2" --tail=4 2>/dev/null | grep -Eq '\(\+[1-9]'; }

locust_vivo()  { curl -s -m 3 "http://localhost:$LOCUST_PORT/stats/requests" >/dev/null 2>&1; }
locust_carga() { curl -s -m 3 "http://localhost:$LOCUST_PORT/stats/requests" 2>/dev/null | jq -e '.state == "running" and .user_count > 0'; }
locust_estado() {
  curl -s -m 3 "http://localhost:$LOCUST_PORT/stats/requests" \
    | jq -r '"  Locust: \(.state), \(.user_count) usuarios, \(.total_rps|floor) req/s, fallos \(.fail_ratio*100|floor) %"'
}
# Grafana va por el Gateway (no por port-forward, que se cae con la carga de Locust)
grafana_url()  { echo "http://$(gateway_ip)"; }
grafana_vivo() { curl -s -m 15 "$(grafana_url)/api/health" 2>/dev/null | grep -q database; }

# Si el clúster no tiene nodos, la vuelta solo imprime lo que pide la guía
sin_cluster() {
  cluster_ok && return 1
  echo; falla "El clúster no tiene nodos listos: solo se muestra lo que pide la guía."
  echo "    Para levantarlo: ./scripts/90_calificacion.sh levantar"
}

# ---------- vueltas ----------
vuelta1() {
  titulo "VUELTA 1 · Infraestructura GCP, Registry Zot y Gateway API"
  guia <<EOF
tiempo|5 min (8 alumnos)
puntos|Gateway API 5 · Zot 10
pantalla|Pestaña 2: catálogo de imágenes en Zot → https://$ZOT_DOMAIN/home
comando|kubectl get nodes -o wide
comando|kubectl get gateway,httproute -n $NS
verifica|Despliegue efectivo en un clúster de GKE (GCP)
verifica|Zot alojado en una VM de GCP externa al clúster
verifica|Servicios expuestos con Kubernetes Gateway API en la ruta /grpc-$CARNET
EOF
  sin_cluster && return 0

  guia_cmd 1 2 "Verificar clúster GKE y nodos activos"
  cmd kubectl get nodes -o wide
  se_ve "nodos en estado Ready, máquinas N1 (n1-standard-2) en el node pool de GKE, SO Container-Optimized OS"

  guia_cmd 2 2 "Verificar configuración del Gateway y las rutas"
  cmd kubectl get gateway,httproute -n $NS
  se_ve "Gateway de clase gke-l7-global-external-managed, PROGRAMMED=True, IP pública $(gateway_ip); HTTPRoute grpc-route"

  evidencia "Rutas del HTTPRoute (la que pide la guía es /grpc-$CARNET)"
  cmd "kubectl get httproute grpc-route -n $NS -o jsonpath='{range .spec.rules[*]}{.matches[0].path.value}{\" -> \"}{.backendRefs[0].name}:{.backendRefs[0].port}{\"\\n\"}{end}'"
  evidencia "No se usa Ingress: la exposición es solo con Gateway API"
  cmd "kubectl get ingress -A 2>&1 | head -3"

  evidencia "Zot corre en una VM de GCP, fuera del clúster (la pestaña 2 muestra su catálogo)"
  cmd gcloud compute instances list --filter="name=$ZOT_VM" --format="'table(name,zone.basename(),machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'"
  cmd "curl -s https://$ZOT_DOMAIN/v2/_catalog | jq"
  cmd "echo | openssl s_client -connect $ZOT_DOMAIN:443 -servername $ZOT_DOMAIN 2>/dev/null | openssl x509 -noout -subject -issuer -dates"
  se_ve "certificado de Let's Encrypt válido: Zot se usa por HTTPS"
  evidencia "Todas las imágenes del proyecto se descargan de Zot"
  cmd "imagenes"
  se_ve "todas empiezan con $ZOT_DOMAIN/mumnk8s/…"

  check "Clúster de GKE con nodos Ready" 'cluster_ok'
  check "Nodos con máquinas N1" 'kubectl get nodes -o jsonpath="{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}" | grep -q "^n1-"'
  check "Gateway API programado con IP pública" '[ "$(kubectl get gateway mumnk8s-gateway -n $NS -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}")" = True ]'
  check "HTTPRoute con la ruta /grpc-$CARNET" 'kubectl get httproute -n $NS -o jsonpath="{..path.value}" | grep -q "/grpc-$CARNET"'
  check "Sin Ingress en el clúster" '[ -z "$(kubectl get ingress -A -o name)" ]'
  check "Zot responde por HTTPS y tiene las imágenes" 'curl -s -m 10 https://$ZOT_DOMAIN/v2/_catalog | grep -q mumnk8s/rust-api'
  check "Todas las imágenes del proyecto vienen de Zot" 'imagenes | grep -q . && ! imagenes | grep -v "^$ZOT_DOMAIN/"'
  resumen "la vuelta 1"
}

vuelta2() {
  titulo "VUELTA 2 · Locust, API REST (Rust), gRPC Client/Server (Go) y HPA"
  guia <<EOF
tiempo|5 min (8 alumnos)
puntos|API Rust 5 · Servicios Go 10 · Pruebas de carga/HPA 3
pantalla|Pestaña 1: Locust enviando reportes militares en JSON → http://localhost:$LOCUST_PORT
comando|kubectl get hpa,deployments -n $NS
comando|kubectl logs -l app=api-rust --tail=10   (en este proyecto la etiqueta es app=rust-api, namespace $NS)
verifica|Tráfico activo generado con Locust
verifica|Comunicación Rust (API REST) → Go (gRPC Client) → Go (gRPC Server / Writer)
verifica|HPA en el deployment de Rust (1 a 3 réplicas, CPU > 30 %)
EOF
  sin_cluster && return 0

  paso "Pestaña 1: Locust"
  if locust_vivo; then
    if locust_carga; then
      ok "la carga ya está corriendo"
    elif puede_actuar; then
      echo "  Iniciando la carga: $USUARIOS usuarios ($SPAWN por segundo) contra http://$(gateway_ip)"
      curl -s -m 10 -X POST "http://localhost:$LOCUST_PORT/swarm" \
        -d "user_count=$USUARIOS&spawn_rate=$SPAWN&host=http://$(gateway_ip)" | jq -c '{success, message}' || true
      sleep 30   # los usuarios entran en ~20 s y el HPA mide cada 15 s
    else
      omitida "iniciar la carga en Locust"
    fi
    locust_estado
  elif puede_actuar; then
    aviso "Locust no está corriendo (./scripts/90_calificacion.sh levantar). Se usa headless 120 s."
    locust -f locust/locustfile.py --host "http://$(gateway_ip)" --headless -u "$USUARIOS" -r "$SPAWN" -t 120s --processes "$PROCESOS" --only-summary &
    sleep 20
  else
    falla "Locust no responde en http://localhost:$LOCUST_PORT (se abre con ./scripts/90_calificacion.sh levantar)"
  fi
  echo "  Ejemplo del JSON que envía Locust: $(reporte)"
  echo "  Países, rangos y pausas salen del OCI Artifact mumnk8s/locust-config:v1 (locust/war-config.json)"

  guia_cmd 1 2 "Estado del HPA y pods de la API Rust"
  cmd kubectl get hpa,deployments -n $NS
  se_ve "HPA rust-api con MINPODS 1, MAXPODS 3, objetivo cpu 30 %; con carga, REPLICAS sube de 1 a 3"

  guia_cmd 2 2 "Logs en tiempo real del flujo gRPC (API Rust)"
  cmd kubectl logs -l app=rust-api -n $NS --tail=10 --prefix
  se_ve "cada pod de rust-api resume cada 10 s los reportes reenviados a go-api, sin rechazados ni errores"

  evidencia "Los siguientes saltos del flujo: Rust → go-api (api-rest + grpc-client) → go-writer (grpc-server + rabbit-writer)"
  cmd kubectl logs -l app=go-api -n $NS -c api-rest --tail=3 --prefix
  cmd kubectl logs -l app=go-api -n $NS -c grpc-client --tail=3 --prefix
  se_ve "grpc-client: 'go-writer gRPC=N (+M)' = llamadas gRPC SendReport enviadas a go-writer"
  cmd kubectl logs -l app=go-writer -n $NS -c grpc-server --tail=3 --prefix
  se_ve "grpc-server: 'grpc=N (+M) en 10s' = reportes recibidos por gRPC"
  cmd kubectl logs -l app=go-writer -n $NS -c rabbit-writer --tail=3 --prefix
  se_ve "rabbit-writer: 'publicados=N (+M en 10s)' = mensajes confirmados por RabbitMQ"

  evidencia "Escalado del HPA (1 → 3 réplicas con CPU > 30 %)"
  local muestras=6; [ "$MODO" = mostrar ] && muestras=1
  local i
  for i in $(seq 1 $muestras); do
    kubectl get hpa rust-api -n $NS --no-headers -o custom-columns='N:.metadata.name,CPU:.status.currentMetrics[0].resource.current.averageUtilization,OBJ:.spec.metrics[0].resource.target.averageUtilization,REPLICAS:.status.currentReplicas,DESEADAS:.status.desiredReplicas' \
      | awk -v t="$(date +%H:%M:%S)" '{printf "  %s  cpu=%s%% (objetivo %s%%)  réplicas=%s -> %s\n", t, $2, $3, $4, $5}'
    if [ "$i" -lt $muestras ]; then sleep 15; fi
  done
  cmd kubectl top pods -n $NS -l app=rust-api

  check "Locust corriendo con usuarios activos" 'locust_carga'
  check "HPA de rust-api: 1 a 3 réplicas al 30 % de CPU" '[ "$(kubectl get hpa rust-api -n $NS -o jsonpath="{.spec.minReplicas} {.spec.maxReplicas} {.spec.metrics[0].resource.target.averageUtilization}")" = "1 3 30" ]'
  check "HPA escaló rust-api a más de 1 réplica" '[ "$(kubectl get hpa rust-api -n $NS -o jsonpath="{.status.currentReplicas}")" -gt 1 ]'
  check "go-api con 2 contenedores (api-rest y grpc-client)" 'kubectl get deploy go-api -n $NS -o jsonpath="{.spec.template.spec.containers[*].name}" | grep -q "api-rest grpc-client"'
  check "go-writer con 2 contenedores (grpc-server y rabbit-writer)" 'kubectl get deploy go-writer -n $NS -o jsonpath="{.spec.template.spec.containers[*].name}" | grep -q "grpc-server rabbit-writer"'
  check "Rust → Go gRPC client: grpc-client reenvió en los últimos 10 s" 'activo go-api grpc-client'
  check "gRPC Server recibió en los últimos 10 s" 'activo go-writer grpc-server'
  check "Writer publicó en RabbitMQ en los últimos 10 s" 'activo go-writer rabbit-writer'
  resumen "la vuelta 2"
  [ "$MODO" = calificar ] && locust_vivo && echo "  (la carga sigue corriendo para las vueltas 3 y 4; se detiene con ./scripts/90_calificacion.sh detener)"
  return 0
}

vuelta3() {
  titulo "VUELTA 3 · Broker RabbitMQ, Consumer y Operator SDK (Helm)"
  guia <<EOF
tiempo|5 min (8 alumnos)
puntos|RabbitMQ y consumer 10 · Valkey 10
comando|kubectl get crd
comando|kubectl get valkeyinstances,grafanainstances -n $NS
comando|kubectl get pods -n $NS
comando|kubectl exec -it <pod-valkey> -n $NS -- valkey-cli DBSIZE
verifica|RabbitMQ como broker de mensajería principal
verifica|Operator de Kubernetes con Operator SDK (Helm) ejecutándose
verifica|Valkey y Grafana desplegados como Custom Resources reconciliados por el Operator
verifica|Consumer procesando la cola y guardando en Valkey
EOF
  sin_cluster && return 0
  local pv_plural gf_plural pod
  pv_plural=$(crd_plural Valkey); gf_plural=$(crd_plural Grafana); pod=$(pod_valkey)
  echo "  ${D}(nombres leídos del clúster: CRDs $pv_plural y $gf_plural del grupo $GRUPO; pod primario de Valkey $pod)${N}"

  guia_cmd 1 4 "Custom Resource Definitions del operador"
  cmd kubectl get crd
  cmd "kubectl get crd | grep -E 'NAME|$GRUPO'"
  se_ve "los dos CRDs propios: $pv_plural.$GRUPO y $gf_plural.$GRUPO"

  guia_cmd 2 4 "Instancias creadas (Custom Resources)"
  cmd kubectl get "$pv_plural,$gf_plural" -n $NS
  se_ve "un ValkeyInstance y un GrafanaInstance; el operador los reconcilia con sus charts de Helm"

  guia_cmd 3 4 "Pods de RabbitMQ y del consumer (y del resto del namespace)"
  cmd kubectl get pods -n $NS
  se_ve "rabbitmq-0, consumer-…, $pod (Valkey) y grafana-… en Running"

  guia_cmd 4 4 "Persistencia en Valkey"
  cmd kubectl exec "$pod" -n $NS -- valkey-cli DBSIZE
  se_ve "número de claves > 0: el consumer escribió en Valkey"

  evidencia "El operador (Operator SDK, Helm) y lo que creó a partir de los CRs"
  cmd kubectl get deploy -n mumnk8s-operator-system
  cmd "kubectl get sts,svc,pvc -n $NS -l app.kubernetes.io/instance=$(cr_nombre Valkey)"
  se_ve "StatefulSet, Service y PVC (persistencia) de Valkey, creados por el operador"
  cmd "kubectl get deploy,svc,cm -n $NS -l app.kubernetes.io/instance=$(cr_nombre Grafana)"
  cmd "kubectl get sts $(cr_nombre Valkey) -n $NS -o jsonpath='{.metadata.annotations.meta\\.helm\\.sh/release-name}{\" = release de Helm del operador\\n\"}'"

  evidencia "RabbitMQ (broker principal) y consumer"
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_queues name messages consumers
  se_ve "cola war_reports con consumers > 0 y pocos mensajes pendientes: el consumer la vacía al ritmo de llegada"
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_exchanges name type
  cmd kubectl logs -l app=consumer -n $NS --tail=5 --prefix
  se_ve "'procesados=N (+M en 10s)': mensajes leídos de RabbitMQ y guardados en Valkey"

  evidencia "Datos que el consumer guardó en Valkey"
  cmd "kubectl exec $pod -n $NS -- sh -c 'for k in max:planes min:planes mode:planes max:ships min:ships mode:ships reports:$PAIS; do echo \"\$k = \$(valkey-cli get \$k)\"; done; echo \"top:planes = \$(valkey-cli zrange top:planes 0 4 rev withscores | paste -sd \" \" -)\"; echo \"ts:$PAIS = \$(valkey-cli xlen ts:$PAIS) puntos\"'"

  check "CRDs propios del grupo $GRUPO (Valkey y Grafana)" '[ -n "$(crd_plural Valkey)" ] && [ -n "$(crd_plural Grafana)" ]'
  check "CRs ValkeyInstance y GrafanaInstance creados" '[ -n "$(cr_nombre Valkey)" ] && [ -n "$(cr_nombre Grafana)" ]'
  check "Operador (controller-manager) disponible en el clúster" '[ "$(kubectl get deploy mumnk8s-operator-controller-manager -n mumnk8s-operator-system -o jsonpath="{.status.availableReplicas}")" -ge 1 ]'
  check "Valkey creado por el operador como release de Helm" '[ "$(kubectl get sts "$(cr_nombre Valkey)" -n $NS -o jsonpath="{.metadata.annotations.meta\.helm\.sh/release-name}")" = "$(cr_nombre Valkey)" ]'
  check "PVC de Valkey en Bound (persistencia)" 'kubectl get pvc -n $NS --no-headers | grep "^data-$(cr_nombre Valkey)-" | grep -q Bound'
  check "RabbitMQ corriendo" '[ "$(kubectl get pod rabbitmq-0 -n $NS -o jsonpath="{.status.phase}")" = Running ]'
  check "Cola war_reports con consumers conectados" 'kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_queues name consumers | awk "\$1==\"war_reports\" && \$2>0 {f=1} END {exit !f}"'
  check "Consumer procesando (últimos 10 s)" 'kubectl logs -l app=consumer -n $NS --tail=4 | grep -Eq "\(\+[1-9]"'
  check "Valkey con datos (DBSIZE > 0)" '[ "$(vk DBSIZE)" -gt 0 ]'
  resumen "la vuelta 3"
}

vuelta4() {
  titulo "VUELTA 4 · Dashboard en Grafana, Falco y documentación"
  guia <<EOF
tiempo|8 min (8 alumnos)
puntos|Grafana 20 · Falco 15 · Manual y guía de instalación 2 · Dapr extra
pantalla|Pestaña 3: dashboard de Grafana desplegado por el Operator → $(grafana_url)/d/mumnk8s
verifica|Métricas generales de aviones y barcos: máximo, mínimo y moda
verifica|Top 5 de países con más aviones y con más barcos
verifica|País asignado ($PAIS): serie temporal y total de reportes
verifica|Validación de alertas de Falco en consola (en Grafana es un plus)
verifica|Manual técnico (pruebas de carga, HPA y análisis de réplicas) y guía de instalación
verifica|Extra: flujo con Dapr (/dapr-$CARNET)
EOF
  sin_cluster && return 0

  paso "Pestaña 3: dashboard 'M.U.M.N.K8s Monitoring Dashboard'"
  if grafana_vivo; then
    ok "Grafana responde en $(grafana_url)/d/mumnk8s (refresco cada 5 s)"
  else
    falla "Grafana no responde en $(grafana_url) (ruta grafana-route del Gateway: kubectl apply -f k8s/40-gateway.yaml)"
  fi
  cat <<EOF
  Dónde está cada verificación en el dashboard:
    • Máximo y mínimo  → fila 1: Max./Min. Aviones en Aire, Max./Min. Barcos en Mar
    • Moda             → Moda de Aviones/Barcos (general) y del país asignado ($PAIS)
    • Top 5            → Top 5 Países: Aviones en Aire / Barcos en Mar
    • País asignado    → País Asignado ($PAIS), Reportes Recibidos ($PAIS), Evolución Temporal - $PAIS
    • Falco (plus)     → abajo: Alertas Falco (regla propia y total) y Últimas alertas de Falco
EOF
  evidencia "Grafana es un Custom Resource del operador"
  cmd kubectl get "$(crd_plural Grafana)" -n $NS
  evidencia "Los valores que muestra el dashboard, leídos directo de Valkey"
  cmd "kubectl exec $(pod_valkey) -n $NS -- sh -c 'echo \"aviones: max=\$(valkey-cli get max:planes) min=\$(valkey-cli get min:planes) moda=\$(valkey-cli get mode:planes)\"; echo \"barcos:  max=\$(valkey-cli get max:ships) min=\$(valkey-cli get min:ships) moda=\$(valkey-cli get mode:ships)\"; echo \"top 5 aviones: \$(valkey-cli zrange top:planes 0 4 rev withscores | paste -sd \" \" -)\"; echo \"top 5 barcos:  \$(valkey-cli zrange top:ships 0 4 rev withscores | paste -sd \" \" -)\"; echo \"$PAIS: \$(valkey-cli get reports:$PAIS) reportes, \$(valkey-cli xlen ts:$PAIS) puntos en la serie\"'"

  paso "Falco: DaemonSet, regla propia y alerta"
  cmd kubectl get pods -n falco -o wide
  se_ve "un pod de Falco por nodo (DaemonSet) en Running"
  cmd "kubectl get cm -n falco falco-rules -o jsonpath='{.data.reglas-mumnk8s\\.yaml}' 2>/dev/null || cat k8s/falco/reglas-mumnk8s.yaml"
  se_ve "la regla propia 'Lectura de archivo sensible en pods de MUMNK8s' (/etc/shadow, /etc/gshadow, /app/secretos)"
  local p; p=$(kubectl -n $NS get pods -l app=rust-api -o jsonpath='{.items[0].metadata.name}')
  if puede_actuar; then
    evidencia "Simulación de la amenaza: leer /etc/shadow dentro de un pod de la API Rust"
    cmd kubectl exec "$p" -n $NS -- cat /etc/shadow
    se_ve "Permission denied: el contenedor corre como el usuario app, pero el intento ya es una syscall openat"
    # Con la carga de Locust, el exec puede no llegar al pod (timeout): se reintenta hasta ver
    # el "Permission denied" y luego se espera a que la alerta aparezca en los logs de Falco
    local i
    for i in 1 2 3; do
      DESDE=$DESDE_FALCO ./scripts/70_falco.sh logs 2>/dev/null | grep -q "pod=$p" && break
      kubectl exec "$p" -n $NS -- cat /etc/shadow 2>&1 | grep -q "Permission denied" && break
      sleep 3
    done
    for i in $(seq 1 10); do
      DESDE=$DESDE_FALCO ./scripts/70_falco.sh logs 2>/dev/null | grep -q "pod=$p" && break
      sleep 3
    done
  else
    omitida "kubectl exec $p -- cat /etc/shadow"
  fi
  evidencia "La alerta en consola: logs de Falco (todos los nodos, últimos $DESDE_FALCO), lo que pide la guía"
  cmd "DESDE=$DESDE_FALCO ./scripts/70_falco.sh logs"
  se_ve "Critical [MUMNK8s] Intento de lectura de archivo sensible (archivo=/etc/shadow … padre=containerd-shim … pod=$p)"
  evidencia "Plus: la misma alerta en Grafana, Falco (http_output) → falco-bridge → Valkey"
  cmd kubectl logs -l app=falco-bridge -n $NS --tail=3
  cmd "kubectl exec $(pod_valkey) -n $NS -- sh -c 'echo \"falco:total:mumnk8s = \$(valkey-cli get falco:total:mumnk8s)\"; valkey-cli xrevrange falco:alertas + - count 1'"

  paso "Manual técnico y guía de instalación (en el repositorio)"
  cat <<EOF
  README.md            manual técnico en Markdown
    sección 2  arquitectura · 6 flujo de datos · 7 Gateway API · 8 REST y gRPC · 9 RabbitMQ
    sección 10 operador (CRDs, charts, reconciliación) · 11 HPA · 12 OCI Artifact · 13 dashboard
    sección 14 pruebas de carga y análisis de réplicas (1 vs. 2 en go-writer y Valkey)
    sección 15 Dapr y Falco (regla YAML y alertas) · 16 problemas · 17 conclusiones
  GuiaDeInstalacion.md guía paso a paso (secciones 0-13)
EOF

  check "Grafana accesible (pestaña 3)" 'grafana_vivo'
  check "Grafana desplegado por el operador (GrafanaInstance)" '[ -n "$(cr_nombre Grafana)" ]'
  check "Máximo, mínimo y moda de aviones y barcos en Valkey" '[ "$(vk MGET max:planes min:planes mode:planes max:ships min:ships mode:ships | grep -c .)" -eq 6 ]'
  check "Top 5 de países (aviones y barcos)" '[ "$(vk ZCARD top:planes)" -ge 5 ] && [ "$(vk ZCARD top:ships)" -ge 5 ]'
  check "País asignado $PAIS: serie temporal y total de reportes" '[ "$(vk XLEN ts:$PAIS)" -gt 0 ] && [ "$(vk GET reports:$PAIS)" -gt 0 ]'
  check "Falco: un pod listo por nodo" '[ "$(kubectl get ds -n falco -l app.kubernetes.io/name=falco -o jsonpath="{.items[0].status.numberReady}")" = "$(kubectl get nodes --no-headers | wc -l | tr -d " ")" ]'
  check "Falco: regla propia cargada" 'kubectl get cm -n falco -o yaml | grep -q "MUMNK8s"'
  check "Falco: alerta de la regla propia en consola (últimos 30 min)" 'DESDE=30m ./scripts/70_falco.sh logs | grep -q "MUMNK8s"'
  check "Plus: alertas de Falco registradas para Grafana" '[ "$(vk GET falco:total:mumnk8s)" -gt 0 ]'
  check "Manual técnico y guía de instalación en Markdown" '[ -s README.md ] && [ -s GuiaDeInstalacion.md ]'
  resumen "la vuelta 4"
}

extra() {
  titulo "EXTRA · Flujo con Dapr (/dapr-$CARNET)"
  guia <<EOF
tiempo|dentro de la vuelta 4
puntos|puntos extra
verifica|Verificación opcional del flujo con Dapr por la ruta /dapr-$CARNET
EOF
  sin_cluster && return 0
  evidencia "Plano de control de Dapr y componente pub/sub sobre RabbitMQ"
  cmd kubectl get pods -n dapr-system
  cmd kubectl get components.dapr.io -n $NS
  evidencia "Sidecar daprd en go-api (publica) y go-writer (suscrito)"
  cmd "kubectl get pods -n $NS -l 'app in (go-api,go-writer)' -o custom-columns='POD:.metadata.name,LISTOS:.status.containerStatuses[*].ready,CONTENEDORES:.spec.containers[*].name'"
  se_ve "3 contenedores por pod: los 2 del servicio y daprd"
  if puede_actuar; then
    evidencia "Un reporte por /dapr-$CARNET"
    cmd "curl -s -w '  (HTTP %{http_code})\\n' -H 'Content-Type: application/json' -d '$(reporte)' http://$(gateway_ip)/dapr-$CARNET"
    sleep 11
  else
    omitida "enviar un reporte por /dapr-$CARNET"
  fi
  cmd kubectl logs -l app=go-api -n $NS -c grpc-client --tail=3 --prefix
  se_ve "'Dapr pub/sub=N (+M)': go-api publicó con el SDK de Dapr"
  cmd "kubectl logs -l app=go-writer -n $NS -c grpc-server --tail=20 | grep -i dapr | tail -3"
  se_ve "go-writer recibió el evento por la suscripción de Dapr y lo pasó al writer"
  cmd kubectl exec rabbitmq-0 -n $NS -- rabbitmqctl -q list_queues name messages consumers

  check "Plano de control de Dapr listo" '! kubectl get pods -n dapr-system --no-headers | grep -v Running'
  check "Componente pub/sub de Dapr en $NS" 'kubectl get components.dapr.io -n $NS -o name | grep -q .'
  check "go-api y go-writer con sidecar daprd" 'for d in go-api go-writer; do kubectl get pods -n $NS -l app=$d -o jsonpath="{.items[*].spec.containers[*].name}" | grep -qw daprd || exit 1; done'
  check "HTTPRoute con la ruta /dapr-$CARNET" 'kubectl get httproute -n $NS -o jsonpath="{..path.value}" | grep -q "/dapr-$CARNET"'
  resumen "el extra (Dapr)"
}
