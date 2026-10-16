# Guía de Instalación. Proyecto 3, Sistemas Operativos 1

| Campo | Valor |
|---|---|
| Nombre | Mariano Rac |
| Carné | 202101149 |

Esta guía levanta el entorno completo desde cero. La máquina de desarrollo es una **Mac con Apple Silicon** y todo el sistema corre en **Google Cloud Platform**. Los scripts están en `scripts/` y comparten las variables de `scripts/config.env`.

> El manual técnico, con la arquitectura y las decisiones de diseño, está en [README.md](README.md).

## 0. Herramientas locales

```bash
./scripts/00_instalar_herramientas.sh
```

Instala con Homebrew:

| Herramienta | Uso |
|---|---|
| `gcloud` + `gke-gcloud-auth-plugin` | Administrar GCP y autenticar `kubectl` contra GKE |
| `kubectl`, `helm`, `operator-sdk` | Kubernetes, charts y el Operator |
| `go`, `protobuf`, `protoc-gen-go`, `protoc-gen-go-grpc`, `grpcurl` | Servicios en Go y gRPC |
| `rustup`, el target `x86_64-unknown-linux-musl`, `zig`, `cargo-zigbuild` | API en Rust, compilada para amd64 sin emulación |
| `locust`, `oras`, `jq`, `dapr` | Carga, OCI Artifact, utilidades y el extra de Dapr |

También hace falta **Docker Desktop**, abierto antes de construir imágenes.

Abrir una terminal nueva para que se apliquen los cambios al PATH.

## 1. Proyecto de GCP

```bash
gcloud init                                  # login y crear el proyecto so1-p3-202101149
gcloud auth application-default login
gcloud services enable compute.googleapis.com container.googleapis.com
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-c
```

Verificar que la facturación esté activa:

```bash
gcloud billing projects describe so1-p3-202101149   # billingEnabled: true
```

Recomendado: crear una alerta de presupuesto en *Facturación → Presupuestos y alertas*.

## 2. VM de Zot (registry con HTTPS)

```bash
./scripts/01_zot_vm.sh
```

El script:
1. Reserva la IP estática `zot-ip` y arma el dominio `<ip-con-guiones>.sslip.io`.
2. Genera credenciales aleatorias en `.secrets/zot.env` (este archivo está en `.gitignore`).
3. Crea la regla de firewall `allow-zot` (tcp:80,443) para la etiqueta de red `zot`.
4. Crea la VM `n1-standard-1`, probando varias zonas si alguna no tiene capacidad.
5. Copia y ejecuta [zot/instalar_zot.sh](zot/instalar_zot.sh) en la VM: Docker, certbot, htpasswd y el contenedor `zot`.

Verificar:

```bash
source .secrets/zot.env
curl -s -o /dev/null -w "%{http_code}\n" https://$ZOT_DOMAIN/v2/    # 200
```

Interfaz web: `https://<ZOT_DOMAIN>` (usuario y contraseña en `.secrets/zot.env`).

## 3. Clúster de GKE

```bash
./scripts/02_gke_cluster.sh
```

Crea `so1-p3` (zonal, 3 × `n1-standard-2`, `pd-standard` de 50 GB, Gateway API `standard`) y configura `kubectl`. Tarda entre 6 y 10 minutos.

Verificar:

```bash
kubectl get nodes -o wide
kubectl get gatewayclass          # aparecen unos minutos después de crear el clúster
```

## 4. Validar Zot ↔ GKE

```bash
./scripts/03_probar_zot_gke.sh
```

Sube `nginx:alpine` (amd64) a `prueba/nginx:v1` en Zot y crea un pod en GKE que la descarga.

## 5. Construir y publicar las imágenes

Requiere Docker Desktop abierto.

```bash
./scripts/10_build_push.sh                     # todas, con tag v1
TAG=v2 ./scripts/10_build_push.sh grpc-server  # una sola, con otro tag
```

| Imagen | Contexto | Cómo se compila para amd64 |
|---|---|---|
| `mumnk8s/rust-api` | `rust-api/` | `cargo-zigbuild` en una etapa `--platform=$BUILDPLATFORM` que genera un binario musl estático |
| `mumnk8s/api-rest`, `grpc-client`, `grpc-server`, `rabbit-writer`, `consumer` | `go-services/` (una Dockerfile, `--build-arg SERVICE=<binario>`) | `GOOS=linux GOARCH=amd64 CGO_ENABLED=0` (cross-compile nativo de Go) |

En ambos casos el compilador corre nativo en la Mac y solo el binario resultante es amd64, así que no hay emulación. Compilar todas las imágenes desde cero toma unos 3 minutos.

Si cambias el `.proto`, regenera el código Go antes de compilar:

