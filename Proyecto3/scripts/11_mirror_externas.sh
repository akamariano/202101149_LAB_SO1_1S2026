#!/usr/bin/env bash
# Copia a Zot las imágenes de terceros (RabbitMQ, Valkey, Grafana, Falco, Dapr) para que el clúster
# descargue TODO desde el registry propio, como pide el enunciado.
#
# La copia se ejecuta DENTRO de la VM de Zot con skopeo (de registry a registry) y no desde
# la Mac. Zot corta cada petición a los 60 s: las capas grandes de Grafana (194 MB en un
# solo PUT) no alcanzaban a subir con el ancho de banda de subida de una conexión de casa
# y fallaban con "stream error: INTERNAL_ERROR" (en Zot: "i/o timeout"). Dentro de GCP la
# descarga es rápida y la subida a Zot ocurre en la misma máquina.
# --format oci: Zot rechaza manifiestos Docker v2 (HTTP 415), así que se convierten a OCI.
# Solo se copia linux/amd64, la arquitectura de los nodos N1.
#
# Uso: ./scripts/11_mirror_externas.sh            # todas
#      ./scripts/11_mirror_externas.sh grafana    # solo las que contengan "grafana"
set -euo pipefail
source "$(dirname "$0")/config.env"
source "$SECRETS_DIR/zot.env"

# origen -> nombre dentro de Zot
IMAGENES=(
  "docker.io/library/rabbitmq:4.1-management-alpine mumnk8s/rabbitmq:4.1-management-alpine"
  "docker.io/valkey/valkey:8.1-alpine mumnk8s/valkey:8.1-alpine"
  "docker.io/grafana/grafana:12.4.13 mumnk8s/grafana:12.4.13"
  "docker.io/falcosecurity/falco:0.45.0 mumnk8s/falco:0.45.0"
  "docker.io/falcosecurity/falcoctl:0.14.2 mumnk8s/falcoctl:0.14.2"
  "ghcr.io/dapr/daprd:1.18.7 mumnk8s/dapr/daprd:1.18.7"
  "ghcr.io/dapr/injector:1.18.7 mumnk8s/dapr/injector:1.18.7"
  "ghcr.io/dapr/operator:1.18.7 mumnk8s/dapr/operator:1.18.7"
  "ghcr.io/dapr/placement:1.18.7 mumnk8s/dapr/placement:1.18.7"
  "ghcr.io/dapr/scheduler:1.18.7 mumnk8s/dapr/scheduler:1.18.7"
  "ghcr.io/dapr/sentry:1.18.7 mumnk8s/dapr/sentry:1.18.7"
)
# Artifacts OCI que no son imágenes: las reglas de Falco y su plugin de contenedores.
# falcoctl (initContainer de Falco) los descarga al arrancar. skopeo solo entiende
# imágenes, así que estos se copian con `oras cp` desde la Mac (pesan pocos MB).
ARTIFACTS=(
  "ghcr.io/falcosecurity/rules/falco-rules:5.2.0 mumnk8s/falco/falco-rules:5.2.0"
  "ghcr.io/falcosecurity/plugins/plugin/container:0.7.4 mumnk8s/falco/container:0.7.4"
)
FILTRO="${1:-}"

ZONA=$(zot_zone)
[ -n "$ZONA" ] || { echo "No existe la VM $ZOT_VM. Ejecuta 01_zot_vm.sh primero."; exit 1; }

# Arma el script que corre en la VM. Viaja por stdin, así la contraseña no aparece en la
# línea de comandos ni en la lista de procesos de la VM.
CMDS="set -e
command -v skopeo >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo >/dev/null; }
skopeo login '$ZOT_DOMAIN' -u '$ZOT_USER' --password-stdin >/dev/null <<<'$ZOT_PASS'"
for par in "${IMAGENES[@]}"; do
  read -r src dst <<<"$par"
  [[ -z "$FILTRO" || "$src" == *"$FILTRO"* ]] || continue
  CMDS+="
echo '→ $src  =>  $ZOT_DOMAIN/$dst'
skopeo copy -q --override-os linux --override-arch amd64 --format oci 'docker://$src' 'docker://$ZOT_DOMAIN/$dst'"
done

gcloud compute ssh "$ZOT_VM" --zone "$ZONA" --command "sudo bash -s" <<<"$CMDS"

echo "$ZOT_PASS" | oras login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null
for par in "${ARTIFACTS[@]}"; do
  read -r src dst <<<"$par"
  [[ -z "$FILTRO" || "$src" == *"$FILTRO"* ]] || continue
  echo "→ $src  =>  $ZOT_DOMAIN/$dst"
  oras cp --platform linux/amd64 "$src" "$ZOT_DOMAIN/$dst" 2>/dev/null || oras cp "$src" "$ZOT_DOMAIN/$dst"
done

echo
echo "Tags en Zot:"
for par in "${IMAGENES[@]}" "${ARTIFACTS[@]}"; do
  read -r _ dst <<<"$par"
  repo="${dst%%:*}"
  echo "  $repo: $(curl -s -u "$ZOT_USER:$ZOT_PASS" "https://$ZOT_DOMAIN/v2/$repo/tags/list")"
done
