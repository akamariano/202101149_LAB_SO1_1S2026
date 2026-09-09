FROM grafana/grafana:11.2.0

USER root

# 1. Crear un directorio personalizado para plugins que no será afectado por volúmenes
RUN mkdir -p /var/lib/grafana-custom-plugins

# 2. Instalar el plugin de Redis directamente en ese nuevo directorio
RUN grafana-cli --pluginsDir /var/lib/grafana-custom-plugins plugins install redis-datasource

# 3. Asignar propiedad al usuario de Grafana (472)
RUN chown -R 472:472 /var/lib/grafana-custom-plugins /var/lib/grafana

# 4. Indicar a Grafana que lea los plugins desde la nueva ruta
ENV GF_PATHS_PLUGINS="/var/lib/grafana-custom-plugins"

USER 472

EXPOSE 3000