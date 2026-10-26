#!/bin/bash
# Script de limpieza total y arranque desde cero del Proyecto 2 (SO1 202101149)
# Elimina artefactos de compilacion anteriores, recompila el modulo de kernel,
# regenera el bytecode eBPF, reconstruye el daemon en Go, y levanta Valkey y Grafana.
# Debe ejecutarse en el Ubuntu dual boot, no en el Mac.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$PROJECT_ROOT/kernel-module/src"
DAEMON_DIR="$PROJECT_ROOT/daemon-go"
MODULE_NAME="continfo"
PROC_PATH="/proc/continfo_pr2_so1_202101149"

echo "=== 1. Deteniendo el modulo de kernel si estaba cargado ==="
sudo rmmod "$MODULE_NAME" 2>/dev/null || echo "El modulo no estaba cargado, se continua."

echo ""
echo "=== 2. Bajando Valkey y Grafana (docker compose down) ==="
cd "$PROJECT_ROOT"
sudo docker compose down

echo ""
echo "=== 3. Limpiando artefactos de compilacion del modulo de kernel ==="
cd "$KERNEL_DIR"
make clean

echo ""
echo "=== 4. Limpiando artefactos de compilacion del daemon en Go ==="
cd "$DAEMON_DIR"
rm -f daemon-go ebpftest ebpftestpidfd
find internal/ebpfprobe -type f \( -name "*.o" -o -name "*_bpfel.go" -o -name "*_bpfeb.go" -o -name "*_bpfel.o" -o -name "*_bpfeb.o" \) -delete

echo ""
echo "=== 5. Recompilando el modulo de kernel ==="
cd "$KERNEL_DIR"
make
echo "Kernel activo: $(uname -r)"

echo ""
echo "=== 6. Cargando el modulo de kernel ==="
sudo insmod "${MODULE_NAME}.ko"
if [ -f "$PROC_PATH" ]; then
    echo "Modulo cargado correctamente, contenido de $PROC_PATH:"
    cat "$PROC_PATH"
else
    echo "ERROR: el modulo no genero el archivo esperado en $PROC_PATH"
    exit 1
fi

echo ""
echo "=== 7. Regenerando bytecode eBPF (bpf2go) ==="
cd "$DAEMON_DIR"
go generate ./...

echo ""
echo "=== 8. Recompilando el daemon en Go ==="
go build -o daemon-go ./cmd/main.go

echo ""
echo "=== 9. Levantando Valkey y Grafana ==="
cd "$PROJECT_ROOT"
sudo docker compose up -d
sleep 3
sudo docker ps

echo ""
echo "=== Limpieza y reconstruccion completa ==="
echo "Para iniciar el daemon, correr:"
echo "  cd $DAEMON_DIR && sudo ./daemon-go"