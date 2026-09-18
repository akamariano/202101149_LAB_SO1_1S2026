#!/bin/bash
# Script de demostracion para la Guia de Calificacion del Proyecto 2 (SO1 202101149)
# Recorre las vueltas 1, 2 y 3 con los comandos exactos que pide la guia.
# La Vuelta 4 (eBPF en vivo) y la Vuelta 5 (Grafana) se muestran aparte,
# en la consola del daemon corriendo y en el navegador respectivamente.

CARNET="202101149"
MODULE_NAME="continfo"
PROC_PATH="/proc/continfo_pr2_so1_${CARNET}"
DAEMON_BIN="daemon-go"

separador() {
    echo ""
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

separador "VUELTA 1 - Modulo de Kernel"

echo "--- Comando: lsmod | grep ${MODULE_NAME} ---"
lsmod | grep "$MODULE_NAME"
echo ""
echo "--- Comando: cat ${PROC_PATH} ---"
cat "$PROC_PATH"

separador "VUELTA 2 - Extraccion de datos correcta + Cronjob y restricciones"

echo "--- Comando: cat ${PROC_PATH} (revisar PID, nombre, VSZ, RSS, %MEM, %CPU) ---"
cat "$PROC_PATH"
echo ""
echo "--- Comando: docker ps --format \"table {{.ID}}\\t{{.Names}}\\t{{.Status}}\" ---"
echo "    (comparar manualmente los PID/ID de arriba contra estos contenedores reales)"
sudo docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
echo ""
echo "--- Comando: crontab -l ---"
sudo crontab -l
echo ""
echo "--- Comando: docker ps ---"
sudo docker ps

separador "VUELTA 3 - Daemon Go + Valkey"

echo "--- Comando: ps aux | grep ${DAEMON_BIN} ---"
ps aux | grep "$DAEMON_BIN" | grep -v grep
echo ""
echo "--- Comando: redis-cli -h localhost -p 6379 KEYS '*' ---"
sudo docker exec -it valkey-db valkey-cli KEYS '*'
echo ""
echo "--- Comando: redis-cli -h localhost -p 6379 GET latest_telemetry ---"
sudo docker exec -it valkey-db valkey-cli GET latest_telemetry

separador "VUELTA 4 - eBPF (demostracion en vivo, no automatizada por este script) VER CONSOLA DAEMON"
echo "1. Tener la terminal del daemon visible (sudo ./daemon-go corriendo en primer plano)."
echo "2. Esperar o forzar a que el daemon elimine un contenedor durante su loop normal."
echo "3. Senalar en el log la linea que empieza con [EBPF] Evento capturado, que muestra"
echo "   PID emisor, PID receptor, y la senal SIGKILL."
echo "4. Inmediatamente despues, senalar la linea [SUCCESS] ... eliminado y confirmado por eBPF."
echo "5. Confirmar en Valkey que el registro de decision_logs correspondiente tiene"
echo "   ebpf_confirmed en true, corriendo:"
echo ""
echo "   sudo docker exec -it valkey-db valkey-cli LRANGE decision_logs 0 0"

separador "VUELTA 5 - Grafana (se muestra en el navegador, no por este script)"
echo "Abrir http://localhost:3001 y recorrer los paneles:"
echo "Total RAM, Free RAM, Total Contenedores Eliminados,"
echo "Grafica de uso de RAM en el tiempo, Top 5 +RAM, Top 5 +CPU, eBPF Event Counter."

separador "VUELTA 6 - Documentacion + preguntas + Rust"
echo "Cubierta por el manual tecnico y la defensa oral (fuera del alcance de este script)."

separador "FIN DE LA DEMOSTRACION"
