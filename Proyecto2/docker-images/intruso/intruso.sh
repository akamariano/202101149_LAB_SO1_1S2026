#!/bin/sh
# Contenedor Intruso: Simulación de lectura continua de archivos sensibles del sistema

echo "[+] Contenedor Intruso Iniciado - Escaneando archivos sensibles..."

while true; do
    echo "=== Intento de lectura de archivos sensibles ===" > /dev/null
    cat /etc/passwd > /dev/null 2>&1 || true
    cat /etc/shadow > /dev/null 2>&1 || true
    cat /proc/version > /dev/null 2>&1 || true
    cat /sys/firmware/efi/efivars 2>/dev/null || true
    sleep 5
done
