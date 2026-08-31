# Proyecto 2 - Sistemas Operativos 1

Sistema de monitorización y gestión autónoma de contenedores mediante un módulo de kernel en C, una sonda eBPF, y un daemon en Go, con visualización en Grafana.

Carné: 202101149

## Componentes

- Módulo de kernel (kernel-module/): expone métricas de RAM y procesos en /proc/continfo_pr2_so1_202101149
- Cronjob (cronjob/): despliega contenedores de prueba cada 2 minutos
- Daemon en Go (daemon-go/): orquesta el sistema, decide qué contenedores eliminar, guarda en Valkey
- Sonda eBPF (ebpf/): confirma a nivel de kernel la terminación de contenedores
- Dashboard (grafana/): visualización de métricas

## Estado del proyecto