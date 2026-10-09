# Una sola Dockerfile para todos los binarios de go-services.
# Uso: docker buildx build --platform linux/amd64 --build-arg SERVICE=api-rest .
#
# Etapa 1: compila en la arquitectura del host ($BUILDPLATFORM, arm64 en la Mac) y genera
# un binario para la arquitectura destino ($TARGETARCH, amd64 en GKE). Go hace cross-compile
# nativo, así que no hay emulación y el build es rápido.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS TARGETARCH SERVICE
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${SERVICE}

# Etapa 2: imagen final mínima. Alpine (y no distroless) para poder usar `kubectl exec`
# con shell al depurar y en la prueba de Falco.
FROM alpine:3
RUN adduser -D -u 10001 app
COPY --from=build /out/app /usr/local/bin/app
USER app
ENTRYPOINT ["/usr/local/bin/app"]
