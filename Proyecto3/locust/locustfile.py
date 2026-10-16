# Generador de carga: cada usuario simulado envía reportes militares aleatorios
# a la ruta pública del Gateway.
# Uso: locust -f locust/locustfile.py --host http://<IP_DEL_GATEWAY>
import random
from datetime import datetime, timezone

from locust import HttpUser, between, task

CARNET = "202101149"
PAISES = ["USA", "RUS", "CHN", "ESP", "GTM"]


class SoldadoReportero(HttpUser):
    # Pausa entre peticiones de un mismo usuario
    wait_time = between(0.1, 0.5)

    @task
    def enviar_reporte(self):
        reporte = {
            "country": random.choice(PAISES),
            "warplanes_in_air": random.randint(0, 50),
            "warships_in_water": random.randint(0, 30),
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        self.client.post(f"/grpc-{CARNET}", json=reporte, name=f"/grpc-{CARNET}")
