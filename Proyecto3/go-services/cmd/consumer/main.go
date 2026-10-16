// consumer: Deployment que lee los reportes de la cola war_reports y los guarda en
// Valkey (Service creado por el operador a partir del CR ValkeyInstance).
package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"mumnk8s/internal/mq"
	"mumnk8s/internal/report"
	"mumnk8s/internal/store"
)

var total atomic.Int64

func procesar(st *store.Store, d amqp.Delivery, pod string) {
	var r report.WarReport
	if err := json.Unmarshal(d.Body, &r); err != nil {
		// Mensaje malformado: se descarta (requeue=false). Si se reencolara,
		// volvería a fallar para siempre.
		log.Printf("[%s] mensaje inválido descartado: %v", pod, err)
		d.Nack(false, false)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := st.Guardar(ctx, r); err != nil {
		// Valkey no disponible: el mensaje vuelve a la cola para reintentarlo.
		// La pausa evita un ciclo que sature el log y la red mientras Valkey vuelve.
		log.Printf("[%s] no se pudo guardar en Valkey, se reencola: %v", pod, err)
		time.Sleep(time.Second)
		d.Nack(false, true)
		return
	}
	if n := total.Add(1); n <= 5 {
		log.Printf("[%s] #%d %s aviones=%d barcos=%d ts=%s", pod, n, r.Country, r.WarplanesInAir, r.WarshipsInWater, r.Timestamp)
	}
	// Ack manual DESPUÉS de guardar en Valkey: si el pod muere antes, RabbitMQ
	// reentrega el mensaje a otro consumer y no se pierde.
	d.Ack(false)
}

func main() {
	url := report.Env("RABBITMQ_URL", "amqp://guest:guest@rabbitmq:5672/")
	workers, _ := strconv.Atoi(report.Env("WORKERS", "8"))
	valkeyAddr := report.Env("VALKEY_ADDR", "valkey:6379")
	pod, _ := os.Hostname()

	st, err := store.New(valkeyAddr)
	if err != nil {
		log.Fatalf("no se pudo conectar a Valkey en %s: %v", valkeyAddr, err)
	}
	defer st.Close()

	conn, ch := mq.Connect(url)
	defer conn.Close()

	// Prefetch: máximo de mensajes sin ack que RabbitMQ entrega a este consumer.
	// Limita la memoria del pod y reparte la carga si hay varias réplicas.
	if err := ch.Qos(workers*10, 0, false); err != nil {
		log.Fatalf("no se pudo configurar el prefetch: %v", err)
	}
	msgs, err := ch.Consume(mq.Queue, pod, false, false, false, false, nil)
	if err != nil {
		log.Fatalf("no se pudo consumir la cola: %v", err)
	}

	// Pool de workers: varias goroutines leen del mismo canal de entregas.
	for i := 0; i < workers; i++ {
		go func() {
			for d := range msgs {
				procesar(st, d, pod)
			}
		}()
	}

	log.Printf("consumer %s leyendo %s con %d workers -> Valkey %s", pod, mq.Queue, workers, valkeyAddr)
	var prev int64
	for range time.Tick(10 * time.Second) {
		if n := total.Load(); n != prev {
			log.Printf("[%s] procesados=%d (+%d en 10s)", pod, n, n-prev)
			prev = n
		}
	}
}
