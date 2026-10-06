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
_Pendiente (bloque 2)._

## 6. Desplegar los componentes en GKE
_Pendiente (bloques 2 a 6)._

## 7. Ejecutar Locust
_Pendiente (bloque 3)._

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
| Pod en GKE con `exec format error` | La imagen se construyó para arm64. Reconstruir con `--platform linux/amd64` |
