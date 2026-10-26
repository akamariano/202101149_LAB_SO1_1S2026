# Laboratorio de Sistemas Operativos 1

Mariano Roberto Rac Noguera · carné 202101149 · Universidad de San Carlos de Guatemala, segundo semestre 2026

Tres proyectos que van de la virtualización al kernel y a la nube: contenedores en máquinas virtuales con tres runtimes distintos, observabilidad de contenedores desde el kernel con un módulo en C y eBPF, y un sistema distribuido en Kubernetes sobre Google Cloud.

| Proyecto | Qué es | Stack | Documentación |
|---|---|---|---|
| [Proyecto 1](Proyecto1/) | 3 APIs REST en Go repartidas en 3 VMs de KVM, cada una con un runtime distinto (containerd, podman y Docker), y un registro privado de imágenes (Zot) | Go, KVM/libvirt, cloud-init, containerd, nerdctl, BuildKit, podman, Docker, Zot | [Manual técnico](Proyecto1/README.md) · [Guía de instalación](Proyecto1/GuiaDeinstalacion.md) |
| [Proyecto 2](Proyecto2/) | Monitoreo y gestión autónoma de contenedores: un módulo de kernel expone RAM y procesos por contenedor en `/proc`, un daemon en Go decide qué contenedores eliminar y una sonda eBPF confirma cada eliminación | C (módulo de kernel), eBPF (cilium/ebpf), Go, cgroups v2, Docker, Valkey, Grafana | [Manual técnico](Proyecto2/README.md) · [Ejecución](Proyecto2/EXECUTER.md) |
| [Proyecto 3](Proyecto3/) | M.U.M.N.K8s: reportes en tiempo real que cruzan una API en Rust, microservicios en Go por gRPC, RabbitMQ y Valkey, con un Operator propio, HPA y pruebas de carga con Locust | GKE, Rust (axum), Go, gRPC/Protobuf, RabbitMQ, Valkey, Grafana, Operator SDK (Helm), Gateway API, HPA, Zot, Locust, Dapr, Falco | [Manual técnico](Proyecto3/README.md) · [Guía de instalación](Proyecto3/GuiaDeInstalacion.md) |

## Pruébalo tú mismo

Los tres proyectos se entregaron sobre infraestructura real (VMs con KVM, un Ubuntu con su propio kernel y un clúster de GKE). Para revisarlos sin montar todo eso, cada uno tiene un camino corto.

### Proyecto 1: las 3 APIs en Docker (5 minutos)

Requiere Docker con Compose. Levanta las tres APIs en una sola red en lugar de tres VMs:

```bash
cd Proyecto1
docker compose -f docker-compose.local.yml up --build -d

curl localhost:8081/health                       # API1 responde
curl localhost:8081/api1/202101149/call-api2     # API1 llama a API2: connection true
curl localhost:8083/api3/202101149/call-api1     # API3 llama a API1

docker compose -f docker-compose.local.yml stop api3
curl localhost:8081/api1/202101149/call-api3     # la API3 "cayó": connection false

docker compose -f docker-compose.local.yml down
```

El despliegue completo, con las 3 VMs, los tres runtimes y el registro Zot, está paso a paso en la [guía de instalación](Proyecto1/GuiaDeinstalacion.md).

### Proyecto 2: módulo de kernel, eBPF y daemon (Linux)

Necesita un Linux real (o una VM) porque carga un módulo en el kernel: Ubuntu 22.04 o superior, con Docker, Go 1.25+ y los headers del kernel en ejecución. No funciona dentro de un contenedor ni en macOS.

```bash
sudo apt install -y build-essential linux-headers-$(uname -r) docker.io docker-compose-v2
cd Proyecto2

# Módulo de kernel
make -C kernel-module/src
sudo insmod kernel-module/src/continfo.ko
cat /proc/continfo_pr2_so1_202101149            # RAM del sistema y procesos por contenedor

# Daemon (levanta Valkey y Grafana, adjunta la sonda eBPF e instala el cronjob)
cd daemon-go && go build -o daemon-go ./cmd && cd ..
sudo ./daemon-go/daemon-go
```

Grafana queda en http://localhost:3001 (admin / admin). Cada 2 minutos el cronjob despliega contenedores de prueba y cada 30 segundos el daemon conserva 3 de bajo consumo y 2 de alto consumo; en su consola se ve cada eliminación confirmada por eBPF. El bytecode eBPF ya viene compilado; para regenerarlo hace falta `clang`, `llvm` y `libbpf-dev` (`go generate ./...` en `daemon-go/internal/ebpfprobe`). Para apagar todo y los problemas comunes, ver [EXECUTER.md](Proyecto2/EXECUTER.md).

### Proyecto 3: el flujo completo en Docker Compose (10 minutos)

Requiere Docker con Compose y unos 4 GB de RAM libres. Corre el mismo camino de datos que en GKE, sin necesitar una cuenta de Google Cloud:

```bash
cd Proyecto3
docker compose -f docker-compose.local.yml up --build -d

# Un reporte a mano
curl -X POST localhost:8080/grpc-202101149 -H 'Content-Type: application/json' \
  -d '{"country":"GTM","warplanes_in_air":42,"warships_in_water":14,"timestamp":"2026-03-12T20:15:30Z"}'
docker compose -f docker-compose.local.yml exec valkey valkey-cli GET reports:total

# Carga con Locust (pip install locust)
LOCUST_CONFIG=locust/war-config.json locust -f locust/locustfile.py --host http://localhost:8080

docker compose -f docker-compose.local.yml down -v
```

- Dashboard de Grafana: http://localhost:3000 (admin / admin), carpeta M.U.M.N.K8s.
- Cola de RabbitMQ: http://localhost:15672 (demo / demo).

Lo que solo existe dentro del clúster (Gateway API, HPA, el Operator de Valkey y Grafana, Zot con HTTPS, Dapr y Falco) se despliega con los scripts numerados de `Proyecto3/scripts/`, siguiendo la [guía de instalación](Proyecto3/GuiaDeInstalacion.md). Para usar tu propio proyecto de GCP cambia `PROJECT_ID` en `scripts/config.env`; las contraseñas se generan en `.secrets/`, que no se versiona, y `scripts/apagar.sh` detiene el clúster para no generar costos.
