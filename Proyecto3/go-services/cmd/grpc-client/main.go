// grpc-client: contenedor 2 del Deployment 1 (go-api). Patrón "ambassador".
// Expone WarReportService solo en localhost para el contenedor api-rest y reenvía cada
// llamada al gRPC Server (Deployment 2) dentro del clúster.
//
// Por qué un ambassador: concentra en un solo lugar la conexión remota (resolución DNS,
// balanceo entre réplicas, timeouts). El contenedor api-rest no sabe dónde está el servidor.
package main

import (
	"context"
	"log"
	"net"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

type ambassador struct {
	pb.UnimplementedWarReportServiceServer
	upstream pb.WarReportServiceClient
}

func (a *ambassador) SendReport(ctx context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return a.upstream.SendReport(ctx, req)
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
	pb.RegisterWarReportServiceServer(s, &ambassador{upstream: pb.NewWarReportServiceClient(conn)})

	log.Printf("grpc-client (ambassador) en %s -> %s", listen, upstreamAddr)
	log.Fatal(s.Serve(lis))
}
