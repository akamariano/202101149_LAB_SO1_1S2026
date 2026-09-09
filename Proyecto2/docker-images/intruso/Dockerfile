FROM alpine:latest

# Instalar utilidades requeridas si fuera necesario
RUN apk add --no-cache bash

COPY intruso.sh /intruso.sh
RUN chmod +x /intruso.sh

CMD ["/intruso.sh"]
