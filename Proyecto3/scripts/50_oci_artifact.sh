#!/usr/bin/env bash
# OCI Artifact: la configuración de Locust (países, rangos y rutas) se publica en Zot
# como un artifact OCI (no es una imagen) y Locust la descarga con `oras pull` antes de
# cada prueba.
# Uso: ./scripts/50_oci_artifact.sh push   # sube locust/war-config.json a Zot
#      ./scripts/50_oci_artifact.sh pull   # la baja a locust/.artifact/war-config.json
#      ./scripts/50_oci_artifact.sh ver    # muestra el manifiesto guardado en Zot
#      TAG=v2 ./scripts/50_oci_artifact.sh push
set -euo pipefail
source "$(dirname "$0")/config.env"
source "$SECRETS_DIR/zot.env"

TAG="${TAG:-v1}"
REF="$ZOT_DOMAIN/mumnk8s/locust-config:$TAG"
ARTIFACT_TYPE="application/vnd.mumnk8s.locust.config.v1+json"
DEST="$P3_ROOT/locust/.artifact"

echo "$ZOT_PASS" | oras login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null

case "${1:-}" in
  push)
    # oras guarda el nombre del archivo en la anotación org.opencontainers.image.title,
    # por eso se ejecuta desde locust/ (así el pull lo recrea como war-config.json).
    cd "$P3_ROOT/locust"
    oras push "$REF" \
      --artifact-type "$ARTIFACT_TYPE" \
      --annotation "org.opencontainers.image.description=Configuración de Locust (carnet $CARNET)" \
      war-config.json:application/json
    ;;
  pull)
    rm -rf "$DEST" && mkdir -p "$DEST"
    oras pull "$REF" -o "$DEST"
    echo "Descargado: $DEST/war-config.json"
    ;;
  ver)
    oras manifest fetch --pretty "$REF"
    echo
    echo "Repositorios en Zot:"
    oras repo ls "$ZOT_DOMAIN/mumnk8s"
    ;;
  *)
    echo "Uso: $0 push|pull|ver"; exit 1 ;;
esac
