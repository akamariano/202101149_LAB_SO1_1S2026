# Guía de Instalación. Proyecto 1, Sistemas Operativos 1

| Campo | Valor |
|---|---|
| Nombre | Mariano Rac |
| Carné | 202101149 |

Esta guía describe cómo levantar el entorno completo desde cero, en un host Ubuntu con soporte de virtualización por hardware activo.

## 1. Requisitos previos del host

Verificar que el procesador soporte virtualización por hardware.

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

El resultado debe ser mayor a 0. Si es 0, activar Intel VT-x o AMD-V en el BIOS o UEFI antes de continuar.

## 2. Instalación de KVM, QEMU y libvirt

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils
```

Verificar que el servicio esté activo.

```bash
sudo systemctl status libvirtd
```

Debe mostrar active running. Verificar acceso con virsh.

```bash
sudo virsh --connect qemu:///system list --all
```

Si aparece un error de permisos, agregar el usuario a los grupos correspondientes.

```bash
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER
```

(requiere cerrar sesión y volver a entrar para que el cambio tome efecto)

## 3. Descarga de la imagen base

```bash
mkdir -p ~/vms/images
cd ~/vms/images
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
```

## 4. Creación de las 3 máquinas virtuales

El proceso es el mismo para las 3 VMs, cambiando el nombre. A continuación el ejemplo con VM1.

```bash
mkdir -p ~/vms/vm1-containerd
cd ~/vms/vm1-containerd

qemu-img create -f qcow2 -F qcow2 -b ~/vms/images/jammy-server-cloudimg-amd64.img vm1-disk.qcow2 20G

cat > user-data << 'EOF'
#cloud-config
hostname: vm1-containerd
manage_etc_hosts: true
users:
  - name: mariano
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: 'so1lab2026'
    ssh_pwauth: true
chpasswd:
  expire: false
package_update: true
packages:
  - curl
  - net-tools
EOF

cat > meta-data << 'EOF'
instance-id: vm1-containerd
local-hostname: vm1-containerd
EOF

genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data

sudo apt install -y acl
sudo setfacl -m u:libvirt-qemu:--x /home/mariano
sudo setfacl -m u:libvirt-qemu:--x /home/mariano/vms
sudo setfacl -m u:libvirt-qemu:--x /home/mariano/vms/vm1-containerd

sudo virt-install \
  --name vm1-containerd \
  --memory 1536 \
  --vcpus 1 \
  --disk path=/home/mariano/vms/vm1-containerd/vm1-disk.qcow2,format=qcow2 \
  --disk path=/home/mariano/vms/vm1-containerd/seed.iso,device=cdrom \
  --os-variant ubuntu22.04 \
  --network network=default \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole
```

Repetir el mismo proceso para vm2-podman y vm3-docker, cambiando el nombre en cada archivo y comando. Cada VM queda con 1 vCPU, 1536MB de RAM y 20GB de disco.

## 5. Instalación de runtimes dentro de cada VM

Conectarse a cada VM.

```bash
sudo virsh --connect qemu:///system start <nombre_vm>
sudo virsh --connect qemu:///system console <nombre_vm>
```

Usuario mariano, contraseña so1lab2026. Salir de la consola sin apagar la VM con Ctrl seguido de corchete de cierre.

### VM1, containerd

```bash
sudo apt update
sudo apt install -y containerd

# Cliente nerdctl
cd /tmp
wget https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-amd64.tar.gz
sudo tar Cxzvvf /usr/local/bin nerdctl-1.7.6-linux-amd64.tar.gz

# Plugins de red CNI
wget https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvvf /opt/cni/bin cni-plugins-linux-amd64-v1.5.1.tgz

# BuildKit, para poder construir imágenes
BUILDKIT_VERSION=v0.14.1
wget https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz
sudo tar Cxzvvf /usr/local buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz

sudo tee /etc/systemd/system/buildkit.service << 'EOF'
[Unit]
Description=BuildKit
[Service]
ExecStart=/usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now buildkit

# Prueba
sudo nerdctl run --rm hello-world
```

### VM2, podman

```bash
sudo apt update
sudo apt install -y podman

# Definir registro por defecto para nombres cortos de imagen
echo 'unqualified-search-registries = ["docker.io"]' | sudo tee -a /etc/containers/registries.conf

# Prueba
podman run --rm hello-world
```

### VM3, docker

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Prueba
sudo docker run --rm hello-world
```

## 6. Registro Zot, dentro de VM3

