# Manual Técnico. Proyecto 1, Sistemas Operativos 1

| Campo | Valor |
|---|---|
| Nombre | Mariano Rac |
| Carné | 202101149 |
| Curso | Sistemas Operativos 1, 2do Semestre 2026 |
| Repositorio | 202101149_LAB_SO1_1S2026 |

## 1. Introducción

Este documento describe la arquitectura, la implementación y las pruebas realizadas para el Proyecto 1 del curso. El sistema consiste en 3 máquinas virtuales administradas con KVM, cada una con un runtime de contenedores distinto, que alojan 3 APIs REST desarrolladas en Go y un registro de imágenes privado (Zot). Las APIs se comunican entre sí a través de la red interna creada por libvirt.

## 2. Diagrama de arquitectura

El sistema está compuesto por 3 máquinas virtuales dentro de un entorno virtualizado con KVM y libvirt, conectadas por una red interna con IP estática. La comunicación entre los servicios se realiza usando REST sobre HTTP, con formato de datos JSON.

VM1 usa containerd como runtime, y aloja los contenedores de API1 y API2. VM2 usa podman, y aloja el contenedor de API3. VM3 usa Docker, y aloja el contenedor del registro Zot, que sirve como repositorio privado de imágenes para las tres APIs.

(Insertar aquí el diagrama del enunciado del proyecto, guardado como Images/diagrama-enunciado.png o el nombre que le hayas dado)

## 3. Resumen de infraestructura

| VM | Runtime | Contenedor(es) | Hostname | IP |
|---|---|---|---|---|
| VM1 | containerd | API1, API2 | vm1_containerd | 192.168.122.227 |
| VM2 | podman | API3 | vm2_podman | 192.168.122.92 |
| VM3 | docker | Zot (registro) | vm3_docker | 192.168.122.76 |

Zot está expuesto en el puerto 5000 dentro de VM3, y es accesible desde las otras VMs usando la dirección http://192.168.122.76:5000.

Especificaciones por VM. host físico ASUS X555LN con Ubuntu en dual boot, 4 hilos de CPU con Intel VT x activo, 7.6GB de RAM y 534GB de disco. Cada VM tiene 1 vCPU, 1536MB de RAM y un disco de 20GB en formato qcow2. La imagen base es Ubuntu 22.04 Server Cloud Image, configurada con cloud init. La red usada es la red NAT por defecto de libvirt, en el rango 192.168.122.2 a 192.168.122.254.

## 4. Estructura de las APIs

Las 3 APIs están escritas en Go, sin frameworks externos, usando únicamente el paquete estándar net/http. Cada una expone un endpoint principal de salud y dos endpoints de llamada cruzada hacia las otras dos APIs.

Formato de respuesta del endpoint /health.

```json
{
  "status": "UP",
  "message": "API# is Ready",
  "timestamp": "2026-01-01T00:00:00Z",
  "VM": "#",
  "carnet": "202101149"
}
```

Formato de respuesta de los endpoints de llamada cruzada, por ejemplo /api2/202101149/call-api1.

```json
{
  "apiname": "API1",
  "message": "The API1 located on the VM1 is working",
  "connection": true,
  "carnet": "202101149"
}
```

Si la API destino no responde, el mensaje cambia a formato de error y el campo connection queda en false.

```json
{
  "apiname": "API1",
  "message": "ERROR: The API1 located on the VM1 is not working",
  "connection": false,
  "carnet": "202101149"
}
```

Las URLs de destino de cada API se configuran mediante variables de entorno (API1_URL, API2_URL, API3_URL), con valor por defecto localhost para pruebas locales, y las IPs reales de las VMs al desplegar los contenedores.

## 5. Construcción de imágenes

Las 3 imágenes se construyen con la técnica de multi stage build. La primera etapa usa golang:1.22-alpine para compilar el binario, y la segunda etapa usa alpine:latest y copia únicamente el binario ya compilado. Esto reduce el tamaño final de la imagen de más de 800MB a aproximadamente 16 a 25MB.

Nombres de imagen, respetando el formato exigido API#-CARNET.

| Imagen | Runtime de build | Tamaño |
|---|---|---|
| api1-202101149:latest | nerdctl, en VM1 | 8.1 MiB (comprimida) |
| api2-202101149:latest | podman, en VM2 | 16.7 MB |
| api3-202101149:latest | docker, en VM3 | 25.6 MB |

