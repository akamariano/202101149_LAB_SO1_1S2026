# Configuración de Infraestructura. Proyecto 1, SO1

| Campo | Valor |
|---|---|
| Nombre | Mariano Rac |
| Carné | 202101149 |
| Curso | Sistemas Operativos 1, 2do Semestre 2026 |
| Repositorio | 202101149_LAB_SO1_1S2026 |

## 1. Resumen de infraestructura

| VM | Runtime | Contenedor(es) | Hostname | IP |
|---|---|---|---|---|
| VM1 | containerd | API1, API2 | vm1_containerd | 192.168.122.227 |
| VM2 | podman | API3 | vm2_podman | 192.168.122.92 |
| VM3 | docker | Zot (registro) | vm3_docker | 192.168.122.76 |

Zot está expuesto en el puerto 5000 dentro de VM3, y es accesible desde las otras VMs usando la dirección http://192.168.122.76:5000.

## 2. Especificaciones de cada VM

El host físico es una laptop ASUS X555LN con Ubuntu en dual boot, 4 hilos de CPU con Intel VT x activo, 7.6GB de RAM y 534GB de disco.

El hypervisor usado es KVM junto con QEMU, administrado con libvirt (conexión qemu:///system).

Cada VM tiene 1 vCPU, 1536MB de RAM y un disco de 20GB en formato qcow2 (con backing file compartido entre las 3, y crecimiento dinámico según el uso real).

La imagen base es Ubuntu 22.04 (Jammy) Server Cloud Image (jammy server cloudimg amd64.img), sin entorno gráfico, configurada con cloud init en lugar de un instalador manual.

La red usada es la red NAT por defecto de libvirt (virbr0, en el rango 192.168.122.2 a 192.168.122.254), con salida a internet y comunicación libre entre las VMs.

El usuario creado en cada VM es mariano, generado automáticamente por cloud init a través del archivo user data.

### Por qué se usó cloud init en lugar de instalación manual

Se usó una imagen cloud (un disco ya preinstalado y minimizado) en vez del ISO tradicional con instalador interactivo. En el primer arranque, cada VM lee un seed ISO (volumen cidata) que contiene dos archivos.

El archivo user data define el usuario, la contraseña, los paquetes iniciales y el hostname. El archivo meta data define la identidad básica de la instancia (instance id y local hostname).

Con esto se automatiza y se acelera el despliegue de las 3 VMs, sin intervención manual durante la instalación del sistema operativo. Este es el mismo mecanismo que usan proveedores en la nube como AWS, GCP y Oracle Cloud cuando lanzan instancias nuevas.

## 3. Comandos esenciales de manejo de VMs

```bash
# Listar todas las VMs (corriendo y apagadas)
sudo virsh --connect qemu:///system list --all

# Encender una VM
sudo virsh --connect qemu:///system start <nombre_vm>

# Conectarse a la consola serial (login interactivo)
sudo virsh --connect qemu:///system console <nombre_vm>
# Salir de la consola sin apagar la VM: Ctrl + ]

# Apagar una VM de forma ordenada (equivalente a shutdown normal)
sudo virsh --connect qemu:///system shutdown <nombre_vm>

# Apagar de forma forzada (equivalente a desconectar el cable)
sudo virsh --connect qemu:///system destroy <nombre_vm>

# Eliminar la definición de una VM (esto no borra el disco)
sudo virsh --connect qemu:///system undefine <nombre_vm>

# Ver la información de los recursos asignados
sudo virsh --connect qemu:///system dominfo <nombre_vm>
```

## 4. Problemas encontrados y soluciones

**Problema.** El comando virt_install mostraba "Permiso denegado" al acceder al disco.
**Causa.** El servicio libvirtd corre como el usuario de sistema libvirt qemu, que no tiene acceso a la carpeta /home/mariano (permisos 700 por defecto).
**Solución.** Se aplicó un ACL específico en cada carpeta de la ruta, usando el comando sudo setfacl -m u:libvirt-qemu:--x <carpeta>.

**Problema.** Al correr virsh list --all sin sudo, aparecía el error "failed to connect to the hypervisor".
**Causa.** La conexión por defecto es qemu:///session (VMs de usuario), y no qemu:///system (VMs administradas por el demonio, que son las que usa virt install con sudo).
**Solución.** Usar siempre la opción connect qemu:///system, o correr virsh con sudo.

**Problema.** El comando nerdctl build mostraba el mensaje "buildctl needs to be installed".
**Causa.** Containerd no incluye un motor de build por defecto, a diferencia de Docker.
**Solución.** Se instaló BuildKit (los binarios buildkitd y buildctl) y se configuró para correr como servicio de systemd.

**Problema.** Al correr nerdctl run hello world, fallaba la creación de la red por CNI.
**Causa.** Containerd no trae incluidos los plugins de red CNI.
**Solución.** Se instalaron los plugins CNI en la ruta /opt/cni/bin (paquete de containernetworking/plugins).

**Problema.** Al hacer push hacia Zot, aparecía el error 415 Unsupported Media Type (esto solo ocurría con containerd y nerdctl).
**Causa.** El comando nerdctl build genera manifiestos en formato Docker (vnd.docker.distribution.manifest.v2+json), y Zot solo acepta el formato OCI estándar.
**Solución.** Se convirtió la imagen antes de hacer push, usando el comando nerdctl image convert --oci seguido del nombre de la imagen. Luego se etiquetó y se subió esa versión convertida. Podman no presentó este problema, ya que genera manifiestos OCI de forma nativa.

**Problema.** El comando podman build mostraba el mensaje "short name did not resolve to an alias".
**Causa.** Podman no asume un registro por defecto para nombres cortos de imagen, como golang:1.22 alpine, por razones de seguridad.
**Solución.** Se definió la línea unqualified search registries igual a docker.io dentro del archivo /etc/containers/registries.conf.

**Problema.** El archivo Dockerfile llegaba vacío después de hacer git clone dentro de las VMs.
**Causa.** El editor usado en macOS al crear los archivos originales no tenía activado el autoguardado.
**Solución.** Se verifica el contenido con el comando cat Dockerfile antes de cada build, y se recrea el archivo con un heredoc si aparece vacío.

## 5. Registro Zot

La configuración usada, guardada en zot/config.json dentro de VM3, es la siguiente.

```json
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/var/lib/registry" },
  "http": { "address": "0.0.0.0", "port": "5000" },
  "log": { "level": "info" }
}
```

Zot se corre como un contenedor Docker con el siguiente comando.

```bash
sudo docker run -d --name zot --restart unless-stopped \
  -p 5000:5000 \
  -v ~/zot/config.json:/etc/zot/config.json \
  -v ~/zot/data:/var/lib/registry \
  ghcr.io/project-zot/zot:latest
```

Para verificar que funciona correctamente, se usan estos comandos.

```bash
curl http://192.168.122.76:5000/v2/
curl http://192.168.122.76:5000/v2/<imagen>/tags/list
```

## 6. Imágenes construidas y publicadas

| Imagen | Runtime de build | Tamaño | Registro Zot |
|---|---|---|---|
| api1_202101149:latest | nerdctl (VM1) | 16.3 MiB | Publicada en 192.168.122.76:5000/api1-202101149 |
| api2_202101149:latest | podman (VM2) | 16.7 MB | Publicada en 192.168.122.76:5000/api2-202101149 |
| api3_202101149:latest | docker (VM3) | pendiente | pendiente |

Todas las imágenes se construyeron usando la técnica de multi stage build. Esto significa que se usa una etapa con golang:1.22 alpine para compilar el código, y una etapa final con alpine:latest que solo copia el binario ya compilado. Con esto, el tamaño de la imagen se reduce de más de 800MB a aproximadamente 16MB.