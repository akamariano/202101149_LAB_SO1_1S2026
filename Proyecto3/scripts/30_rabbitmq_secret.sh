#!/usr/bin/env bash
# Genera (una sola vez) la contraseña de RabbitMQ y la carga como Secret en el clúster.
# La contraseña queda en .secrets/rabbitmq.env, fuera de git.
set -euo pipefail
source "$(dirname "$0")/config.env"
mkdir -p "$SECRETS_DIR"

if [ ! -f "$SECRETS_DIR/rabbitmq.env" ]; then
  cat > "$SECRETS_DIR/rabbitmq.env" <<EOT
RABBITMQ_USER=mumnk8s
RABBITMQ_PASS=$(openssl rand -base64 18 | tr -d '/+=')
EOT
  chmod 600 "$SECRETS_DIR/rabbitmq.env"
fi
source "$SECRETS_DIR/rabbitmq.env"

# dry-run + apply: crea o actualiza el Secret sin fallar si ya existe
kubectl -n mumnk8s create secret generic rabbitmq-cred \
  --from-literal=username="$RABBITMQ_USER" \
  --from-literal=password="$RABBITMQ_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
