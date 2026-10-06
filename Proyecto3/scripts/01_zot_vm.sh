#!/usr/bin/env bash
# Bloque 1a: crea la VM de Zot (N1) fuera del clúster y la deja sirviendo HTTPS.
#   1. IP estática  -> el dominio (y el certificado) no cambian al apagar/encender la VM
#   2. Firewall     -> abre 80 (validación Let's Encrypt) y 443 (registry)
#   3. VM Ubuntu    -> n1-standard-1, disco estándar
#   4. Copia y ejecuta zot/instalar_zot.sh dentro de la VM
set -euo pipefail
source "$(dirname "$0")/config.env"
mkdir -p "$SECRETS_DIR"

echo "→ IP estática"
gcloud compute addresses describe "$ZOT_IP_NAME" --region "$REGION" &>/dev/null \
  || gcloud compute addresses create "$ZOT_IP_NAME" --region "$REGION"
ZOT_IP=$(gcloud compute addresses describe "$ZOT_IP_NAME" --region "$REGION" --format='value(address)')
# sslip.io: DNS público que resuelve "34-1-2-3.sslip.io" -> 34.1.2.3 (dominio gratis para el certificado)
ZOT_DOMAIN="${ZOT_IP//./-}.sslip.io"
echo "  IP: $ZOT_IP   Dominio: $ZOT_DOMAIN"

echo "→ Credenciales de Zot (solo se generan la primera vez)"
if [ ! -f "$SECRETS_DIR/zot.env" ]; then
  ZOT_PASS=$(openssl rand -base64 18 | tr -d '/+=')
  cat > "$SECRETS_DIR/zot.env" <<EOF
ZOT_DOMAIN=$ZOT_DOMAIN
ZOT_USER=$ZOT_USER
ZOT_PASS=$ZOT_PASS
EOF
  chmod 600 "$SECRETS_DIR/zot.env"
fi
source "$SECRETS_DIR/zot.env"

echo "→ Regla de firewall (tag de red: zot)"
gcloud compute firewall-rules describe allow-zot &>/dev/null \
  || gcloud compute firewall-rules create allow-zot \
       --network default --direction INGRESS --action ALLOW \
       --rules tcp:80,tcp:443 --source-ranges 0.0.0.0/0 --target-tags zot

echo "→ VM $ZOT_VM"
ZONE="$(zot_zone)"
if [ -z "$ZONE" ]; then
  for z in $ZOT_ZONES; do
    echo "  Probando zona $z..."
    if gcloud compute instances create "$ZOT_VM" \
         --zone "$z" --machine-type "$ZOT_MACHINE" \
         --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
         --boot-disk-size 30GB --boot-disk-type pd-standard \
         --address "$ZOT_IP" --tags zot; then
      ZONE="$z"; break
    fi
  done
  [ -n "$ZONE" ] || { echo "Ninguna zona tuvo capacidad para $ZOT_MACHINE; reintenta más tarde."; exit 1; }
fi
echo "  VM en zona: $ZONE"

echo "→ Esperando SSH..."
until gcloud compute ssh "$ZOT_VM" --zone "$ZONE" --command true --quiet &>/dev/null; do sleep 5; done

echo "→ Instalando Zot dentro de la VM"
gcloud compute scp "$P3_ROOT/zot/instalar_zot.sh" "$ZOT_VM":/tmp/instalar_zot.sh --zone "$ZONE"
gcloud compute ssh "$ZOT_VM" --zone "$ZONE" --command \
  "sudo bash /tmp/instalar_zot.sh '$ZOT_DOMAIN' '$ZOT_USER' '$ZOT_PASS' '$ZOT_VERSION'"

echo
echo "→ Prueba desde tu Mac (debe responder 200 y JSON de catálogo):"
curl -s -o /dev/null -w "  HTTPS /v2/ -> %{http_code}\n" "https://$ZOT_DOMAIN/v2/"
echo "  UI web: https://$ZOT_DOMAIN  (usuario: $ZOT_USER, contraseña en .secrets/zot.env)"