## 6. Registro Zot

Zot corre como contenedor Docker dentro de VM3, en el puerto 5000, con almacenamiento persistente en un volumen local. Las tres imágenes se suben (push) a este registro desde su VM de origen, y se descargan (pull) desde las otras VMs cuando es necesario correr un contenedor de una API que no fue construida localmente.

Catálogo de imágenes disponibles en el registro.

```
GET http://192.168.122.76:5000/v2/_catalog
```

![Catálogo de Zot](Images/Cap7.jpeg)

## 7. Problemas encontrados y soluciones

**Problema.** El comando virt_install mostraba Permiso denegado al acceder al disco.
**Causa.** El servicio libvirtd corre como el usuario de sistema libvirt qemu, que no tiene acceso a la carpeta /home/mariano por los permisos por defecto.
**Solución.** Se aplicó un ACL específico en cada carpeta de la ruta, con el comando sudo setfacl -m u:libvirt-qemu:--x seguido de la carpeta.

**Problema.** Al correr virsh list --all sin sudo, aparecía el error failed to connect to the hypervisor.
**Causa.** La conexión por defecto es qemu:///session, y no qemu:///system, que es la que administra las VMs creadas con sudo.
**Solución.** Usar siempre la opción connect qemu:///system, o correr virsh con sudo.

**Problema.** El comando nerdctl build mostraba el mensaje buildctl needs to be installed.
**Causa.** Containerd no incluye un motor de build por defecto, a diferencia de Docker.
**Solución.** Se instaló BuildKit y se configuró como servicio de systemd.

**Problema.** Al correr nerdctl run hello world, fallaba la creación de la red por CNI.
**Causa.** Containerd no trae incluidos los plugins de red CNI.
**Solución.** Se instalaron los plugins CNI en la ruta /opt/cni/bin.

**Problema.** Al hacer push hacia Zot desde VM1, aparecía el error 415 Unsupported Media Type.
**Causa.** El comando nerdctl build genera manifiestos en formato Docker, y Zot solo acepta el formato OCI estándar.
**Solución.** Se convirtió la imagen antes de hacer push, con el comando nerdctl image convert --oci. Podman y Docker no presentaron este problema.

**Problema.** El comando podman build mostraba el mensaje short name did not resolve to an alias.
**Causa.** Podman no asume un registro por defecto para nombres cortos de imagen, por razones de seguridad.
**Solución.** Se definió unqualified search registries igual a docker.io en el archivo /etc/containers/registries.conf.

**Problema.** El archivo Dockerfile llegaba vacío después de hacer git clone dentro de las VMs.
**Causa.** El editor usado en macOS al crear los archivos originales no tenía activado el autoguardado.
**Solución.** Se verifica el contenido con cat Dockerfile antes de cada build, y se recrea con un heredoc si aparece vacío.

**Problema.** Las llamadas cruzadas entre API1 y API2 fallaban con connection false, aunque ambas corrían en la misma VM.
**Causa.** Cada contenedor tiene su propio namespace de red. El localhost dentro de un contenedor apunta a su propio loopback interno, no al de la VM ni al de otros contenedores.
**Solución.** Se configuraron las variables de entorno de las dos APIs usando la IP real de la VM (192.168.122.227) en vez de localhost, incluso para llamadas entre contenedores de la misma máquina.

