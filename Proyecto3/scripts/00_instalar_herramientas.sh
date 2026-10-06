#!/usr/bin/env bash
# Instala las herramientas locales (macOS Apple Silicon) para el Proyecto 3.
# Se puede re-ejecutar sin problema: lo que ya está instalado se salta.
set -euo pipefail

ok()   { printf "\033[32m✔ %s\033[0m\n" "$1"; }
info() { printf "\033[36m→ %s\033[0m\n" "$1"; }

command -v brew >/dev/null || { echo "Homebrew no está instalado: https://brew.sh"; exit 1; }

brew_formula() { brew list --formula "$1" &>/dev/null && ok "$1 ya instalado" || { info "Instalando $1"; brew install "$1"; }; }
brew_cask()    { brew list --cask "$1" &>/dev/null && ok "$1 ya instalado" || { info "Instalando $1"; brew install --cask "$1"; }; }

info "Actualizando Homebrew"
brew update

# --- GCP: gcloud + plugin de autenticación para kubectl con GKE ---
if ! command -v gcloud >/dev/null; then
  brew_cask gcloud-cli || brew_cask google-cloud-sdk
fi
# El cask agrega gcloud al PATH en shells nuevos; para este script lo cargamos a mano
GCLOUD_INC="$(brew --prefix)/share/google-cloud-sdk/path.zsh.inc"
[ -f "$GCLOUD_INC" ] && export PATH="$(brew --prefix)/share/google-cloud-sdk/bin:$PATH"
gcloud components install gke-gcloud-auth-plugin --quiet || true

# --- Kubernetes ---
brew_formula kubernetes-cli   # kubectl
brew_formula helm             # charts (RabbitMQ, Falco, y la base del Operator)
brew_formula operator-sdk     # Operator Helm-based para Valkey y Grafana

# --- Go + gRPC ---
brew_formula go
brew_formula protobuf               # protoc
brew_formula protoc-gen-go          # genera structs de los mensajes
brew_formula protoc-gen-go-grpc     # genera cliente/servidor gRPC
brew_formula grpcurl                # probar el servidor gRPC a mano (como curl)

# --- Rust (vía rustup) + cross-compile a linux/amd64 sin emulación ---
# El formula rustup es keg-only y ya no trae rustup-init: sus binarios (rustup, cargo,
# rustc como proxies) viven en $(brew --prefix rustup)/bin. `rustup default stable`
# descarga el toolchain si no existe.
brew_formula rustup
RUSTUP_BIN="$(brew --prefix rustup)/bin"
export PATH="$RUSTUP_BIN:$HOME/.cargo/bin:$PATH"
info "Instalando/activando toolchain estable de Rust"
rustup default stable
rustup target add x86_64-unknown-linux-musl   # binario estático para la imagen amd64
brew_formula zig                               # linker que usa cargo-zigbuild
command -v cargo-zigbuild >/dev/null && ok "cargo-zigbuild ya instalado" || cargo install --locked cargo-zigbuild

# --- Carga, registry y utilidades ---
brew_formula locust   # generador de tráfico
brew_formula oras     # subir/bajar el JSON como OCI Artifact desde Zot
brew_formula jq
brew_formula dapr/tap/dapr-cli   # para el bloque opcional de Dapr

# --- Docker Desktop (ya instalado; solo verificamos buildx) ---
if docker info &>/dev/null; then
  docker buildx version >/dev/null && ok "docker buildx disponible"
else
  echo "⚠ Docker Desktop no está corriendo: ábrelo antes de construir imágenes."
fi

# --- Asegurar PATH de rustup/cargo en zsh para futuras terminales ---
grep -q 'opt/rustup/bin' "$HOME/.zshrc" 2>/dev/null || echo "export PATH=\"$RUSTUP_BIN:\$PATH\"" >> "$HOME/.zshrc"
grep -q '.cargo/bin' "$HOME/.zshrc" 2>/dev/null || echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.zshrc"

echo
info "Versiones instaladas:"
for t in gcloud kubectl helm operator-sdk go protoc protoc-gen-go protoc-gen-go-grpc grpcurl cargo cargo-zigbuild zig locust oras dapr docker; do
  printf "  %-20s " "$t"
  command -v "$t" >/dev/null && echo "ok" || echo "FALTA"
done

cat <<'EOF'

Siguientes pasos (interactivos, hazlos tú en una terminal nueva):
  1. gcloud init                     # login + elegir/crear proyecto
  2. gcloud auth application-default login
  3. Verifica que el proyecto tenga facturación activa y crea una alerta de presupuesto.
EOF
