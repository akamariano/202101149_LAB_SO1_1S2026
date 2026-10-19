# Generador de carga: cada usuario simulado envía reportes militares aleatorios
# a la ruta pública del Gateway.
#
# Los países, rangos y rutas no están escritos aquí: vienen del OCI Artifact
# mumnk8s/locust-config publicado en Zot. Antes de la prueba hay que bajarlo:
#   ./scripts/50_oci_artifact.sh pull
# Uso: locust -f locust/locustfile.py --host http://<IP_DEL_GATEWAY>
#      FLUJO=dapr locust -f locust/locustfile.py --host http://<IP_DEL_GATEWAY>
#      ESPERA=2.5,4 locust ...   # sobrescribe wait_time_s del artifact (muchos usuarios, pocas req/s)
import json
import os
import random
from datetime import datetime, timezone
from pathlib import Path

from locust import HttpUser, between, task

RUTA_CONFIG = Path(
    os.environ.get("LOCUST_CONFIG", Path(__file__).parent / ".artifact" / "war-config.json")
)
if not RUTA_CONFIG.exists():
    raise SystemExit(
        f"No existe {RUTA_CONFIG}. Descarga el OCI Artifact: ./scripts/50_oci_artifact.sh pull"
    )
CONFIG = json.loads(RUTA_CONFIG.read_text())

FLUJO = os.environ.get("FLUJO", "grpc")  # grpc (flujo principal) o dapr
RUTA = CONFIG["routes"][FLUJO]
PAISES = CONFIG["countries"]
AVIONES = CONFIG["warplanes_in_air"]
BARCOS = CONFIG["warships_in_water"]
ESPERA = CONFIG["wait_time_s"]
if os.environ.get("ESPERA"):
    _min, _max = (float(x) for x in os.environ["ESPERA"].split(","))
    ESPERA = {"min": _min, "max": _max}


class SoldadoReportero(HttpUser):
    # Pausa entre peticiones de un mismo usuario
    wait_time = between(ESPERA["min"], ESPERA["max"])

    @task
    def enviar_reporte(self):
        reporte = {
            "country": random.choice(PAISES),
            "warplanes_in_air": random.randint(AVIONES["min"], AVIONES["max"]),
            "warships_in_water": random.randint(BARCOS["min"], BARCOS["max"]),
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        self.client.post(RUTA, json=reporte, name=RUTA)
