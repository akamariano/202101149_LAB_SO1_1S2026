# Proyecto 2 - Sistemas Operativos 1

Sistema de monitorización y gestión autónoma de contenedores mediante un módulo de kernel en C, una sonda eBPF, y un daemon en Go, con visualización en Grafana.

Carné: 202101149

## Componentes

- Módulo de kernel (kernel-module/): expone métricas de RAM y procesos en /proc/continfo_pr2_so1_202101149
- Cronjob (cronjob/): despliega contenedores de prueba cada 2 minutos
- Daemon en Go (daemon-go/): orquesta el sistema, decide qué contenedores eliminar, guarda en Valkey
- Sonda eBPF (ebpf/): confirma a nivel de kernel la terminación de contenedores
- Dashboard (grafana/): visualización de métricas
## Compilación y Recarga del Módulo de Kernel

Estos pasos aplican para cualquier cambio en `continfo.c`. Ejecutar en orden dentro de `kernel-module/src`:

1. **Compilar desde cero** (limpiando artefactos anteriores para evitar mezclar binarios viejos con nuevos):
   ```bash
   make clean
   make
   ```

2. **Descargar la versión previa del módulo** si estaba cargada (evita conflictos en `/proc`):
   ```bash
   sudo rmmod continfo
   ```

3. **Cargar el módulo recién compilado**:
   ```bash
   sudo insmod continfo.ko
   ```

4. **Verificar el contenido expuesto en `/proc`**:
   ```bash
   cat /proc/continfo_pr2_so1_202101149
   ```

5. **Revisar el log del kernel** filtrando los mensajes del módulo:
   ```bash
   sudo dmesg | grep continfo
   ```

### Notas Frecuentes
- Un error de *"no existe el archivo o el directorio"* al correr `make` significa que falta el Makefile en la carpeta actual, o que el nombre del archivo referenciado en `obj-m` no coincide con el nombre real del archivo fuente.
- Un error relacionado a un símbolo o tipo no declarado suele significar que falta un include; revisar contra la lista de headers usados en `continfo.c`.
- Si `rmmod` falla diciendo que el módulo no existe, es porque no había una versión previa cargada; ese error se puede ignorar antes del primer `insmod` de la sesión.

---

## Errores y Soluciones Frecuentes

### 1. Error `Invalid module format` / `section size must match`
- **Causa**: Ocurre cuando las cabeceras del kernel en `/usr/src/linux-headers-*` fueron modificadas o desconfiguradas por comandos manuales de `make`.
- **Solución Definitiva (Restaurar cabeceras originales de fábrica)**:
  ```bash
  sudo apt-get purge -y linux-headers-$(uname -r) linux-headers-$(uname -r | cut -d'-' -f1,2)
  sudo apt-get install -y linux-headers-$(uname -r)
  ```

### 2. Error `address already in use` (Puertos 6379 o 3000)
- **Causa**: Ocurre al reiniciar el Daemon si los contenedores de **Valkey** (`6379`) o **Grafana** (`3000`) ya se encontraban encendidos.
- **Solución**: El Daemon lo maneja automáticamente como una advertencia y reutiliza la infraestructura activa. Si deseas reiniciarlos completamente:
  ```bash
  sudo docker rm -f valkey_db grafana_dashboard 2>/dev/null || true
  ```