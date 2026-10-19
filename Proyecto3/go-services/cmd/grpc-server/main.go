// grpc-server: contenedor 1 del Deployment 2 (go-writer).
// Recibe los reportes por gRPC desde el Deployment 1 y los reenvía al contenedor
// rabbit-writer del mismo pod (localhost), que los publica en RabbitMQ.
//
// Flujo Dapr: si DAPR_APP_ADDR está definido, además se suscribe con el SDK de Dapr al
// tópico war_reports_dapr. El sidecar daprd lee la cola en RabbitMQ y entrega cada evento
// a este proceso por gRPC; el reporte sigue el mismo camino (rabbit-writer -> war_reports
// -> consumer -> Valkey), así que Grafana muestra los datos de los dos flujos.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"sync/atomic"
	"time"

	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/grpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/reflection"

	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

type server struct {
	pb.UnimplementedWarReportServiceServer
	pod       string
	total     atomic.Int64
	totalDapr atomic.Int64
	writer    pb.WarReportServiceClient
}

// gRPC ejecuta cada llamada en su propia goroutine; el contador es atómico por eso.
func (s *server) SendReport(ctx context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	resp, err := s.writer.SendReport(ctx, req)
	if err != nil {
		return nil, err // el código gRPC (p. ej. Unavailable) se propaga hacia atrás
	}
	n := s.total.Add(1)
	if n <= 5 {
		log.Printf("[%s] #%d %s aviones=%d barcos=%d ts=%s", s.pod, n,
			report.CountryCode(req.GetCountry()), req.GetWarplanesInAir(), req.GetWarshipsInWater(), req.GetTimestamp())
	}
	return &pb.WarReportResponse{Status: resp.GetStatus() + " por " + s.pod}, nil
}

// onDaprEvent recibe cada evento del tópico. Devolver retry=true hace que Dapr no confirme
// el mensaje en RabbitMQ y lo vuelva a entregar; un reporte inválido se descarta (DROP).
func (s *server) onDaprEvent(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
	var rep report.WarReport
	if err := e.Struct(&rep); err != nil {
		return false, fmt.Errorf("evento %s con JSON inválido: %w", e.ID, err)
	}
	req, err := rep.ToProto()
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if _, err := s.writer.SendReport(ctx, req); err != nil {
		return true, err
	}
	if n := s.totalDapr.Add(1); n <= 5 {
		log.Printf("[%s] dapr #%d %s aviones=%d barcos=%d", s.pod, n, rep.Country, rep.WarplanesInAir, rep.WarshipsInWater)
	}
	return false, nil
}

// suscribirDapr levanta el servidor de callbacks de Dapr (otro puerto, app-port del sidecar)
func suscribirDapr(addr string, srv *server) {
	svc, err := daprd.NewService(addr)
	if err != nil {
		log.Fatalf("no se pudo escuchar en %s para Dapr: %v", addr, err)
	}
	sub := &common.Subscription{PubsubName: report.DaprPubsub, Topic: report.DaprTopic}
	if err := svc.AddTopicEventHandler(sub, srv.onDaprEvent); err != nil {
		log.Fatalf("no se pudo registrar la suscripción: %v", err)
	}
	log.Printf("suscrito con Dapr a %s/%s (callbacks en %s)", report.DaprPubsub, report.DaprTopic, addr)
	log.Fatal(svc.Start())
}

func main() {
	listen := report.Env("GRPC_LISTEN", ":50051")
	writerAddr := report.Env("WRITER_ADDR", "localhost:50052")
	pod, _ := os.Hostname()

	// Conexión al rabbit-writer del mismo pod. NewClient no conecta todavía: lo hace en la
	// primera llamada, así que no importa cuál de los dos contenedores arranque primero.
	conn, err := grpc.NewClient(writerAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("no se pudo crear la conexión al writer: %v", err)
	}
	defer conn.Close()

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
	srv := &server{pod: pod, writer: pb.NewWarReportServiceClient(conn)}
	pb.RegisterWarReportServiceServer(s, srv)

	// Resumen periódico: reportes atendidos por ESTA réplica (útil para comparar 1 vs 2).
	go func() {
		var prev, prevDapr int64
		for range time.Tick(10 * time.Second) {
			n, d := srv.total.Load(), srv.totalDapr.Load()
			if n != prev || d != prevDapr {
				log.Printf("[%s] grpc=%d (+%d) dapr=%d (+%d) en 10s", pod, n, n-prev, d, d-prevDapr)
				prev, prevDapr = n, d
			}
		}
	}()
	if addr := os.Getenv("DAPR_APP_ADDR"); addr != "" {
		go suscribirDapr(addr, srv)
	}
	healthpb.RegisterHealthServer(s, health.NewServer()) // para las probes de Kubernetes
	reflection.Register(s)                               // permite probar con grpcurl sin el .proto

	log.Printf("grpc-server escuchando en %s -> writer %s", listen, writerAddr)
	log.Fatal(s.Serve(lis))
}
