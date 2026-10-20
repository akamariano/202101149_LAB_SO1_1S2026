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

Tags vigentes: `rust-api:v3`, `api-rest:v2`, `grpc-client:v3`, `grpc-server:v4`, `rabbit-writer:v1`, `consumer:v3` y `falco-bridge:v1` (los que usan los manifiestos de `k8s/`). El operador va en `v5` (`TAG=v5 ./operator/build_deploy.sh`), que trae el dashboard con los paneles de Falco.

```bash
TAG=v3 ./scripts/10_build_push.sh rust-api grpc-client
TAG=v2 ./scripts/10_build_push.sh api-rest
TAG=v4 ./scripts/10_build_push.sh grpc-server
TAG=v1 ./scripts/10_build_push.sh falco-bridge
```

Imágenes y artifacts de terceros (RabbitMQ, Valkey, Grafana, Falco y Dapr): se copian a Zot una sola vez. Las imágenes se copian con `skopeo` desde la VM de Zot; las reglas y el plugin de Falco, que son artifacts OCI, con `oras cp` desde la Mac.

```bash
./scripts/11_mirror_externas.sh          # todo
./scripts/11_mirror_externas.sh falco    # solo lo que contenga "falco"
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

Locust lee países, rangos y rutas del OCI Artifact publicado en Zot (sección 9). Bájalo primero:

```bash
./scripts/50_oci_artifact.sh pull
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

### Grafana

Todo en un paso: `./scripts/41_grafana_deploy.sh` hace lo de abajo y abre el dashboard. Si Grafana ya está desplegado, `./scripts/41_grafana_deploy.sh ver` solo lo abre.

Paso a paso:

```bash
./scripts/11_mirror_externas.sh        # también copia grafana/grafana:12.4.13 a Zot
TAG=v5 ./operator/build_deploy.sh      # operador con el kind GrafanaInstance (v5: con paneles de Falco)
./scripts/40_grafana_secret.sh         # Secret grafana-admin (clave en .secrets/grafana.env)
kubectl apply -f k8s/80-grafana.yaml   # CR GrafanaInstance
kubectl -n mumnk8s get grafanainstance,deploy,svc,cm -l app.kubernetes.io/name=grafana
```

Abrir el dashboard:

```bash
kubectl -n mumnk8s port-forward svc/grafana 3300:80
# http://localhost:3300  usuario y clave en .secrets/grafana.env
```

Si el pod se queda en `Init:0/1`, el initContainer no pudo descargar el plugin. Revisa `kubectl -n mumnk8s logs deploy/grafana -c install-plugins`.

## 9. OCI Artifact (configuración de Locust)

```bash
./scripts/50_oci_artifact.sh push   # sube locust/war-config.json a Zot como mumnk8s/locust-config:v1
./scripts/50_oci_artifact.sh ver    # manifiesto (artifactType propio, capa application/json)
./scripts/50_oci_artifact.sh pull   # lo baja a locust/.artifact/war-config.json
```

Para cambiar los rangos o los países, edita `locust/war-config.json` y publica otra versión (`TAG=v2 ./scripts/50_oci_artifact.sh push`).

## 10. Pruebas de réplicas

```bash
./scripts/60_pruebas_replicas.sh                    # w1-v1 w2-v1 w1-v2 w2-v2, 150 usuarios, 2 min
PREFIJO=alta- USUARIOS=600 TASA=50 PROCESOS=4 GO_API=2 ./scripts/60_pruebas_replicas.sh w1-v1 w2-v1
FLUJO=dapr PREFIJO=dapr- ./scripts/60_pruebas_replicas.sh w1-v1 w2-v1
```

`wX-vY` significa X réplicas de `go-writer` e Y réplicas de Valkey. Los resultados quedan en `pruebas/<escenario>/`: `locust_stats.csv`, `cola.csv` (colas de RabbitMQ cada 5 s), `cpu.txt` (`kubectl top` cada 5 s) y `resumen.txt`. Al terminar, el script deja 1 `go-writer`, 1 Valkey y el HPA en 1-3.

## 11. Dapr (extra, `/dapr-202101149`)

```bash
./scripts/80_dapr.sh instalar   # chart dapr/dapr 1.18.7 desde Zot, Component pubsub-rabbitmq, sidecars
./scripts/80_dapr.sh probar     # POST a /dapr-202101149 y logs de cada salto
./scripts/80_dapr.sh estado     # pods 3/3, Component y colas
FLUJO=dapr locust -f locust/locustfile.py --host http://<IP_GATEWAY>
```

`go-api` y `go-writer` deben mostrar `3/3` (el tercer contenedor es `daprd`). En RabbitMQ aparece la cola `go-writer-war_reports_dapr`. Después de agregar la ruta, el balanceador puede responder `404` durante 1-3 minutos mientras propaga el cambio.

## 12. Falco (extra)

```bash
./scripts/70_falco.sh instalar   # chart falcosecurity/falco 9.2.0 desde Zot + regla k8s/falco/reglas-mumnk8s.yaml
./scripts/70_falco.sh probar     # kubectl exec ... cat /etc/shadow y muestra la alerta
./scripts/70_falco.sh logs       # solo las alertas [MUMNK8s]
```

Los 3 pods del DaemonSet `falco` deben estar `1/1`. Si un pod no arranca, revisa el initContainer que baja las reglas: `kubectl -n falco logs <pod> -c falcoctl-artifact-install`.

## 13. Día de la calificación

La guía del auxiliar ([pruebas/Official/](pruebas/Official/)) pide todo desplegado **antes** del turno y no permite compilar ni desplegar durante él. [scripts/90_calificacion.sh](scripts/90_calificacion.sh) separa las dos partes:

```bash
./scripts/90_calificacion.sh            # todo de una vez: levantar + las 4 vueltas + extra
./scripts/90_calificacion.sh levantar   # o solo levantar, antes del turno (5-15 min)
```

Sin parámetros, el script levanta todo, abre las pestañas y ejecuta las vueltas seguidas, con una pausa (Enter) entre vuelta y vuelta. `PAUSA=comando` pausa después de cada comando y `PAUSA=0` no pausa nunca. La vuelta 2 genera tráfico con **200 usuarios** (~450 req/s); se cambia con `USUARIOS=…`.

`levantar` hace lo siguiente:
1. Enciende la VM de Zot y los nodos.
2. Aplica los manifiestos (idempotente) e instala Dapr y Falco si faltan.
3. Espera a que todos los pods estén listos. Si `go-api` o `go-writer` arrancaron antes que el injector de Dapr y quedaron sin sidecar, los recrea.
4. Baja el OCI Artifact.
5. Prueba `/grpc-202101149` y `/dapr-202101149`. Con nodos recién encendidos, el balanceador tarda unos minutos en registrar los pods; el script espera hasta 15 min y muestra el avance.
6. Deja Locust (interfaz web, puerto 8089) y el port-forward de Grafana (puerto 3300) en segundo plano.
7. Abre las 3 pestañas que pide la guía: Locust, el catálogo de Zot y el dashboard.

Durante el turno, una vuelta por comando. Cada uno muestra el comando antes de ejecutarlo y espera Enter:

| Comando | Vuelta de la guía | Qué muestra |
|---|---|---|
| `./scripts/90_calificacion.sh vuelta1` | 1. GCP, Zot y Gateway | `kubectl get nodes -o wide`, `kubectl get gateway,httproute`, las rutas, la VM de Zot, el catálogo, el certificado y que todas las imágenes salen de Zot |
| `./scripts/90_calificacion.sh vuelta2` | 2. Locust, Rust, gRPC y HPA | Inicia la carga en la interfaz de Locust, `kubectl get hpa,deployments`, logs de cada salto (`rust-api` → `grpc-client` → `grpc-server` → `rabbit-writer`) y el HPA escalando de 1 a 3 |
| `./scripts/90_calificacion.sh vuelta3` | 3. RabbitMQ, consumer y operador | `kubectl get crd`, los CRs, los pods, `valkey-cli DBSIZE`, lo que creó el operador, las colas y los datos en Valkey |
| `./scripts/90_calificacion.sh vuelta4` | 4. Grafana, Falco y manual | Dashboard, `cat /etc/shadow` en un pod y la alerta de Falco del último minuto |
| `./scripts/90_calificacion.sh extra` | Puntos extra | Flujo Dapr: plano de control, Component, pods `3/3` y un reporte por `/dapr-202101149` |

Los nombres de los CRDs (`valkeyinstances`, `grafanainstances`), de los CRs y del pod de Valkey no están fijos en el script: los lee del clúster filtrando por el grupo `mumnk8s.so1.usac`. El pod primario es `<nombre del CR>-0` porque el operador usa el nombre del CR como nombre del release de Helm. La guía usa `app=api-rust` como ejemplo; en este proyecto la etiqueta es **`app=rust-api`**:

```bash
kubectl logs -l app=rust-api -n mumnk8s --tail=10
```

Ensayo completo sin pausas: `PAUSA=0 ./scripts/90_calificacion.sh todo`. Al terminar: `./scripts/90_calificacion.sh detener && ./scripts/apagar.sh`.

Cada vuelta sigue el mismo orden que el PDF:
1. Imprime lo que pide la guía: tiempo, puntos, pestañas del navegador, comandos y verificaciones.
2. Ejecuta los comandos de la guía rotulados `[Guía, comando n de N]`, cada uno con una línea `↳ Se ve:` que dice qué mirar en la salida. Después vienen los rotulados `[Evidencia adicional]`.
3. Cierra con un resumen ✔/✘ de las verificaciones de esa vuelta, comprobadas contra el clúster (por ejemplo: HPA 1-3 al 30 %, cola `war_reports` con consumers, `DBSIZE > 0`, alertas de Falco registradas).

Las vueltas están en [scripts/lib_calificacion.sh](scripts/lib_calificacion.sh) y las usan dos scripts:

| Script | Qué hace |
|---|---|
| [scripts/90_calificacion.sh](scripts/90_calificacion.sh) | Levanta el sistema y hace las acciones de la demo: inicia la carga en Locust, `cat /etc/shadow` para Falco y un reporte por `/dapr-202101149` |
| [scripts/91_mostrar.sh](scripts/91_mostrar.sh) | **Solo lee.** No enciende GCP, no abre Locust ni el port-forward y no inicia la carga. Muestra lo que pide la guía y el estado actual. Si el clúster está apagado, solo imprime la guía |

```bash
./scripts/91_mostrar.sh            # preparación (kubectl y las 3 pestañas) + 4 vueltas + extra
./scripts/91_mostrar.sh guia       # solo el texto de la guía y los puntos (no consulta el clúster)
./scripts/91_mostrar.sh vuelta3    # una vuelta
SIMULAR=1 ./scripts/91_mostrar.sh vuelta4   # además genera la alerta de Falco
```

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
| Locust: `No existe .../locust/.artifact/war-config.json` | Falta bajar el OCI Artifact: `./scripts/50_oci_artifact.sh pull` |
| `10_build_push.sh` responde `Abre Docker Desktop primero.` | Abrir Docker Desktop y esperar a que `docker info` responda |
| `go-api` o `go-writer` en `2/2` con Dapr instalado | Los pods se crearon antes que Dapr. `kubectl -n mumnk8s rollout restart deploy/go-api deploy/go-writer` |