**Problema.** Al intentar correr en VM1 y VM2 el contenedor de una API construida en otra VM, aparecía el error pull access denied al buscarla en Docker Hub.
**Causa.** Las imágenes de las APIs se construyen de forma local en cada VM, con el runtime correspondiente, y ese nombre local no existe en ningún registro público.
**Solución.** Se descarga la imagen desde el registro Zot antes de correrla, usando pull con el nombre completo del registro (192.168.122.76:5000/api#-202101149).

**Problema.** Al apagar y volver a encender las VMs, los contenedores no quedaban corriendo automáticamente.
**Causa.** Por defecto, los runtimes no reinician los contenedores al reiniciar la VM ni el host, salvo que se configure explícitamente.
**Solución.** Se agregó al checklist previo a cualquier prueba o calificación, encender las 3 VMs y luego iniciar manualmente cada contenedor (ver sección 9, Pruebas).

**Problema.** En VM1, al reactivar un contenedor detenido con start (en vez de crearlo de nuevo), aparecía un error de CNI indicando IP duplicada (duplicate allocation is not allowed).
**Causa.** Cuando la VM se apaga sin que el contenedor libere limpiamente su IP asignada por el plugin bridge de CNI, queda un registro de esa IP como si siguiera en uso.
**Solución.** En vez de reactivar el contenedor con start, se elimina con rm -f y se vuelve a crear con run. Este problema es específico de containerd y nerdctl, no se presentó con podman ni con Docker.

**Problema.** Al correr docker en VM3 sin sudo, aparecía permission denied while trying to connect to the docker API.
**Causa.** El usuario mariano no pertenece al grupo docker, que es el que tiene permiso sobre el socket /var/run/docker.sock.
**Solución.** Se puede agregar el usuario al grupo con sudo usermod -aG docker seguido del usuario (requiere cerrar sesión y volver a entrar), o simplemente anteponer sudo a cada comando de Docker, que es la opción usada en este proyecto.

## 8. Guía de instalación

Ver el archivo guia-instalacion.md, que contiene el paso a paso completo desde cero para levantar el entorno.

## 9. Pruebas y evidencia

Esta sección sigue el mismo orden que la guía de calificación del curso, con el comando exacto usado en cada punto y la evidencia correspondiente.

### 9.0 Checklist previo a cualquier prueba o calificación

Antes de correr cualquier prueba, siempre encender las 3 VMs y verificar que los contenedores estén corriendo. Esto evita perder tiempo durante la calificación.

```bash
sudo virsh --connect qemu:///system start vm1-containerd
sudo virsh --connect qemu:///system start vm2-podman
sudo virsh --connect qemu:///system start vm3-docker
```

Dentro de cada VM, verificar contenedores y arrancarlos si es necesario.

```bash
# VM1 (containerd)
sudo nerdctl ps -a
# si api1 o api2 no están Up, no usar start, eliminar y recrear:
sudo nerdctl rm -f api1 api2
sudo nerdctl run -d --name api1 -p 8081:8081 \
  -e API2_URL=http://192.168.122.227:8082 \
  -e API3_URL=http://192.168.122.92:8083 \
  api1-202101149:latest
sudo nerdctl run -d --name api2 -p 8082:8082 \
  -e API1_URL=http://192.168.122.227:8081 \
  -e API3_URL=http://192.168.122.92:8083 \
  192.168.122.76:5000/api2-202101149:latest

# VM2 (podman)
podman ps -a
# si api3 no está Up:
podman start api3

# VM3 (docker)
sudo docker ps -a
# si zot no está Up:
sudo docker start zot
```

### 9.1 Validación de máquinas virtuales y KVM

```bash
virsh list --all
```

Muestra las 3 VMs con estado running. También se puede abrir Virtual Machine Manager para verificar visualmente.

![Listado de VMs con virsh](Images/Cap21.jpeg)

### 9.2 Validación de runtimes

VM1, verificar containerd.
```bash
sudo ctr namespace ls
sudo systemctl status containerd
docker info
```
El comando docker info debe fallar (comando no encontrado), confirmando que Docker no está instalado en esta VM.

![Validación containerd en VM1](Images/Cap20.jpeg)

VM2, verificar podman.
```bash
podman info
podman -v
docker info
```
El comando docker info también debe fallar en esta VM.

![Validación podman en VM2](Images/Cap19.jpeg)

VM3, verificar Docker.
```bash
docker info
docker -v
```

![Validación docker en VM3](Images/Cap18.jpeg)

### 9.3 Contenedores en ejecución y código en Go

```bash
# VM1
sudo ctr -n default containers ls

# VM2
podman ps

# VM3
docker ps
```

![Contenedores en ejecución, VM1](Images/Cap17.jpeg)
![Contenedores en ejecución, VM2](Images/Cap16.jpeg)
![Contenedores en ejecución, VM3](Images/Cap15.jpeg)

El código fuente de las 3 APIs está en Go, ubicado en las carpetas api1-containerd, api2-podman y api3-docker-zot del repositorio, cada una con su archivo main.go y go.mod. Las rutas respetan el formato exigido, por ejemplo /api1/202101149/call-api2.

### 9.4 Endpoint /health

```bash
curl -s http://192.168.122.227:8081/health | jq .
curl -s http://192.168.122.227:8082/health | jq .
curl -s http://192.168.122.92:8083/health | jq .
```

Las 3 respuestas devuelven status UP con el formato JSON exacto especificado en el enunciado.

![Health API1](Images/Cap14.jpeg)
![Health API2](Images/Cap13.jpeg)
![Health API3](Images/Cap12.jpeg)

### 9.5 Dockerfiles e imágenes

```bash
# VM1
sudo ctr -n default images ls

# VM2
podman images

# VM3
sudo docker images
cd ~/202101149_LAB_SO1_1S2026/api3-docker-zot
sudo cat Dockerfile
```

Las imágenes respetan el formato API#-202101149 en su nombre.

![Imágenes VM1](Images/Cap11.jpeg)
![Imágenes VM2](Images/Cap10.jpeg)
![Imágenes VM3](Images/Cap9.jpeg)
![Dockerfile VM3](Images/Cap8.jpeg)

### 9.6 Registro Zot y catálogo de imágenes

```bash
curl http://192.168.122.76:5000/v2/_catalog
```

Resultado esperado, las 3 imágenes listadas.

```json
{"repositories":["api1-202101149","api2-202101149","api3-202101149"]}
```

![Catálogo de Zot](Images/Cap7.jpeg)

### 9.7 Comunicación cruzada entre APIs

```bash
curl http://192.168.122.227:8081/api1/202101149/call-api2
curl http://192.168.122.227:8081/api1/202101149/call-api3
curl http://192.168.122.227:8082/api2/202101149/call-api1
curl http://192.168.122.227:8082/api2/202101149/call-api3
curl http://192.168.122.92:8083/api3/202101149/call-api1
curl http://192.168.122.92:8083/api3/202101149/call-api2
```

Los 6 endpoints devuelven connection true, confirmando comunicación real entre las 3 VMs.

![API1 llama a API2](Images/Cap6.jpeg)
![API1 llama a API3](Images/Cap5.jpeg)
![API2 llama a API1](Images/Cap4.jpeg)
![API2 llama a API3](Images/Cap3.jpeg)
![API3 llama a API1](Images/Cap2.jpeg)
![API3 llama a API2](Images/Cap1.jpeg)

### 9.8 Qué hacer si las imágenes no cargan 

Primero, confirmar que la VM correspondiente está encendida, con virsh list --all. Si aparece apagada, encenderla y esperar a que cloud init y los servicios terminen de levantar, esto puede tardar entre 30 segundos y 2 minutos.

Segundo, si la VM está encendida pero el runtime no responde, verificar el servicio. En VM1, sudo systemctl status containerd. En VM3, sudo systemctl status docker. Si no está active running, reiniciar el servicio con sudo systemctl restart seguido del nombre del servicio.

Tercero, si el servicio está activo pero no aparecen las imágenes esperadas, es probable que se haya perdido la referencia local. Se pueden volver a descargar desde Zot sin necesidad de reconstruirlas, usando pull con el nombre completo del registro, por ejemplo sudo nerdctl pull 192.168.122.76:5000/api1-202101149:latest, o el comando equivalente en podman o docker.

Cuarto, si el contenedor existe pero no está corriendo, usar start para reactivarlo, salvo en VM1 con containerd, donde si aparece un error de CNI con IP duplicada, la solución es eliminar el contenedor con rm -f y volver a crearlo con run, usando el mismo comando de la sección 9.0 de este documento.

Quinto, si Zot no responde en el puerto 5000 desde otra VM, aunque sí responda con localhost dentro de VM3, verificar que el contenedor de Zot esté escuchando en 0.0.0.0 y no solo en 127.0.0.1, revisando el archivo de configuración en ~/zot/config.json dentro de VM3, y que la IP usada en la prueba sea la correcta, 192.168.122.76.

En caso de que ninguna de estas soluciones funcione en el momento de la calificación, mostrar este documento como evidencia de que el sistema fue probado y funcionó correctamente en una sesión previa, con las capturas correspondientes.