```bash
cd go-services
protoc -I ../proto --go_out=proto --go_opt=paths=source_relative \
       --go-grpc_out=proto --go-grpc_opt=paths=source_relative ../proto/warreport.proto
```

Imágenes de terceros (RabbitMQ): se copian de Docker Hub a Zot una sola vez.

```bash
./scripts/11_mirror_externas.sh
```

## 6. Desplegar los componentes en GKE

```bash
kubectl apply -f k8s/00-namespace.yaml
./scripts/30_rabbitmq_secret.sh      # credenciales de RabbitMQ (Secret rabbitmq-cred)
kubectl apply -f k8s/
kubectl -n mumnk8s get pods          # go-api y go-writer deben mostrar 2/2
```

Ver la cola y la UI de RabbitMQ (usuario y contraseña en `.secrets/rabbitmq.env`):

```bash
kubectl -n mumnk8s exec rabbitmq-0 -- rabbitmqctl list_queues name messages consumers
kubectl -n mumnk8s port-forward svc/rabbitmq 15672:15672    # http://localhost:15672
kubectl -n mumnk8s logs deploy/consumer -f
```

Prueba sin Gateway (port-forward):

```bash
kubectl -n mumnk8s port-forward svc/rust-api 18080:8080 &
curl -X POST localhost:18080/grpc-202101149 -H 'content-type: application/json' \
  -d '{"country":"GTM","warplanes_in_air":42,"warships_in_water":14,"timestamp":"2026-10-06T23:40:00Z"}'
kubectl -n mumnk8s logs deploy/go-writer -c grpc-server
```

## 7. Gateway, HPA y Locust

`kubectl apply -f k8s/` ya crea el Gateway, la HTTPRoute y el HPA. Para obtener la IP pública:

```bash
./scripts/20_gateway_ip.sh     # espera la IP (3 a 8 min) y hace un POST de prueba
```

Locust con interfaz web (http://localhost:8089):

```bash
locust -f locust/locustfile.py --host http://<IP_GATEWAY>
```

Locust sin interfaz, y en otra terminal el escalado:

```bash
locust -f locust/locustfile.py --host http://<IP_GATEWAY> --headless -u 200 -r 20 -t 4m
kubectl -n mumnk8s get hpa rust-api -w
```

## 8. Operador (Valkey y Grafana)

Requiere `operator-sdk` y `helm` (instalados en el paso 0) y Docker Desktop abierto.

```bash
./scripts/11_mirror_externas.sh        # incluye valkey/valkey:8.1-alpine
./operator/build_deploy.sh             # imagen del operador en Zot + CRDs, RBAC y manager
kubectl -n mumnk8s-operator-system get pods
kubectl apply -f k8s/70-valkey.yaml    # CR ValkeyInstance
kubectl -n mumnk8s get valkeyinstance,sts,svc,pvc
```

`kubectl apply -f k8s/` falla en `70-valkey.yaml` si el operador aún no está instalado, porque el CRD no existe. Instala el operador primero.

Ver los datos que escribe el consumer:

```bash
kubectl -n mumnk8s exec valkey-0 -- valkey-cli get reports:GTM
kubectl -n mumnk8s exec valkey-0 -- valkey-cli zrevrange top:planes 0 4 withscores
```

Si cambias el chart, vuelve a ejecutar `TAG=v2 ./operator/build_deploy.sh`: los charts van dentro de la imagen del operador.

---

## Apagar y encender (control de costos)

```bash
./scripts/apagar.sh     # clúster a 0 nodos y VM de Zot detenida
./scripts/encender.sh   # vuelve a 3 nodos, enciende la VM y actualiza kubectl
```

La IP estática, los discos y las imágenes de Zot se conservan.

## Problemas frecuentes

| Síntoma | Solución |
|---|---|
| `ZONE_RESOURCE_POOL_EXHAUSTED` | No hay capacidad N1 en esa zona. Cambiar `ZONE` en `config.env` (para la VM, el script ya prueba varias) |
| `gke-gcloud-auth-plugin not found` | Ejecutar `gcloud components install gke-gcloud-auth-plugin` y verificar que `$(brew --prefix)/share/google-cloud-sdk/bin` esté en el PATH |
| `docker login` se queda colgado | Revisar si el llavero de macOS abrió una ventana pidiendo permiso |
| `kubectl`: `gke-gcloud-auth-plugin not found` en una terminal nueva | Esa terminal no cargó el PATH de gcloud. Ejecutar `export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"` |
| El Gateway responde `502` | El health check del balanceador falla. Revisar que exista la `HealthCheckPolicy` y que `/health` responda |
| Pod en GKE con `exec format error` | La imagen se construyó para arm64. Reconstruir con `--platform linux/amd64` |
