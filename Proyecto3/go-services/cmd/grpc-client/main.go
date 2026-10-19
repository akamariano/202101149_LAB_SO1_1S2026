// grpc-client: contenedor 2 del Deployment 1 (go-api). Patrón "ambassador".
// Expone WarReportService solo en localhost para el contenedor api-rest y reenvía cada
// llamada al gRPC Server (Deployment 2) dentro del clúster.
//
// Por qué un ambassador: concentra en un solo lugar la conexión remota (resolución DNS,
// balanceo entre réplicas, timeouts). El contenedor api-rest no sabe dónde está el servidor.
//
// Flujo Dapr: si la llamada trae la metadata x-flujo=dapr, en lugar de llamar por gRPC al
// Deployment 2 publica el reporte con el SDK de Dapr en el tópico war_reports_dapr. El
// sidecar daprd (inyectado en el pod) lo entrega a RabbitMQ; el ambassador no sabe qué
// broker hay detrás, eso lo define el Component de Dapr.
package main

import (
	"context"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	dapr "github.com/dapr/go-sdk/client"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

type ambassador struct {
	pb.UnimplementedWarReportServiceServer
	upstream pb.WarReportServiceClient
	dapr     daprPublisher
	// Contadores para el resumen periódico del log
	okGRPC, okDapr, fallidos atomic.Int64
}

func (a *ambassador) SendReport(ctx context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		if f := md.Get(report.FlujoHeader); len(f) > 0 && f[0] == report.FlujoDapr {
			return a.contar(&a.okDapr)(a.dapr.publish(ctx, req))
		}
	}
	return a.contar(&a.okGRPC)(a.upstream.SendReport(ctx, req))
}

// contar suma la llamada al contador del flujo si salió bien, o a fallidos si no.
func (a *ambassador) contar(ok *atomic.Int64) func(*pb.WarReportResponse, error) (*pb.WarReportResponse, error) {
	return func(resp *pb.WarReportResponse, err error) (*pb.WarReportResponse, error) {
		if err != nil {
			a.fallidos.Add(1)
		} else {
			ok.Add(1)
		}
		return resp, err
	}
}

// daprPublisher crea el cliente de Dapr en la primera publicación y no al arrancar:
// el sidecar daprd puede tardar unos segundos más que este contenedor en estar listo.
type daprPublisher struct {
	mu     sync.Mutex
	client dapr.Client
}

func (d *daprPublisher) get() (dapr.Client, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.client == nil {
		c, err := dapr.NewClient() // gRPC a localhost:$DAPR_GRPC_PORT (el sidecar)
		if err != nil {
			return nil, err
		}
		d.client = c
	}
	return d.client, nil
}

func (d *daprPublisher) publish(ctx context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	c, err := d.get()
	if err != nil {
		return nil, status.Errorf(codes.Unavailable, "sidecar de Dapr no disponible: %v", err)
	}
	// El SDK serializa el struct a JSON y Dapr lo envuelve en un CloudEvent.
	// Con publisherConfirm en el Component, el sidecar responde solo cuando RabbitMQ confirmó.
	if err := c.PublishEvent(ctx, report.DaprPubsub, report.DaprTopic, report.FromProto(req)); err != nil {
		return nil, status.Errorf(codes.Unavailable, "Dapr no pudo publicar: %v", err)
	}
	return &pb.WarReportResponse{Status: "publicado con Dapr"}, nil
}

func main() {
	listen := report.Env("GRPC_LISTEN", "localhost:50050")
	// "dns:///" + Service headless => el cliente recibe la IP de CADA pod del servidor y
	// round_robin reparte las llamadas entre ellas. Con un Service normal (ClusterIP),
	// la conexión HTTP/2 persistente quedaría pegada a una sola réplica.
	upstreamAddr := report.Env("GRPC_SERVER_ADDR", "dns:///go-writer-grpc:50051")

	conn, err := grpc.NewClient(upstreamAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`),
	)
	if err != nil {
		log.Fatalf("no se pudo crear la conexión al servidor: %v", err)
	}
	defer conn.Close()

	lis, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("no se pudo escuchar en %s: %v", listen, err)
	}
	s := grpc.NewServer()
	amb := &ambassador{upstream: pb.NewWarReportServiceClient(conn)}
	pb.RegisterWarReportServiceServer(s, amb)

	// Resumen periódico: cuántos reportes salieron por gRPC hacia go-writer y cuántos por Dapr
	pod, _ := os.Hostname()
	go func() {
		var pg, pd int64
		for range time.Tick(10 * time.Second) {
			g, d := amb.okGRPC.Load(), amb.okDapr.Load()
			if g != pg || d != pd {
				log.Printf("[%s] -> go-writer gRPC=%d (+%d) | Dapr pub/sub=%d (+%d) | fallidos=%d",
					pod, g, g-pg, d, d-pd, amb.fallidos.Load())
				pg, pd = g, d
			}
		}
	}()

	log.Printf("grpc-client (ambassador) en %s -> %s (o Dapr %s/%s)", listen, upstreamAddr, report.DaprPubsub, report.DaprTopic)
	log.Fatal(s.Serve(lis))
}
