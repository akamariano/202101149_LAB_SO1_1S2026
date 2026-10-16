# Manual Técnico. Proyecto 3, Sistemas Operativos 1
## M.U.M.N.K8s: Monitoreo de Unidades Militares en la Nube con Kubernetes

| Campo | Valor |
|---|---|
| Nombre | Mariano Rac |
| Carné | 202101149 |
| País asignado | GTM (último dígito del carné: 9) |
| Ruta principal | `/grpc-202101149` |
| Ruta alterna (opcional) | `/dapr-202101149` |

> Estado del documento: **en construcción**. Cada sección se completa al cerrar su bloque de trabajo. La guía para levantar el entorno está en [GuiaDeInstalacion.md](GuiaDeInstalacion.md).

---

## Índice
1. [Objetivo del proyecto](#1-objetivo-del-proyecto)
2. [Arquitectura general](#2-arquitectura-general)
3. [Conceptos clave](#3-conceptos-clave)
4. [Infraestructura en GCP](#4-infraestructura-en-gcp)
5. [Zot: registry de imágenes](#5-zot-registry-de-imágenes)
6. [Flujo completo de datos](#6-flujo-completo-de-datos)
7. [Kubernetes Gateway API](#7-kubernetes-gateway-api)
8. [Comunicación REST y gRPC](#8-comunicación-rest-y-grpc)
9. [RabbitMQ](#9-rabbitmq)
10. [Operator: Valkey y Grafana](#10-operator-valkey-y-grafana)
11. [HPA](#11-hpa)
12. [OCI Artifact](#12-oci-artifact)
13. [Dashboard de Grafana](#13-dashboard-de-grafana)
14. [Pruebas de carga y análisis de réplicas](#14-pruebas-de-carga-y-análisis-de-réplicas)
15. [Extras: Dapr y Falco](#15-extras-dapr-y-falco)
16. [Problemas encontrados y soluciones](#16-problemas-encontrados-y-soluciones)
17. [Conclusiones](#17-conclusiones)

---

## 1. Objetivo del proyecto

Construir en Google Cloud Platform un sistema distribuido y escalable que recibe en tiempo real reportes militares simulados. Cada reporte indica un país, los aviones de guerra en el aire, los barcos de guerra en el mar y una marca de tiempo. El sistema los procesa, los encola, los almacena y los muestra en un dashboard.

El proyecto demuestra el uso de:
- contenedores y orquestación con **GKE**;
- microservicios en **Rust** y **Go**, comunicados por **REST** y **gRPC**;
- mensajería asíncrona con **RabbitMQ**;
- extensión de Kubernetes con un **Operator** (Operator SDK, basado en Helm) que administra **Valkey** y **Grafana** como Custom Resources;
- un registry privado (**Zot**) en una VM fuera del clúster;
- pruebas de carga con **Locust** y autoescalado con **HPA**.

Ejemplo de mensaje:

```json
{
  "country": "GTM",
  "warplanes_in_air": 42,
  "warships_in_water": 14,
  "timestamp": "2026-03-12T20:15:30Z"
}
```

## 2. Arquitectura general

![Arquitectura del enunciado](docs/img_enunciado/arquitectura.png)

```
Locust ──HTTP───▶ Gateway API ──/grpc-202101149──▶ API REST (Rust, HPA 1-3)
                                                        │ HTTP
                                                        ▼
                                          Go Deployment 1 (REST + cliente gRPC)
                                                        │ gRPC
                                                        ▼
                                          Go Deployment 2 (servidor gRPC + writer)
                                                        │ AMQP publish
                                                        ▼
                                                    RabbitMQ
                                                        │ AMQP consume
                                                        ▼
                                              Consumer (Go) ──▶ Valkey (CR ValkeyInstance)
                                                                     │
                                                                     ▼
                                                           Grafana (CR GrafanaInstance)

  Zot (VM en GCP, fuera del clúster) ──imágenes por HTTPS──▶ todos los Deployments
```

| Componente | Tecnología | Dónde corre | Estado |
|---|---|---|---|
| Generador de carga | Locust | Máquina local | **Funcionando** (bloque 3) |
| Exposición | Kubernetes Gateway API (GKE) | GKE | **Funcionando** (bloque 3) |
| API REST | Rust, con HPA 1-3 | GKE | **Funcionando** (bloques 2 y 3) |
| Deployment 1 | Go: REST + cliente gRPC | GKE | **Funcionando** (bloque 2) |
| Deployment 2 | Go: servidor gRPC + writer de RabbitMQ | GKE | **Funcionando** (bloque 4) |
| Broker | RabbitMQ 4.1 (StatefulSet) | GKE | **Funcionando** (bloque 4) |
| Consumer | Go | GKE | **Funcionando**: lee la cola y escribe en Valkey (bloques 4 y 5) |
| Almacenamiento | Valkey 8.1, CR `ValkeyInstance` del operador propio | GKE | **Funcionando** (bloque 5) |
| Visualización | Grafana, administrado por el Operator | GKE | Pendiente |
| Registry | Zot v2.1.22 | VM `zot-vm` | **Funcionando** |

## 3. Conceptos clave

| Concepto | Qué es | Para qué se usa en el proyecto |
|---|---|---|
| **Contenedor / imagen OCI** | Un paquete con una aplicación y sus dependencias. OCI es el estándar abierto del formato | Cada servicio (Rust, Go, consumer, operator) es una imagen |
| **Registry** | Un servidor que almacena imágenes, como Docker Hub | Zot guarda todas las imágenes del proyecto |
| **Kubernetes (K8s)** | Un orquestador: decide en qué nodo corre cada contenedor, los reinicia si fallan y los escala | Es la base de todo el sistema |
| **GKE** | Kubernetes administrado por Google: Google opera el *control plane* y nosotros solo los nodos | El clúster `so1-p3` |
| **Nodo** | Una VM que ejecuta pods. En GKE corre kubelet y containerd | 3 nodos `n1-standard-2` |
| **Pod / Deployment / Service** | Pod: uno o más contenedores que comparten red. Deployment: mantiene N réplicas de un pod. Service: IP y DNS estables frente a pods que cambian | Cada microservicio |
| **Gateway API** | El sucesor de Ingress para exponer servicios HTTP, con recursos `Gateway` y `HTTPRoute` | La entrada pública de Locust |
| **REST vs. gRPC** | REST: JSON sobre HTTP/1.1, fácil de leer. gRPC: Protobuf binario sobre HTTP/2, con contrato tipado (`.proto`) y más eficiente | Rust → Go por REST; Go → Go por gRPC |
| **Message broker** | Un intermediario que desacopla a quien produce mensajes de quien los consume, usando colas | RabbitMQ amortigua los picos de carga |
| **HPA** | Horizontal Pod Autoscaler: agrega o quita réplicas según el uso de CPU | API de Rust: 1 a 3 réplicas cuando la CPU pasa del 30 % |
| **CRD / Custom Resource** | Extienden la API de Kubernetes con tipos nuevos, por ejemplo `ValkeyInstance` | Valkey y Grafana se piden de forma declarativa |
| **Operator** | Un controlador que **reconcilia** el estado deseado (el CR) con el estado real del clúster | Crea, actualiza y borra Valkey y Grafana |
| **Helm chart** | Una plantilla parametrizada de manifiestos de Kubernetes | El Operator basado en Helm instala el chart con los valores del CR |
| **PVC** | PersistentVolumeClaim: una solicitud de disco persistente que sobrevive al pod | Los datos de Valkey |
| **TLS / HTTPS** | Cifrado y verificación de identidad del servidor mediante un certificado firmado por una CA | Zot usa un certificado de Let's Encrypt |

## 4. Infraestructura en GCP

| Recurso | Valor |
|---|---|
| Proyecto | `so1-p3-202101149` |
| Región / zona | `us-central1` / `us-central1-c` |
| Clúster | `so1-p3`, GKE Standard zonal, Kubernetes 1.35 |
| Nodos | 3 × `n1-standard-2` (2 vCPU, 7.5 GB), disco `pd-standard` de 50 GB |
| Gateway API | Canal `standard` (`--gateway-api standard`) |
| VM de Zot | `zot-vm`, `n1-standard-1`, Ubuntu 24.04, disco de 30 GB |
| IP estática de Zot | `34.45.250.177` |

Decisiones de diseño:
- **Clúster zonal.** La gestión de un clúster zonal entra en el nivel gratuito de GKE; uno regional triplicaría los nodos.
- **Disco `pd-standard` de 50 GB.** El disco por defecto (`pd-balanced` de 100 GB) cuenta contra la cuota de SSD de 250 GB, y con 3 nodos sumaría 300 GB.
- **Zona `us-central1-c`.** En `us-central1-a` y `us-central1-b` no había capacidad para máquinas N1 (`ZONE_RESOURCE_POOL_EXHAUSTED`).


## 5. Zot: registry de imágenes

Zot es un registry OCI ligero. Corre como contenedor dentro de la VM `zot-vm`, **fuera del clúster**, y sirve HTTPS directamente.

| Aspecto | Implementación |
|---|---|
| Dominio | `34-45-250-177.sslip.io`. sslip.io es un DNS público que resuelve el nombre a la IP incluida en él |
| Certificado | Let's Encrypt, obtenido con `certbot --standalone` mediante el reto HTTP-01 en el puerto 80 |
| Renovación | Un *deploy hook* de certbot copia el certificado nuevo a `/opt/zot/tls` y reinicia Zot |
| Puertos | 443 en la VM, que redirige al 5000 del contenedor. Regla de firewall `allow-zot` (tcp:80,443) |
| Autenticación | `htpasswd` (bcrypt), usuario `admin` |
| Control de acceso | **Lectura anónima** (GKE descarga sin `imagePullSecrets`). Subir y borrar requiere autenticación |
| Persistencia | `/opt/zot/data` en la VM |
| Interfaz web | Extensiones `search` y `ui` habilitadas |

Configuración (`/opt/zot/config.json`, generada por [zot/instalar_zot.sh](zot/instalar_zot.sh)):

```json
{
  "distSpecVersion": "1.1.1",
  "storage": { "rootDirectory": "/var/lib/registry", "gc": true },
  "http": {
    "address": "0.0.0.0", "port": "5000", "realm": "zot",
    "tls": { "cert": "/etc/zot/tls/fullchain.pem", "key": "/etc/zot/tls/privkey.pem" },
    "auth": { "htpasswd": { "path": "/etc/zot/htpasswd" } },
    "accessControl": { "repositories": { "**": {
      "anonymousPolicy": ["read"],
      "defaultPolicy": ["read", "create", "update", "delete"] } } }
  },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
```

**Arquitectura de las imágenes.** La máquina de desarrollo es una Mac con Apple Silicon (arm64) y los nodos N1 son x86_64, así que todas las imágenes se construyen para `linux/amd64`. Una imagen arm64 fallaría en GKE con `exec format error`.

Validación del ciclo de push y pull:

| Prueba | Resultado |
|---|---|
| `GET /v2/` por HTTPS | 200, con certificado emitido por Let's Encrypt |
| Push anónimo | 401, rechazado |
| `docker push .../prueba/nginx:v1` con login | Aparece en `/v2/_catalog` |
| Pod en GKE con imagen de Zot | `Successfully pulled image "34-45-250-177.sslip.io/prueba/nginx:v1"` |

Interfaz web de Zot servida por HTTPS (`https://34-45-250-177.sslip.io/home`), con la imagen de prueba `prueba/nginx:v1` publicada para `linux/amd64` y 2 descargas: el pod de prueba de GKE y la verificación.

![Interfaz web de Zot por HTTPS con la imagen de prueba](Images/Images_zot_Prueba.png)


## 6. Flujo completo de datos

Todos los componentes viven en el namespace `mumnk8s`.

| # | Origen → destino | Protocolo | Formato | Dirección |
|---|---|---|---|---|
| 1 | Locust → Gateway API | HTTPS | JSON | IP pública del Gateway, `/grpc-202101149` _(bloque 3)_ |
| 2 | Gateway → `rust-api` | HTTP | JSON | `rust-api:8080/grpc-202101149` |
| 3 | `rust-api` → `go-api` (contenedor `api-rest`) | HTTP/1.1 REST | JSON | `http://go-api:8080/reports` |
| 4 | `api-rest` → `grpc-client` (mismo pod) | gRPC | Protobuf | `localhost:50050` |
| 5 | `grpc-client` → `go-writer` (contenedor `grpc-server`) | gRPC (HTTP/2) | Protobuf | `dns:///go-writer-grpc.mumnk8s.svc.cluster.local:50051` |
| 6 | `grpc-server` → `rabbit-writer` → RabbitMQ | AMQP | JSON | _(bloque 4)_ |
| 7 | RabbitMQ → consumer → Valkey | AMQP / RESP | | _(bloque 5)_ |
| 8 | Valkey → Grafana | Redis datasource | | _(bloque 6)_ |

Validación en cada capa:
- **Rust** rechaza con `400` los países fuera de `USA, RUS, CHN, ESP, GTM` y los valores fuera de rango (aviones 0–50, barcos 0–30). Normaliza el país a mayúsculas.
- **api-rest (Go)** convierte el país al enum del `.proto` (`"GTM"` → `Countries_gtm`) y valida que el timestamp sea RFC3339.
- Si una capa posterior falla, la anterior responde `502 Bad Gateway`.

## 7. Kubernetes Gateway API
Manifiesto: [k8s/40-gateway.yaml](k8s/40-gateway.yaml). Sustituye al Ingress Controller y separa la exposición en dos recursos:

| Recurso | Rol | Quién lo administra |
|---|---|---|
| `Gateway` `mumnk8s-gateway` | El balanceador. Con la clase `gke-l7-global-external-managed`, GKE crea un Application Load Balancer externo de Google con IP pública (escucha HTTP en el puerto 80) | Infraestructura |
| `HTTPRoute` `grpc-route` | La regla: `PathPrefix /grpc-202101149` → Service `rust-api:8080`. Se engancha al Gateway con `parentRefs` | Aplicación |
| `HealthCheckPolicy` `rust-api-hc` | Le indica al balanceador que revise la salud de los pods en `GET /health` | Aplicación |

La ruta se reenvía sin reescribirla, por eso `rust-api` escucha directamente en `/grpc-202101149`. La ruta opcional `/dapr-202101149` sería otra regla (u otra `HTTPRoute`) sobre el mismo Gateway.

**¿Por qué la HealthCheckPolicy?** El balanceador de Google no usa las `readinessProbe` del pod, sino sus propios health checks, que por defecto piden `GET /`. Como `rust-api` responde `404` en `/`, sin la política todos los backends quedarían marcados como no sanos y el Gateway respondería `502`.

Verificación:

```bash
kubectl -n mumnk8s get gateway        # PROGRAMMED=True y una IP en ADDRESS
./scripts/20_gateway_ip.sh            # espera la IP y hace un POST de prueba
```

El balanceador tarda entre 3 y 8 minutos en quedar listo después del `apply`.

## 8. Comunicación REST y gRPC

### 8.1 Contrato gRPC
[proto/warreport.proto](proto/warreport.proto) es la propuesta del enunciado (paquete `wartweets`, servicio `WarReportService.SendReport`). El código Go se genera con:

```bash
cd go-services
protoc -I ../proto --go_out=proto --go_opt=paths=source_relative \
       --go-grpc_out=proto --go-grpc_opt=paths=source_relative ../proto/warreport.proto
```

**Todos los saltos gRPC usan el mismo servicio `WarReportService`.** Cada contenedor es servidor del salto anterior y cliente del siguiente, así que la interfaz no cambia a lo largo de la cadena.

### 8.2 API REST en Rust ([rust-api/src/main.rs](rust-api/src/main.rs))
| Aspecto | Implementación |
|---|---|
| Framework | `axum` 0.8 sobre `tokio`, un runtime asíncrono multihilo |
| Rutas | `POST /grpc-202101149` (la ruta llega igual desde el Gateway) y `GET /health` para las probes |
| Reenvío | `reqwest::Client` compartido (`Arc`), con pool de conexiones keep-alive y timeout de 5 s |
| Configuración | Variables de entorno `CARNET`, `GO_API_URL`, `HTTP_ADDR` |
| Imagen | Binario estático `x86_64-unknown-linux-musl` compilado con `cargo-zigbuild` en una imagen `alpine` |

### 8.3 Deployment 1: `go-api` (2 contenedores)
Los dos contenedores del pod comparten el mismo *network namespace*, así que se comunican por `localhost`.

| Contenedor | Rol | Concurrencia |
|---|---|---|
| `api-rest` ([cmd/api-rest](go-services/cmd/api-rest/main.go)) | HTTP `:8080`. Recibe el JSON de Rust, lo valida, lo convierte a protobuf y llama a `SendReport` en `localhost:50050` | `net/http` atiende cada petición en una goroutine; usa una sola conexión gRPC (HTTP/2) multiplexada y contadores `atomic` |
| `grpc-client` ([cmd/grpc-client](go-services/cmd/grpc-client/main.go)) | **Patrón ambassador**: expone `WarReportService` solo en `localhost:50050` y reenvía cada llamada al gRPC Server del Deployment 2 | El servidor gRPC atiende cada llamada en una goroutine; una sola `ClientConn` hacia el upstream, con balanceo `round_robin` |

¿Por qué un ambassador? Toda la lógica de la conexión remota (descubrimiento por DNS, balanceo entre réplicas y timeouts) queda en un solo contenedor. `api-rest` no sabe dónde vive el servidor.

### 8.4 Deployment 2: `go-writer`
| Contenedor | Rol |
|---|---|
| `grpc-server` ([cmd/grpc-server](go-services/cmd/grpc-server/main.go)) | gRPC `:50051`. Recibe los reportes del Deployment 1 y los reenvía al `rabbit-writer` por `localhost:50052`. Registra cada 10 s el total atendido por la réplica. Expone `grpc.health.v1` (lo usa la `readinessProbe` gRPC nativa) y *reflection* (para probarlo con `grpcurl`) |
| `rabbit-writer` ([cmd/rabbit-writer](go-services/cmd/rabbit-writer/main.go)) | gRPC solo en `localhost:50052`. Convierte el reporte a JSON y lo publica en RabbitMQ (sección 9) |

Es el mismo patrón del Deployment 1: cada contenedor tiene una sola responsabilidad y se comunican por `localhost`. Los errores se propagan hacia atrás: si RabbitMQ no confirma un mensaje, el writer responde `Unavailable`, el grpc-server lo reenvía y Locust ve un error en lugar de un falso `200`.

### 8.5 Balanceo gRPC entre réplicas
gRPC usa conexiones HTTP/2 **persistentes**. Con un Service normal (ClusterIP), kube-proxy balancea **conexiones**, no peticiones: el cliente abre una sola conexión y **todo el tráfico va a una réplica**, aunque haya dos.

Solución aplicada:
1. **Service headless** `go-writer-grpc` (`clusterIP: None`). El DNS devuelve la IP de cada pod.
2. **El cliente usa `dns:///…` con `round_robin`**: abre una conexión por pod y reparte las llamadas.
3. **`MaxConnectionAge: 30s` en el servidor.** El resolver DNS de grpc-go no vuelve a consultar por su cuenta. Al cerrar el servidor las conexiones cada 30 s (con GOAWAY), el cliente vuelve a resolver y descubre las réplicas nuevas tras un escalado.

Prueba con `go-writer` en 2 réplicas y 1000 peticiones (25 concurrentes):

| Réplica | Reportes atendidos |
|---|---|
| `go-writer-849d95595c-d2djb` | 500 |
| `go-writer-849d95595c-gq472` | 500 |

Antes de agregar `MaxConnectionAge`, la réplica nueva recibió **0** reportes: el cliente seguía conectado solo a la original.

### 8.6 Pruebas del bloque 2
| Prueba | Resultado |
|---|---|
| Reporte válido (`GTM`, 42, 14) | `200 reporte enviado` |
| País `MEX` | `400 país no soportado: MEX` |
| `warplanes_in_air: 99` | `400 warplanes_in_air fuera de rango (0-50)` |
| `grpcurl` directo al servidor | `{"status": "recibido por <pod>"}` |
| 1000 peticiones concurrentes en GKE | 1000 × `200` |

## 9. RabbitMQ
Manifiestos: [k8s/05-rabbitmq.yaml](k8s/05-rabbitmq.yaml) (broker) y [k8s/60-consumer.yaml](k8s/60-consumer.yaml) (consumer). Código compartido de la topología: [internal/mq/mq.go](go-services/internal/mq/mq.go).

### 9.1 Despliegue del broker
| Decisión | Motivo |
|---|---|
| **StatefulSet** con 1 réplica, y no Deployment | RabbitMQ tiene estado. El pod siempre se llama `rabbitmq-0` y RabbitMQ guarda sus datos bajo el nombre del nodo (`rabbit@rabbitmq-0`); con un nombre aleatorio no reconocería sus propios datos al reiniciar |
| `volumeClaimTemplates` de 2Gi en `/var/lib/rabbitmq` | Cada réplica obtiene su PVC. Los mensajes persistentes sobreviven al reinicio del pod |
| Imagen `rabbitmq:4.1-management-alpine` **espejada en Zot** | El clúster descarga todo desde el registry propio ([scripts/11_mirror_externas.sh](scripts/11_mirror_externas.sh)). La variante `management` trae la UI web en el puerto 15672 |
| Credenciales en el Secret `rabbitmq-cred` | Las genera [scripts/30_rabbitmq_secret.sh](scripts/30_rabbitmq_secret.sh) y quedan en `.secrets/`, fuera de git. Los pods arman la URL con `$(RABBITMQ_USER)` y `$(RABBITMQ_PASS)`, que Kubernetes expande |
| Probes con `rabbitmq-diagnostics` | `ping` (liveness) revisa que el nodo esté vivo y `check_port_connectivity` (readiness) que acepte conexiones AMQP |

### 9.2 Topología
```
rabbit-writer ──publish (clave "report")──▶ exchange "war_reports" (direct)
                                                  │ binding "report"
                                                  ▼
                                            cola "war_reports" (durable) ──▶ consumer(s)
```

- El **productor publica en un exchange**, no en la cola. El exchange decide a qué colas va cada mensaje según la clave y los bindings. Así se podría agregar otra cola (por ejemplo, una de auditoría) sin tocar el writer.
- Exchange y cola son `durable` y los mensajes se publican como `Persistent`: sobreviven a un reinicio de RabbitMQ.
- Tanto el writer como el consumer declaran la topología al conectarse. La declaración es idempotente, así que no importa cuál arranque primero.

### 9.3 Writer: publisher confirms
El `rabbit-writer` activa el **modo confirm** del canal: RabbitMQ envía un `ack` cuando ya tomó la responsabilidad del mensaje. El writer espera ese `ack` antes de responder por gRPC, así que un `200` en Locust implica que el reporte quedó guardado en la cola. Todas las goroutines (una por llamada gRPC) comparten el mismo canal AMQP.

### 9.4 Consumer
| Aspecto | Implementación |
|---|---|
| Concurrencia | Pool de 8 goroutines (`WORKERS`) que leen del mismo canal de entregas |
| `ack` manual | Se confirma **después** de procesar. Si el pod muere a mitad, RabbitMQ reentrega los mensajes sin `ack` a otro consumer |
| Prefetch (`Qos`) | Máximo de `WORKERS × 10` mensajes sin `ack` por consumer. Limita la memoria del pod y reparte la carga entre réplicas |
| Mensaje inválido | `Nack` sin reencolar: si volviera a la cola, fallaría para siempre |
| Conexión perdida | El proceso termina y Kubernetes reinicia el contenedor (más simple que reconectar a mano). Al arrancar reintenta cada 3 s mientras RabbitMQ no esté listo |

Desde el bloque 5, el consumer guarda cada reporte en Valkey **antes** del `ack` (sección 10.3). Si Valkey falla, hace `Nack` con reencolado y el mensaje se reintenta.

### 9.5 Pruebas del bloque 4
**Flujo completo** con Locust (100 usuarios durante 60 s):

| Punto | Cantidad |
|---|---|
| Respuestas `200` en Locust | 13 524 (0 fallos, 226 req/s) |
| Publicados por `rabbit-writer` | 13 548 |
| Procesados por el consumer | 13 548 |
| Mensajes en la cola al terminar | 0 |

La diferencia entre Locust y el writer son peticiones que seguían en vuelo cuando Locust se detuvo y que no alcanzó a contar.

**Desacoplamiento: consumer caído.**

```bash
kubectl -n mumnk8s scale deploy/consumer --replicas=0
# Locust 20 s (50 usuarios)
kubectl -n mumnk8s exec rabbitmq-0 -- rabbitmqctl list_queues name messages consumers
kubectl -n mumnk8s scale deploy/consumer --replicas=1
```

| Momento | Mensajes en cola | Consumers |
|---|---|---|
| Consumer apagado, antes de la carga | 0 | 0 |
| Después de 20 s de carga (2 291 × `200` en Locust) | 2 305 | 0 |
| 15 s después de levantar el consumer | 0 | 1 |

Con el consumer caído, Locust siguió recibiendo `200` y los mensajes se acumularon en la cola. Al volver, el consumer procesó los 2 305 pendientes en menos de 10 s. El productor no depende de que el consumidor esté disponible.

## 10. Operator: Valkey y Grafana
Carpeta: [operator/](operator/). Es un operador **propio**, generado con Operator SDK (plugin Helm) según la [guía oficial](https://sdk.operatorframework.io/docs/building-operators/helm/quickstart/), con CRDs y charts escritos para este proyecto. Despliega las **imágenes oficiales** de Valkey y Grafana, espejadas en Zot. El auxiliar confirmó que este enfoque es el esperado.

```bash
operator-sdk init --plugins helm --domain so1.usac --project-name mumnk8s-operator
operator-sdk create api --group mumnk8s --version v1alpha1 --kind ValkeyInstance
```

El segundo comando generó un chart de ejemplo (nginx). Se reemplazó completo por los templates de Valkey.

### 10.1 Cómo funciona un operador basado en Helm
| Pieza | Archivo | Rol |
|---|---|---|
| CRD | [config/crd/bases/](operator/config/crd/bases/mumnk8s.so1.usac_valkeyinstances.yaml) | Registra el tipo nuevo `ValkeyInstance` (grupo `mumnk8s.so1.usac/v1alpha1`) en la API de Kubernetes |
| `watches.yaml` | [operator/watches.yaml](operator/watches.yaml) | Asocia cada *kind* con un chart: `ValkeyInstance` → `helm-charts/valkeyinstance` |
| Chart | [helm-charts/valkeyinstance/](operator/helm-charts/valkeyinstance/) | El estado deseado. El `spec` del CR se usa como `values.yaml` |
| Manager | Deployment `mumnk8s-operator-controller-manager` en `mumnk8s-operator-system` | Imagen `helm-operator` con los charts adentro. Vigila los CR y sus recursos hijos |
| RBAC | [config/rbac/role.yaml](operator/config/rbac/role.yaml) | Permisos del manager: los CR, StatefulSets, Services, ConfigMaps y PVCs, y los Secrets donde Helm guarda los releases |

**Ciclo de reconciliación.** Por cada evento del CR o de un recurso que creó:
1. Lee el `spec` del CR y lo pasa como *values* al chart.
2. Renderiza el chart y lo compara con lo que existe en el clúster (un release de Helm con el nombre del CR).
3. Si no existe, lo instala; si cambió el `spec`, hace `upgrade`; si alguien modificó o borró un recurso hijo, lo restaura.
4. Si se borra el CR, desinstala el release y borra los recursos que creó, salvo los PVC.
5. Escribe el resultado en `status.conditions` del CR (`Deployed`, `InstallSuccessful`, …).

### 10.2 Chart de Valkey
| Template | Qué crea | Detalle |
|---|---|---|
| [configmap.yaml](operator/helm-charts/valkeyinstance/templates/configmap.yaml) | `valkey.conf` | `appendonly yes` (AOF en el PVC), `maxmemory` y `maxmemory-policy` desde el CR |
| [statefulset.yaml](operator/helm-charts/valkeyinstance/templates/statefulset.yaml) | StatefulSet + un PVC por pod | El pod `-0` es el primario; si `replicas ≥ 2`, los demás arrancan con `--replicaof valkey-0.valkey-headless`. La anotación `checksum/config` reinicia los pods si cambia la configuración |
| [service.yaml](operator/helm-charts/valkeyinstance/templates/service.yaml) | `valkey`, `valkey-read`, `valkey-headless` | Escritura (solo el primario, por la etiqueta `pod-name`), lectura (todos los pods) y nombres DNS estables |

CR usado ([k8s/70-valkey.yaml](k8s/70-valkey.yaml)):

```yaml
apiVersion: mumnk8s.so1.usac/v1alpha1
kind: ValkeyInstance
metadata: { name: valkey, namespace: mumnk8s }
spec:
  replicas: 1        # 2 para la prueba de rendimiento con réplica
  maxmemory: 200mb
  persistence: { size: 1Gi }
```

**Expiración de datos (recomendación del enunciado).** La única clave que crece con el tiempo es la serie temporal (`ts:<país>`). Se recorta a unas 5000 entradas (`XADD MAXLEN ~`) y tiene un TTL de 24 h que se renueva en cada escritura. Con `maxmemory-policy volatile-lru`, al llegar a 200 MB Valkey solo puede expulsar claves con TTL, así que los agregados nunca se pierden.

### 10.3 Modelo de datos en Valkey
El consumer ([internal/store/store.go](go-services/internal/store/store.go)) actualiza todas las claves de un reporte en **un solo script Lua**. Lua se ejecuta de forma atómica dentro de Valkey: con varios consumers en paralelo, nadie lee un máximo o una moda a medias ni se pisan las comparaciones.

| Clave | Tipo | Contenido | Panel de Grafana |
|---|---|---|---|
| `max:planes`, `min:planes` | string | Máximo y mínimo general de aviones | Máx./Mín. aviones en aire |
| `max:ships`, `min:ships` | string | Máximo y mínimo general de barcos | Máx./Mín. barcos en mar |
| `freq:planes`, `freq:ships` | sorted set | valor → veces que apareció | (auxiliar de la moda) |
| `mode:planes`, `mode:ships` | string | Valor más frecuente. Se actualiza cuando un valor supera la frecuencia de la moda actual | Moda |
| `top:planes`, `top:ships` | sorted set | país → **suma acumulada** (`ZINCRBY`) | Top 5 países |
| `reports:GTM`, `reports:total` | string | Contadores (`INCR`) | Reportes recibidos de GTM |
| `ts:GTM` (uno por país) | stream | Entradas `{planes, ships}`. El ID del stream es la marca de tiempo en ms | Serie temporal de GTM |

El top usa la suma acumulada porque con valores aleatorios entre 0 y 50, el máximo por país sería 50 para todos y el promedio rondaría 25 en todos.

`valkey-go` hace *pipelining* automático: los 8 workers comparten una conexión y sus comandos viajan juntos. Cada script se envía con `EVALSHA` (solo el hash).

### 10.4 Pruebas del bloque 5
**Reconciliación.** Después de `kubectl apply -f k8s/70-valkey.yaml`:

```
$ kubectl -n mumnk8s get valkeyinstance valkey -o jsonpath='{.status.conditions[*].reason}'
InstallSuccessful
$ kubectl -n mumnk8s get sts,svc,pvc,cm
statefulset.apps/valkey   1/1
service/valkey  service/valkey-headless  service/valkey-read
persistentvolumeclaim/data-valkey-0   Bound   1Gi
configmap/valkey-config
```

**Autocorrección y persistencia.** Se guardó una clave de prueba y se borró el StatefulSet a mano (`kubectl delete sts valkey`). El operador lo recreó en unos 10 s; el pod nuevo montó el mismo PVC y la clave seguía ahí (recuperada del AOF).

**Datos tras 45 s de Locust (100 usuarios):**

| Clave | Valor |
|---|---|
| `reports:total` | 10 045 (igual a lo procesado por el consumer) |
| `reports:GTM` | 2017 |
| `max:planes` / `min:planes` | 50 / 0 |
| `max:ships` / `min:ships` | 30 / 0 |
| `mode:planes` / `mode:ships` | 31 / 26 |
| `top:planes` | USA 51 841, CHN 51 512, RUS 50 407, GTM 49 951, ESP 48 711 |
| `ts:GTM` | 2017 entradas, TTL 86 373 s |
| Memoria usada | 1.52 MB |

## 11. HPA
Manifiesto: [k8s/50-hpa.yaml](k8s/50-hpa.yaml). Escala `rust-api` entre **1 y 3 réplicas** con un objetivo de **30 % de CPU**.

- El porcentaje se calcula sobre `requests.cpu` (100m), así que el umbral es de unos 30m por pod. Por eso el Deployment debe tener los `requests` definidos.
- `metrics-server` (incluido en GKE) mide el consumo de cada pod y el HPA lo consulta cada 15 s.
- Fórmula: `réplicas = ceil(réplicas_actuales × uso_actual / uso_objetivo)`. Ejemplo: 1 réplica al 138 % da ceil(1 × 138 / 30) = 5, y se recorta al máximo de 3.
- Al bajar la carga, el HPA espera la ventana de estabilización (5 min por defecto) antes de reducir réplicas, para no oscilar.

### 11.1 Prueba de escalado
Locust sin interfaz con 200 usuarios (20 por segundo) durante 4 minutos contra la IP del Gateway:

```bash
locust -f locust/locustfile.py --host http://<IP_GATEWAY> --headless -u 200 -r 20 -t 4m
kubectl -n mumnk8s get hpa rust-api -w      # en otra terminal
```

| Hora | CPU promedio / objetivo | Réplicas |
|---|---|---|
| 19:41:46 | 0 % / 30 % | 1 |
| 19:42:08 | 34 % / 30 % | 2 |
| 19:42:29 | 138 % / 30 % | 3 |
| 19:43:52 | 70 % / 30 % | 3 |
| 19:45:58 | 45 % / 30 % | 3 |

Resultado de Locust: **109 623 peticiones**, unas **464 req/s**, mediana de 110 ms y p95 de 150 ms. Hubo 3 fallos (`503`, 0.00 %), atribuibles a la ventana en que el balanceador integraba las réplicas nuevas.

Observaciones:
- El escalado de 1 a 3 réplicas tomó **menos de 45 s**.
- Al aparecer las réplicas nuevas, la carga se repartió de forma pareja (unos 45m de CPU en cada pod `rust-api`).
- El cuello de botella siguiente es `go-api` (unos 550m entre sus dos contenedores), que no tiene HPA porque el enunciado solo lo pide para Rust.
- La CPU promedio se quedó en 45 %, por encima del 30 %, pero el HPA no puede pasar de `maxReplicas: 3`.
- Al terminar la carga, la CPU bajó a 0-1 %, pero el HPA mantuvo 3 réplicas durante la ventana de estabilización y volvió a **1 réplica** a las 19:53. La espera se alargó porque un rollout a las 19:47 (el cambio de memoria) generó un pico de arranque y reinició la ventana de 5 min.

## 12. OCI Artifact
_Pendiente (bloque 7): qué archivo JSON se publica en Zot, cómo se sube con `oras push` y cómo se consume._

## 13. Dashboard de Grafana
_Pendiente (bloque 6)._

## 14. Pruebas de carga y análisis de réplicas
_Pendiente (bloque 7): Locust; 1 vs. 2 réplicas en los Go writers y en Valkey._

## 15. Extras: Dapr y Falco
_Pendiente (bloque 8, opcional)._

## 16. Problemas encontrados y soluciones

| Problema | Causa | Solución |
|---|---|---|
| `ZONE_RESOURCE_POOL_EXHAUSTED` al crear la VM y el clúster | No había capacidad N1 en `us-central1-a` ni en `us-central1-b` | El script prueba varias zonas; todo quedó en `us-central1-c` |
| No se podía borrar el clúster atascado en `us-central1-a` | GKE no permite borrar un clúster mientras está en `CREATE_CLUSTER`, y esa operación no se puede cancelar | Se creó el clúster en otra zona (el nombre es único por zona) y el viejo se borra cuando termina la operación |
| `Compute Engine API has not been used` | Las APIs vienen deshabilitadas en un proyecto nuevo | `gcloud services enable compute.googleapis.com container.googleapis.com` |
| `rust-api` llegaba a 126Mi de memoria con un límite de 128Mi | El balanceador mantiene muchas conexiones keep-alive abiertas y cada una reserva buffers | Se subió el límite a 256Mi para evitar un OOMKill en pruebas largas |
| `stream error: INTERNAL_ERROR` al copiar RabbitMQ a Zot | `imagetools create` subía en paralelo los blobs de todas las arquitecturas y la VM pequeña de Zot no lo soportó | Copiar solo `--platform linux/amd64`, que es lo único que usan los nodos N1 |
| Con 2 réplicas de `go-writer`, la nueva no recibía tráfico | Conexión HTTP/2 persistente, y el resolver DNS de grpc-go no vuelve a consultar | Service headless, `round_robin` y `MaxConnectionAge` en el servidor (sección 8.5) |
| El formula `rustup` de Homebrew no trae `rustup-init` | Cambio de empaquetado (keg-only) | Se usa `$(brew --prefix rustup)/bin/rustup default stable` |

## 17. Conclusiones
_Pendiente._
