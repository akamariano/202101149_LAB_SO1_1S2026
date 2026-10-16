// rabbit-writer: contenedor 2 del Deployment 2 (go-writer).
// Recibe los reportes del grpc-server por localhost y los publica en RabbitMQ como JSON.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"os"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"mumnk8s/internal/mq"
	"mumnk8s/internal/report"
	pb "mumnk8s/proto"
)

type writer struct {
	pb.UnimplementedWarReportServiceServer
	ch    *amqp.Channel
	total atomic.Int64
}

// Cada llamada gRPC corre en su goroutine y todas comparten el mismo canal AMQP
// (Publish es seguro para uso concurrente).
func (w *writer) SendReport(ctx context.Context, req *pb.WarReportRequest) (*pb.WarReportResponse, error) {
	body, err := json.Marshal(report.FromProto(req))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "no se pudo serializar: %v", err)
	}
	// Persistent: el mensaje se guarda en disco y sobrevive a un reinicio del broker.
	conf, err := w.ch.PublishWithDeferredConfirmWithContext(ctx, mq.Exchange, mq.RoutingKey, false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Timestamp:    time.Now(),
			Body:         body,
		})
	if err != nil {
		return nil, status.Errorf(codes.Unavailable, "no se pudo publicar: %v", err)
	}
	// Publisher confirm: RabbitMQ avisa (ack) cuando ya tomó la responsabilidad del
	// mensaje. Solo entonces se responde OK, así un 200 en Locust implica que el
	// reporte quedó en la cola.
	if ok, err := conf.WaitContext(ctx); err != nil || !ok {
		return nil, status.Errorf(codes.Unavailable, "RabbitMQ no confirmó el mensaje: %v", err)
	}
	w.total.Add(1)
	return &pb.WarReportResponse{Status: "publicado"}, nil
}

func main() {
	listen := report.Env("GRPC_LISTEN", "localhost:50052")
	url := report.Env("RABBITMQ_URL", "amqp://guest:guest@rabbitmq:5672/")
	pod, _ := os.Hostname()

	conn, ch := mq.Connect(url)
	defer conn.Close()
	// Modo confirm: a partir de aquí cada publicación recibe un ack del broker.
	if err := ch.Confirm(false); err != nil {
		log.Fatalf("no se pudo activar el modo confirm: %v", err)
	}

	lis, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("no se pudo escuchar en %s: %v", listen, err)
	}
	s := grpc.NewServer()
	w := &writer{ch: ch}
	pb.RegisterWarReportServiceServer(s, w)

	go func() {
		var prev int64
		for range time.Tick(10 * time.Second) {
			if n := w.total.Load(); n != prev {
				log.Printf("[%s] publicados=%d (+%d en 10s)", pod, n, n-prev)
				prev = n
			}
		}
	}()

	log.Printf("rabbit-writer en %s -> exchange %s", listen, mq.Exchange)
	log.Fatal(s.Serve(lis))
}
