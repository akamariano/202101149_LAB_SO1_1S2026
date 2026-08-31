##Compilacion
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o api2 main.go
##Imagen Final min
FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/api2 .
EXPOSE 8082
CMD ["./api2"]