```bash
mkdir -p ~/zot/data
cat > ~/zot/config.json << 'EOF'
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/var/lib/registry" },
  "http": { "address": "0.0.0.0", "port": "5000" },
  "log": { "level": "info" }
}
EOF

sudo docker run -d --name zot --restart unless-stopped \
  -p 5000:5000 \
  -v ~/zot/config.json:/etc/zot/config.json \
  -v ~/zot/data:/var/lib/registry \
  ghcr.io/project-zot/zot:latest

# Prueba
curl http://localhost:5000/v2/
```

## 7. Obtención del código en cada VM

El código fuente vive en un repositorio privado de GitHub. Para clonarlo dentro de cada VM se usa un Personal Access Token de GitHub, con permiso de solo lectura sobre el contenido del repositorio.

```bash
sudo apt install -y git
git clone https://TU_TOKEN@github.com/TU_USUARIO/202101149_LAB_SO1_1S2026.git
```

Antes de cualquier build, verificar que los archivos Dockerfile y main.go no estén vacíos, con cat, ya que en este proyecto se presentó ese problema por falta de autoguardado en el editor original.

## 8. Construcción de imágenes

En cada VM, dentro de la carpeta de su API correspondiente.

```bash
# VM1
cd ~/202101149_LAB_SO1_1S2026/api1-containerd
sudo nerdctl build -t api1-202101149:latest .

# VM2
cd ~/202101149_LAB_SO1_1S2026/api2-podman
podman build -t api2-202101149:latest .

# VM3
cd ~/202101149_LAB_SO1_1S2026/api3-docker-zot
sudo docker build -t api3-202101149:latest .
```

## 9. Configuración de containerd para registro sin TLS

Solo necesario en VM1, ya que containerd exige TLS por defecto.

```bash
sudo mkdir -p /etc/containerd/certs.d/192.168.122.76:5000
sudo tee /etc/containerd/certs.d/192.168.122.76:5000/hosts.toml << 'EOF'
server = "http://192.168.122.76:5000"
[host."http://192.168.122.76:5000"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

## 10. Publicación de imágenes en Zot

En VM1, la imagen requiere conversión previa a formato OCI, ya que nerdctl genera manifiestos en formato Docker por defecto.

```bash
sudo nerdctl image convert --oci api1-202101149:latest api1-202101149:oci
sudo nerdctl tag api1-202101149:oci 192.168.122.76:5000/api1-202101149:latest
sudo nerdctl push 192.168.122.76:5000/api1-202101149:latest
```

En VM2, podman genera manifiestos OCI de forma nativa, no requiere conversión.

```bash
podman tag api2-202101149:latest 192.168.122.76:5000/api2-202101149:latest
podman push 192.168.122.76:5000/api2-202101149:latest --tls-verify=false
```

En VM3, el push se hace directo a localhost, ya que Zot corre en la misma VM.

```bash
sudo docker tag api3-202101149:latest localhost:5000/api3-202101149:latest
sudo docker push localhost:5000/api3-202101149:latest
```

## 11. Despliegue final de contenedores con IPs reales

Las variables de entorno API1_URL, API2_URL y API3_URL deben apuntar a la IP real de la VM donde vive cada API, incluso entre contenedores de la misma VM, ya que cada contenedor tiene su propio namespace de red y localhost no los conecta entre sí.

```bash
# En VM1
sudo nerdctl run -d --name api1 -p 8081:8081 \
  -e API2_URL=http://192.168.122.227:8082 \
  -e API3_URL=http://192.168.122.92:8083 \
  api1-202101149:latest

sudo nerdctl pull 192.168.122.76:5000/api2-202101149:latest
sudo nerdctl run -d --name api2 -p 8082:8082 \
  -e API1_URL=http://192.168.122.227:8081 \
  -e API3_URL=http://192.168.122.92:8083 \
  192.168.122.76:5000/api2-202101149:latest

# En VM2
podman pull 192.168.122.76:5000/api3-202101149:latest --tls-verify=false
podman run -d --name api3 -p 8083:8083 \
  -e API1_URL=http://192.168.122.227:8081 \
  -e API2_URL=http://192.168.122.227:8082 \
  192.168.122.76:5000/api3-202101149:latest
```

## 12. Verificación final

```bash
curl http://192.168.122.227:8081/health
curl http://192.168.122.227:8082/health
curl http://192.168.122.92:8083/health

curl http://192.168.122.227:8081/api1/202101149/call-api2
curl http://192.168.122.227:8081/api1/202101149/call-api3
curl http://192.168.122.227:8082/api2/202101149/call-api1
curl http://192.168.122.227:8082/api2/202101149/call-api3
curl http://192.168.122.92:8083/api3/202101149/call-api1
curl http://192.168.122.92:8083/api3/202101149/call-api2

curl http://192.168.122.76:5000/v2/_catalog
```

Todos los endpoints de llamada cruzada deben devolver connection true, y el catálogo de Zot debe mostrar las 3 imágenes publicadas.