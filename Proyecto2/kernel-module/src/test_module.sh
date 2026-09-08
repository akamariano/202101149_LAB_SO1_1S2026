#!/bin/bash
# Script de prueba multi-contenedor para el módulo de kernel continfo

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROC_FILE="/proc/continfo_pr2_so1_202101149"

echo "=== 1. Limpiando contenedores de prueba previos ==="
sudo docker rm -f c_low c_high_cpu c_high_ram 2>/dev/null || true

echo "=== 2. Recompilando y recargando módulo de kernel ==="
cd "$MODULE_DIR"
make clean && make
sudo rmmod continfo 2>/dev/null || true
sudo insmod continfo.ko

echo "=== 3. Desplegando contenedores (Bajo y Alto Consumo) ==="
# Contenedor 1: Bajo consumo (sleep / idle)
CONTAINER_LOW=$(sudo docker run -d --name c_low alpine sleep 300)
echo "  [+] Contenedor Bajo consumo (c_low): ${CONTAINER_LOW:0:12}"

# Contenedor 2: Alto consumo de CPU (bucle activo con bc)
CONTAINER_CPU=$(sudo docker run -d --name c_high_cpu alpine sh -c "while true; do echo '2^20' | bc > /dev/null; sleep 1; done")
echo "  [+] Contenedor Alto CPU (c_high_cpu): ${CONTAINER_CPU:0:12}"

# Contenedor 3: Alto consumo de RAM (utilizando la imagen oficial roldyoran/go-client o asignación de memoria continua)
CONTAINER_RAM=$(sudo docker run -d --name c_high_ram roldyoran/go-client 2>/dev/null || sudo docker run -d --name c_high_ram python:3.9-alpine python -c "a = bytearray(150 * 1024 * 1024); import time; time.sleep(300)")
echo "  [+] Contenedor Alto RAM (c_high_ram): ${CONTAINER_RAM:0:12}"

echo ""
echo "Esperando 8 segundos para que los contenedores arranquen y asignen memoria activa..."
sleep 8

echo ""
echo "=== 4. Comparación con 'docker stats' de referencia ==="
sudo docker stats --no-stream c_low c_high_cpu c_high_ram

echo ""
echo "=== 5. Resultado del módulo en /proc/continfo_pr2_so1_202101149 ==="
cat "$PROC_FILE"

echo ""
echo "=== Limpieza opcional de contenedores: ==="
echo "sudo docker rm -f c_low c_high_cpu c_high_ram"
