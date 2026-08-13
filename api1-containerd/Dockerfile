# Etapa 1: compilación
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o api1 main.go

# Etapa 2: imagen final, mínima
FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/api1 .
EXPOSE 8081
CMD ["./api1"]