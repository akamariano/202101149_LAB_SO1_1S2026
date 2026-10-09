// grpc-server: contenedor 1 del Deployment 2 (go-writer).
// Recibe los reportes por gRPC desde el Deployment 1. En el bloque 4 reenviará cada
// reporte al contenedor rabbit-writer del mismo pod; por ahora solo los registra.
package main

import (
	"context"
	"log"
	"net"
	"os"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/reflection"

	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

type server struct {
	pb.UnimplementedWarReportServiceServer
	pod   string
	total atomic.Int64
}

// gRPC ejecuta cada llamada en su propia goroutine; el contador es atómico por eso.
func (s *server) SendReport(_ context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	n := s.total.Add(1)
	if n <= 5 {
		log.Printf("[%s] #%d %s aviones=%d barcos=%d ts=%s", s.pod, n,
			report.CountryCode(req.GetCountry()), req.GetWarplanesInAir(), req.GetWarshipsInWater(), req.GetTimestamp())
	}
	return &pb.WarReportResponse{Status: "recibido por " + s.pod}, nil
}

func main() {
	listen := report.Env("GRPC_LISTEN", ":50051")
	pod, _ := os.Hostname()

	lis, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("no se pudo escuchar en %s: %v", listen, err)
	}
	// MaxConnectionAge: cada 30s el servidor cierra (con GOAWAY ordenado) las conexiones.
	// El cliente se reconecta y vuelve a resolver el DNS del Service headless, así
	// descubre réplicas nuevas cuando el Deployment escala. Sin esto, el resolver DNS de
	// grpc-go no vuelve a consultar y todo el tráfico seguiría yendo a los pods viejos.
	s := grpc.NewServer(grpc.KeepaliveParams(keepalive.ServerParameters{
		MaxConnectionAge:      30 * time.Second,
		MaxConnectionAgeGrace: 5 * time.Second,
	}))
	srv := &server{pod: pod}
	pb.RegisterWarReportServiceServer(s, srv)

	// Resumen periódico: reportes atendidos por ESTA réplica (útil para comparar 1 vs 2).
	go func() {
		var prev int64
		for range time.Tick(10 * time.Second) {
			if n := srv.total.Load(); n != prev {
				log.Printf("[%s] total=%d (+%d en 10s)", pod, n, n-prev)
				prev = n
			}
		}
	}()
	healthpb.RegisterHealthServer(s, health.NewServer()) // para las probes de Kubernetes
	reflection.Register(s)                               // permite probar con grpcurl sin el .proto

	log.Printf("grpc-server escuchando en %s", listen)
	log.Fatal(s.Serve(lis))
}
