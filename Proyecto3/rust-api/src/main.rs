//! API REST en Rust: punto de entrada del sistema detrás del Gateway API.
//! Recibe los reportes de Locust en /grpc-202101149, los valida y los reenvía por
//! HTTP al Deployment 1 de Go (go-api), que continúa el flujo por gRPC.
//! La ruta opcional /dapr-202101149 hace lo mismo pero hacia /reports-dapr, donde go-api
//! continúa el flujo con Dapr pub/sub en lugar de gRPC.

use std::{
    env,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering::Relaxed},
    },
    time::Duration,
};

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

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
    go_api_dapr_url: String,
    /// Tope de reportes en vuelo hacia go-api (load shedding). Si go-api se pone lento, las
    /// peticiones se acumulan aquí con sus buffers y la memoria crece hasta el OOMKill; con
    /// el tope, las que sobran reciben 503 al instante y el pod sigue vivo.
    en_vuelo: Semaphore,
    max_en_vuelo: usize,
    /// Contadores para el resumen periódico del log (kubectl logs -l app=rust-api)
    ok_grpc: AtomicU64,
    ok_dapr: AtomicU64,
    rechazados: AtomicU64,
    errores: AtomicU64,
}

async fn recibir_grpc(
    State(state): State<Arc<AppState>>,
    Json(reporte): Json<WarReport>,
) -> impl IntoResponse {
    let r = reenviar(&state, &state.go_api_url, reporte).await;
    contar(&state, &state.ok_grpc, r.0);
    r
}

async fn recibir_dapr(
    State(state): State<Arc<AppState>>,
    Json(reporte): Json<WarReport>,
) -> impl IntoResponse {
    let r = reenviar(&state, &state.go_api_dapr_url, reporte).await;
    contar(&state, &state.ok_dapr, r.0);
    r
}

fn contar(state: &AppState, ok: &AtomicU64, codigo: StatusCode) {
    match codigo {
        StatusCode::OK => ok.fetch_add(1, Relaxed),
        StatusCode::SERVICE_UNAVAILABLE => state.rechazados.fetch_add(1, Relaxed),
        _ => state.errores.fetch_add(1, Relaxed),
    };
}

/// Cada 10 s imprime cuántos reportes reenvió este pod por cada flujo (solo si hubo cambios).
async fn resumen_periodico(state: Arc<AppState>) {
    let pod = env::var("HOSTNAME").unwrap_or_default();
    let mut prev = (0, 0, 0, 0);
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    loop {
        tick.tick().await;
        let act = (
            state.ok_grpc.load(Relaxed),
            state.ok_dapr.load(Relaxed),
            state.rechazados.load(Relaxed),
            state.errores.load(Relaxed),
        );
        if act != prev {
            tracing::info!(
                "[{pod}] -> go-api: grpc={} (+{}) dapr={} (+{}) | rechazados={} errores={} | en vuelo={}",
                act.0,
                act.0 - prev.0,
                act.1,
                act.1 - prev.1,
                act.2,
                act.3,
                state.max_en_vuelo - state.en_vuelo.available_permits(),
            );
            prev = act;
        }
    }
}

/// Valida el reporte y lo reenvía a go-api; la URL decide el flujo (gRPC o Dapr).
async fn reenviar(state: &AppState, url: &str, mut reporte: WarReport) -> (StatusCode, String) {
    if let Err(e) = reporte.validar() {
        return (StatusCode::BAD_REQUEST, e);
    }
    // El permiso se libera solo al salir de la función (drop)
    let Ok(_permiso) = state.en_vuelo.try_acquire() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "rust-api saturado, reintente".to_string(),
        );
    };
    match state.http.post(url).json(&reporte).send().await {
        Ok(resp) if resp.status().is_success() => (StatusCode::OK, "reporte enviado".to_string()),
        Ok(resp) => {
            let codigo = resp.status();
            let cuerpo = resp.text().await.unwrap_or_default();
            tracing::warn!("go-api respondió {codigo}: {cuerpo}");
            (
                StatusCode::BAD_GATEWAY,
                format!("go-api respondió {codigo}"),
            )
        }
        Err(e) => {
            tracing::error!("no se pudo contactar go-api: {e}");
            (StatusCode::BAD_GATEWAY, "go-api no disponible".to_string())
        }
    }
}

#[tokio::main]
async fn main() {
    // Sin colores ANSI: en `kubectl logs` se verían como códigos de escape
    tracing_subscriber::fmt()
        .with_target(false)
        .with_ansi(false)
        .init();

    let carnet = env::var("CARNET").unwrap_or_else(|_| "202101149".into());
    let go_api_url = env::var("GO_API_URL").unwrap_or_else(|_| "http://go-api:8080/reports".into());
    let go_api_dapr_url =
        env::var("GO_API_DAPR_URL").unwrap_or_else(|_| "http://go-api:8080/reports-dapr".into());
    let addr = env::var("HTTP_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let max_en_vuelo: usize = env::var("MAX_EN_VUELO")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(512);

    let state = Arc::new(AppState {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .pool_max_idle_per_host(100)
            .build()
            .expect("cliente HTTP"),
        go_api_url: go_api_url.clone(),
        go_api_dapr_url: go_api_dapr_url.clone(),
        en_vuelo: Semaphore::new(max_en_vuelo),
        max_en_vuelo,
        ok_grpc: AtomicU64::new(0),
        ok_dapr: AtomicU64::new(0),
        rechazados: AtomicU64::new(0),
        errores: AtomicU64::new(0),
    });

    // El Gateway reenvía la ruta tal cual, así que la API escucha en /grpc-<carnet> y /dapr-<carnet>.
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route(&format!("/grpc-{carnet}"), post(recibir_grpc))
        .route(&format!("/dapr-{carnet}"), post(recibir_dapr))
        .with_state(state.clone());
    tokio::spawn(resumen_periodico(state));

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    tracing::info!(
        "rust-api en {addr}: POST /grpc-{carnet} -> {go_api_url}, POST /dapr-{carnet} -> {go_api_dapr_url}, máx. {max_en_vuelo} en vuelo"
    );
    axum::serve(listener, app).await.expect("servidor");
}
