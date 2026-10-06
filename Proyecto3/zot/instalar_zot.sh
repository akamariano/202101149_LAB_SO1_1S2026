#!/usr/bin/env bash
# Se ejecuta DENTRO de la VM (como root). Lo invoca scripts/01_zot_vm.sh.
# Uso: sudo bash instalar_zot.sh <dominio> <usuario> <password> <version_zot>
set -euo pipefail
DOMAIN="$1"; USER_ZOT="$2"; PASS_ZOT="$3"; VERSION="$4"
BASE=/opt/zot

echo "[vm] Paquetes: docker, certbot, htpasswd"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io certbot apache2-utils >/dev/null
systemctl enable --now docker

mkdir -p "$BASE"/{tls,data}

echo "[vm] Certificado Let's Encrypt para $DOMAIN"
# --standalone levanta un servidor temporal en :80 para el reto HTTP-01
[ -d "/etc/letsencrypt/live/$DOMAIN" ] || \
  certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

# Hook: en cada renovación copia el cert a /opt/zot/tls y reinicia Zot
cat > /etc/letsencrypt/renewal-hooks/deploy/zot.sh <<EOF
#!/bin/sh
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem $BASE/tls/fullchain.pem
cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem   $BASE/tls/privkey.pem
chmod 600 $BASE/tls/privkey.pem
docker restart zot >/dev/null 2>&1 || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/zot.sh
/etc/letsencrypt/renewal-hooks/deploy/zot.sh

echo "[vm] Usuario de Zot (bcrypt)"
htpasswd -bBc "$BASE/htpasswd" "$USER_ZOT" "$PASS_ZOT"

echo "[vm] config.json"
# - TLS: Zot sirve HTTPS directamente (puerto 5000 dentro del contenedor -> 443 en la VM)
# - accessControl: lectura anónima (GKE descarga sin imagePullSecrets);
#   escribir (push) requiere usuario/contraseña
cat > "$BASE/config.json" <<EOF
{
  "distSpecVersion": "1.1.1",
  "storage": { "rootDirectory": "/var/lib/registry", "gc": true },
  "http": {
    "address": "0.0.0.0",
    "port": "5000",
    "realm": "zot",
    "tls": { "cert": "/etc/zot/tls/fullchain.pem", "key": "/etc/zot/tls/privkey.pem" },
    "auth": { "htpasswd": { "path": "/etc/zot/htpasswd" } },
    "accessControl": {
      "repositories": {
        "**": { "anonymousPolicy": ["read"], "defaultPolicy": ["read", "create", "update", "delete"] }
      }
    }
  },
  "log": { "level": "info" },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
EOF

echo "[vm] Contenedor zot $VERSION"
docker rm -f zot >/dev/null 2>&1 || true
docker run -d --name zot --restart=always -p 443:5000 \
  -v "$BASE/config.json:/etc/zot/config.json:ro" \
  -v "$BASE/htpasswd:/etc/zot/htpasswd:ro" \
  -v "$BASE/tls:/etc/zot/tls:ro" \
  -v "$BASE/data:/var/lib/registry" \
  "ghcr.io/project-zot/zot-linux-amd64:$VERSION"

sleep 3
docker ps --filter name=zot --format '[vm] {{.Names}} -> {{.Status}}'
