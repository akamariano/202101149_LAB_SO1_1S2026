#!/usr/bin/env bash
# Genera (una sola vez) la contraseña del admin de Grafana y la carga como Secret.
# La contraseña queda en .secrets/grafana.env, fuera de git.
set -euo pipefail
source "$(dirname "$0")/config.env"
mkdir -p "$SECRETS_DIR"

if [ ! -f "$SECRETS_DIR/grafana.env" ]; then
  cat > "$SECRETS_DIR/grafana.env" <<EOT
GRAFANA_USER=admin
GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=')
EOT
  chmod 600 "$SECRETS_DIR/grafana.env"
fi
source "$SECRETS_DIR/grafana.env"

# dry-run + apply: crea o actualiza el Secret sin fallar si ya existe
kubectl -n mumnk8s create secret generic grafana-admin \
  --from-literal=admin-user="$GRAFANA_USER" \
  --from-literal=admin-password="$GRAFANA_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
