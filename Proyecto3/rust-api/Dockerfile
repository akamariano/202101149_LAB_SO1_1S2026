# API REST en Rust, construida para linux/amd64 (nodos N1 de GKE).
#
# Etapa 1: cargo-zigbuild corre nativo en el host ($BUILDPLATFORM) y usa zig como linker
# para generar un binario x86_64 estático (musl). Así evitamos compilar Rust bajo emulación
# QEMU, que sería entre 10 y 20 veces más lento.
FROM --platform=$BUILDPLATFORM ghcr.io/rust-cross/cargo-zigbuild:latest AS build
ARG RUST_TARGET=x86_64-unknown-linux-musl
WORKDIR /src
RUN rustup target add ${RUST_TARGET}

# Caché de dependencias: si solo cambia src/, esta capa no se recompila.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
    && cargo zigbuild --release --target ${RUST_TARGET} \
    && rm -rf src

COPY src ./src
RUN touch src/main.rs && cargo zigbuild --release --target ${RUST_TARGET} \
    && cp target/${RUST_TARGET}/release/rust-api /rust-api

# Etapa 2: imagen final mínima con el binario estático.
FROM alpine:3
RUN adduser -D -u 10001 app
COPY --from=build /rust-api /usr/local/bin/rust-api
USER app
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/rust-api"]
