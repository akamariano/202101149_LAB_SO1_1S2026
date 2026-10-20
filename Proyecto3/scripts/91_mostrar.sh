#!/usr/bin/env bash
# Muestra, vuelta por vuelta, lo que la guía de calificación (pruebas/Official/Guía Proyecto 3 .pdf)
# pide ver. NO levanta nada: no enciende GCP, no aplica manifiestos, no abre Locust ni el
# port-forward y no inicia la carga. Solo imprime y consulta. Si el clúster está apagado, imprime
# lo que pide la guía para cada vuelta y avisa.
#
#   ./scripts/91_mostrar.sh            # preparación + las 4 vueltas + extra
#   ./scripts/91_mostrar.sh guia       # solo el texto de la guía: vueltas y puntos (sin clúster)
#   ./scripts/91_mostrar.sh previo     # indicaciones previas: kubectl hacia GKE y las 3 pestañas
#   ./scripts/91_mostrar.sh vuelta1    # Infraestructura GCP, Zot y Gateway API
#   ./scripts/91_mostrar.sh vuelta2    # Locust, Rust, gRPC client/server y HPA
#   ./scripts/91_mostrar.sh vuelta3    # RabbitMQ, consumer, Operator (CRDs y CRs) y Valkey
#   ./scripts/91_mostrar.sh vuelta4    # Grafana, Falco y manual
#   ./scripts/91_mostrar.sh extra      # flujo Dapr /dapr-<carnet>
#   ./scripts/91_mostrar.sh ayuda      # esta ayuda
#
# Variables opcionales:
#   PAUSA=vuelta|comando|0  como en 90_calificacion.sh (por defecto 0: no espera)
#   SIMULAR=1               hace también las acciones mínimas de la demo: iniciar la carga en
#                           Locust si ya está abierto, cat /etc/shadow (Falco) y un reporte por Dapr
#   DESDE_FALCO=30m         ventana de los logs de Falco
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
source scripts/config.env
source "$SECRETS_DIR/zot.env"

MODO=mostrar
PAUSA="${PAUSA:-0}"
source scripts/lib_calificacion.sh

# Indicaciones previas de la guía (sección 2): qué debe estar abierto antes del turno
previo() {
  titulo "PREPARACIÓN · Indicaciones previas de la guía"
  guia <<EOF
tiempo|antes de que entre el grupo
puntos|requisito: sin sistema desplegado no se califica
pantalla|Pestaña 1: Locust → http://localhost:$LOCUST_PORT
pantalla|Pestaña 2: catálogo de Zot → https://$ZOT_DOMAIN/home
pantalla|Pestaña 3: dashboard de Grafana → http://localhost:$PORT/d/mumnk8s
verifica|Terminal conectada a GCP con kubectl apuntando al clúster de GKE
verifica|Todo desplegado antes del turno: no se compila, despliega ni levanta nada durante él
EOF
  echo
  cmd kubectl config current-context
  check "kubectl apunta al clúster GKE $CLUSTER" 'kubectl config current-context | grep -q "gke_.*_$CLUSTER$"'
  check "Clúster con nodos Ready" 'cluster_ok'
  check "Pestaña 1: Locust responde en localhost:$LOCUST_PORT" 'locust_vivo'
  check "Pestaña 2: Zot responde por HTTPS" 'curl -s -m 10 -o /dev/null -w "%{http_code}" https://$ZOT_DOMAIN/v2/ | grep -qE "200|401"'
  check "Pestaña 3: Grafana responde en localhost:$PORT" 'grafana_vivo'
  check "Gateway con IP pública asignada" '[ -n "$(gateway_ip)" ]'
  resumen "la preparación"
  echo "  ${D}Lo que falte se levanta con ./scripts/90_calificacion.sh levantar${N}"
}

# Solo el texto de la guía, sin consultar el clúster
solo_guia() {
  cluster_ok() { return 1; }   # fuerza a cada vuelta a imprimir solo lo que pide la guía
  sin_cluster() { return 0; }
  vuelta1; vuelta2; vuelta3; vuelta4; extra
  titulo "DISTRIBUCIÓN DE PUNTOS (sección 5 de la guía)"
  cat <<EOF
  Gateway API 5 · API Rust 5 · Servicios Go 10 · Zot 10 · RabbitMQ y consumer 10 · Valkey 10
  Grafana 20 · Falco 15 · Pruebas de carga, HPA y réplicas 3 · Manual y guía 2
  Respuestas a preguntas 5 · Modificar y justificar código en revisión 5      Total 100
EOF
}

todo() {
  previo;  pausa_vuelta "fin de la preparación"
  vuelta1; pausa_vuelta "fin de la vuelta 1"
  vuelta2; pausa_vuelta "fin de la vuelta 2"
  vuelta3; pausa_vuelta "fin de la vuelta 3"
  vuelta4; pausa_vuelta "fin de la vuelta 4"
  extra
  titulo "FIN"
}

case "${1:-todo}" in
  todo)    todo ;;
  guia)    solo_guia ;;
  previo)  previo ;;
  vuelta1) vuelta1 ;;
  vuelta2) vuelta2 ;;
  vuelta3) vuelta3 ;;
  vuelta4) vuelta4 ;;
  extra)   extra ;;
  *) sed -n '2,21p' "$SCRIPT" | sed 's/^# \{0,1\}//'; [ "${1:-}" = ayuda ] || exit 1 ;;
esac
