//! API REST en Rust: punto de entrada del sistema detrás del Gateway API.
//! Recibe los reportes de Locust en /grpc-202101149, los valida y los reenvía por
//! HTTP al Deployment 1 de Go (go-api), que continúa el flujo por gRPC.

use std::{env, sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};

const PAISES: [&str; 5] = ["USA", "RUS", "CHN", "ESP", "GTM"];

#[derive(Debug, Deserialize, Serialize)]
struct WarReport {
    country: String,
    warplanes_in_air: i32,
    warships_in_water: i32,
    timestamp: String,
}

impl WarReport {
    fn validar(&mut self) -> Result<(), String> {
        self.country = self.country.trim().to_uppercase();
        if !PAISES.contains(&self.country.as_str()) {
            return Err(format!("país no soportado: {}", self.country));
        }
        if !(0..=50).contains(&self.warplanes_in_air) {
            return Err("warplanes_in_air fuera de rango (0-50)".into());
        }
        if !(0..=30).contains(&self.warships_in_water) {
            return Err("warships_in_water fuera de rango (0-30)".into());
        }
        Ok(())
    }
}

/// Estado compartido entre todas las peticiones. reqwest::Client mantiene un pool de
/// conexiones keep-alive, por eso se crea una sola vez y se comparte (Arc).
struct AppState {
    http: reqwest::Client,
    go_api_url: String,
}

async fn recibir_reporte(
    State(state): State<Arc<AppState>>,
    Json(mut reporte): Json<WarReport>,
) -> impl IntoResponse {
    if let Err(e) = reporte.validar() {
        return (StatusCode::BAD_REQUEST, e);
    }
    match state.http.post(&state.go_api_url).json(&reporte).send().await {
        Ok(resp) if resp.status().is_success() => (StatusCode::OK, "reporte enviado".to_string()),
        Ok(resp) => {
            let codigo = resp.status();
            let cuerpo = resp.text().await.unwrap_or_default();
            tracing::warn!("go-api respondió {codigo}: {cuerpo}");
            (StatusCode::BAD_GATEWAY, format!("go-api respondió {codigo}"))
        }
        Err(e) => {
            tracing::error!("no se pudo contactar go-api: {e}");
            (StatusCode::BAD_GATEWAY, "go-api no disponible".to_string())
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_target(false).init();

    let carnet = env::var("CARNET").unwrap_or_else(|_| "202101149".into());
    let go_api_url = env::var("GO_API_URL").unwrap_or_else(|_| "http://go-api:8080/reports".into());
    let addr = env::var("HTTP_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());

    let state = Arc::new(AppState {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .pool_max_idle_per_host(100)
            .build()
            .expect("cliente HTTP"),
        go_api_url: go_api_url.clone(),
    });

    // El Gateway reenvía la ruta tal cual, así que la API escucha en /grpc-<carnet>.
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route(&format!("/grpc-{carnet}"), post(recibir_reporte))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    tracing::info!("rust-api en {addr}: POST /grpc-{carnet} -> {go_api_url}");
    axum::serve(listener, app).await.expect("servidor");
}
