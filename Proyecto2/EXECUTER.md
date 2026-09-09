# Ejecución del Proyecto 2 - Sistemas Operativos 1 (202101149)

Este documento explica cómo levantar y detener el sistema completo (módulo de kernel, Valkey, Grafana, y el daemon en Go) desde cero, y cómo diagnosticar los problemas más comunes que aparecieron durante el desarrollo.

Todo esto se ejecuta en el Ubuntu dual boot (ASUS X555LN), no en el Mac, porque el módulo de kernel y la sonda eBPF necesitan un kernel Linux real.

## Orden de arranque
### Usando Script sh
cd ~/202101149_LAB_SO1_1S2026/Proyecto2
./rebuild_all.sh
### 1. Compilar y cargar el módulo de kernel

Se recomienda recompilar siempre, incluso si el módulo ya estaba cargado de una sesión anterior, porque el kernel de Ubuntu puede haberse actualizado en segundo plano desde la última vez (ver la sección de problemas conocidos más abajo).

```bash
cd ~/202101149_LAB_SO1_1S2026/Proyecto2/kernel-module/src
make clean
make
sudo rmmod continfo 2>/dev/null || true
sudo insmod continfo.ko
cat /proc/continfo_pr2_so1_202101149
```

Si el `cat` muestra la telemetría de RAM y la lista de procesos de contenedores, el módulo quedó cargado correctamente.

### 2. Levantar Valkey y Grafana

```bash
cd ~/202101149_LAB_SO1_1S2026/Proyecto2
sudo docker compose up -d
```

Verificar que ambos contenedores están arriba:

```bash
sudo docker ps
```

Deberían aparecer `valkey-db` y `grafana-valkey` con estado `Up`.

### 3. Compilar y correr el daemon en Go

Si se modificó algún archivo `.c` de la sonda eBPF, regenerar primero el bytecode:

```bash
cd ~/202101149_LAB_SO1_1S2026/Proyecto2/daemon-go
go generate ./...
```

Compilar y ejecutar:

```bash
go build -o daemon-go ./cmd/main.go
sudo ./daemon-go
```

El daemon, al arrancar, hace lo siguiente en orden: levanta Valkey y Grafana (si no estaban ya arriba), carga el módulo de kernel (si no estaba cargado), inicia la sonda eBPF, instala el cronjob de despliegue de contenedores de prueba, y arranca el ciclo principal de telemetría y decisión cada 30 segundos.

Dejarlo corriendo en primer plano en esta terminal (no se envía a segundo plano salvo que se necesite liberar la terminal para seguir trabajando).

### 4. Ver el dashboard

Abrir en el navegador:

```
http://localhost:3001
```

Usuario `admin`, contraseña `admin`.

## Cómo detener todo

Detener en el orden inverso al arranque, para no dejar procesos huérfanos.

### 1. Detener el daemon

En la terminal donde está corriendo, presionar `Ctrl+C`. El propio daemon tiene un manejador de señales que elimina el cronjob del sistema antes de salir.

### 2. Bajar Valkey y Grafana

```bash
cd ~/202101149_LAB_SO1_1S2026/Proyecto2
sudo docker compose down
```

### 3. Descargar el módulo de kernel (opcional)

Solo si se quiere dejar el sistema completamente limpio, por ejemplo antes de la defensa o para probar una carga desde cero.

```bash
sudo rmmod continfo
```

### 4. Limpiar contenedores de prueba sueltos

El cronjob despliega contenedores de prueba cada 2 minutos mientras el daemon corre. Si quedaron contenedores detenidos de sesiones anteriores, se pueden limpiar todos de una vez.

```bash
sudo docker rm $(sudo docker ps -aq --filter "status=exited")
```

## Problemas conocidos y su diagnóstico

### El módulo no carga: "Invalid module format"

Ubuntu actualiza el kernel en segundo plano (`unattended-upgrades`) sin reiniciar, así que la versión de kernel corriendo en memoria puede quedar desincronizada de la versión contra la que se compiló el módulo. La solución es recompilar contra el kernel activo:

```bash
uname -r
cd ~/202101149_LAB_SO1_1S2026/Proyecto2/kernel-module/src
make clean
make
sudo insmod continfo.ko
```

Para evitar que esto interrumpa una sesión de trabajo larga, se puede desactivar temporalmente la actualización automática:

```bash
sudo systemctl disable --now unattended-upgrades.service
```

(reactivar después de la entrega con `enable --now`).

### Valkey o Grafana no levantan: "address already in use"

Puede haber un servicio nativo de Redis o Grafana instalado directamente en el sistema (de una práctica anterior) ocupando el puerto 6379 o 3000/3001 antes que el contenedor. Verificar con:

```bash
sudo lsof -i :6379
sudo lsof -i :3000
```

Si aparece un proceso nativo (por ejemplo `redis-server` o `grafana-server`), detenerlo y desactivarlo:

```bash
sudo systemctl stop redis-server
sudo systemctl disable redis-server
sudo systemctl stop grafana-server
sudo systemctl disable grafana-server
```

### El daemon dice que no encuentra el archivo de /proc

Confirmar que el módulo está realmente cargado (`lsmod | grep continfo`) y que el archivo existe (`ls -la /proc/continfo_pr2_so1_202101149`). Si no existe, revisar el punto de "Invalid module format" arriba.

### Grafana aparece como candidato a eliminación en vez de protegido

Esto puede pasar si el módulo de kernel, en una lectura puntual, no captura todos los procesos internos de Grafana (el contenedor corre `grafana` y `redis-datasource` como dos procesos separados bajo el mismo ID). El parser agrupa los nombres de proceso de un mismo contenedor para que el filtro de protegidos los reconozca sin importar el orden en que aparezcan. Es una condición transitoria y de bajo riesgo: mientras el contenedor sí sea detectado en la mayoría de iteraciones, nunca es eliminado.

### Los paneles de Grafana muestran "No data"

El plugin `redis-datasource`, en la versión usada, no siempre expone los comandos (`LRANGE`, `ZREVRANGE`, etc.) en el selector estructurado de "Command". La solución es usar el modo **Command-line** en el campo Type de la consulta, y escribir el comando completo a mano, por ejemplo:

```
LRANGE telemetry_history 0 -1
ZREVRANGE top_ram 0 4 WITHSCORES
```

Si un panel muestra "Data outside time range", revisar que el selector de tiempo del dashboard (arriba a la derecha) no haya quedado en una fecha inválida (por ejemplo 1970), y ajustarlo a un rango normal como "Last 30 minutes".