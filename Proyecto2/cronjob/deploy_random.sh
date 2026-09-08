#!/bin/bash
# Script de despliegue aleatorio de 5 contenedores cada 2 minutos

LOG_FILE="/tmp/cron_deploy.log"
echo "[$(date)] Ejecutando despliegue de 5 contenedores aleatorios..." >> "$LOG_FILE"

TYPES=("high_ram" "high_cpu" "low" "intruso")

for i in {1..5}; do
    # Selección aleatoria del tipo de contenedor
    RAND_INDEX=$((RANDOM % 4))
    TYPE="${TYPES[$RAND_INDEX]}"
    TIMESTAMP=$(date +%s%N)

    case "$TYPE" in
        "high_ram")
            CONTAINER_NAME="c_hram_${i}_${TIMESTAMP: -6}"
            sudo docker run -d --name "$CONTAINER_NAME" roldyoran/go-client >> "$LOG_FILE" 2>&1 || true
            ;;
        "high_cpu")
            CONTAINER_NAME="c_hcpu_${i}_${TIMESTAMP: -6}"
            sudo docker run -d --name "$CONTAINER_NAME" alpine sh -c "while true; do echo '2^20' | bc > /dev/null; sleep 2; done" >> "$LOG_FILE" 2>&1 || true
            ;;
        "low")
            CONTAINER_NAME="c_low_${i}_${TIMESTAMP: -6}"
            sudo docker run -d --name "$CONTAINER_NAME" alpine sleep 240 >> "$LOG_FILE" 2>&1 || true
            ;;
        "intruso")
            CONTAINER_NAME="c_intruso_${i}_${TIMESTAMP: -6}"
            sudo docker run -d --name "$CONTAINER_NAME" intruso:latest >> "$LOG_FILE" 2>&1 || true
            ;;
    esac
done

echo "[$(date)] Despliegue completado con éxito." >> "$LOG_FILE"
