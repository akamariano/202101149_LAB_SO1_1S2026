// api-rest: contenedor 1 del Deployment 1 (go-api).
// Recibe el JSON que reenvía la API de Rust, lo valida, lo convierte a protobuf y
// lo envía por gRPC al contenedor grpc-client del MISMO pod (localhost).
//
// POST /reports       -> flujo principal: grpc-client llama por gRPC al Deployment 2.
// POST /reports-dapr  -> flujo Dapr: la misma llamada lleva la metadata x-flujo=dapr y
//
//	grpc-client publica el reporte con Dapr pub/sub.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"

	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

func main() {
	addr := report.Env("HTTP_ADDR", ":8080")
	clientAddr := report.Env("GRPC_CLIENT_ADDR", "localhost:50050")

	// Una sola conexión gRPC (HTTP/2) compartida por todas las peticiones:
	// es segura para uso concurrente y multiplexa las llamadas.
	conn, err := grpc.NewClient(clientAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("no se pudo crear el cliente gRPC: %v", err)
	}
	defer conn.Close()
	client := pb.NewWarReportServiceClient(conn)

	var total, fallidos atomic.Int64

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })

	// net/http atiende cada petición en su propia goroutine: aquí está la concurrencia.
	reenviar := func(flujo string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			var rep report.WarReport
			if err := json.NewDecoder(r.Body).Decode(&rep); err != nil {
				http.Error(w, "JSON inválido: "+err.Error(), http.StatusBadRequest)
				return
			}
			req, err := rep.ToProto()
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}

			ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
			defer cancel()
			if flujo != "" {
				ctx = metadata.AppendToOutgoingContext(ctx, report.FlujoHeader, flujo)
			}
			resp, err := client.SendReport(ctx, req)
			if err != nil {
				fallidos.Add(1)
				http.Error(w, "error gRPC: "+err.Error(), http.StatusBadGateway)
				return
			}
			if n := total.Add(1); n%1000 == 0 {
				log.Printf("reportes reenviados: %d (fallidos: %d)", n, fallidos.Load())
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"status": resp.GetStatus()})
		}
	}
	mux.HandleFunc("POST /reports", reenviar(""))
	mux.HandleFunc("POST /reports-dapr", reenviar(report.FlujoDapr))

	log.Printf("api-rest escuchando en %s, cliente gRPC -> %s", addr, clientAddr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
