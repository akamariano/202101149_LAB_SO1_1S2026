// Package mq define la topología de RabbitMQ que comparten el writer y el consumer,
// y la conexión con reintentos.
package mq

import (
	"log"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Topología: el writer publica en el exchange "war_reports" (tipo direct) con la clave
// "report"; el binding entrega esos mensajes a la cola "war_reports", que lee el consumer.
// El productor no conoce la cola: solo el exchange y la clave.
const (
	Exchange   = "war_reports"
	Queue      = "war_reports"
	RoutingKey = "report"
)

// Connect abre la conexión y un canal, reintentando mientras RabbitMQ no esté listo
// (por ejemplo, al arrancar todo el sistema a la vez). Declara la topología, que es
// idempotente: si ya existe con la misma configuración no cambia nada.
//
// Si la conexión se cae después, el proceso termina y Kubernetes reinicia el contenedor.
// Es más simple y confiable que implementar la reconexión a mano.
func Connect(url string) (*amqp.Connection, *amqp.Channel) {
	var conn *amqp.Connection
	var err error
	for {
		if conn, err = amqp.Dial(url); err == nil {
			break
		}
		log.Printf("RabbitMQ no disponible, reintento en 3s: %v", err)
		time.Sleep(3 * time.Second)
	}
	ch, err := conn.Channel()
	if err != nil {
		log.Fatalf("no se pudo abrir el canal: %v", err)
	}
	if err := declarar(ch); err != nil {
		log.Fatalf("no se pudo declarar la topología: %v", err)
	}
	go func() {
		e := <-conn.NotifyClose(make(chan *amqp.Error, 1))
		log.Fatalf("conexión con RabbitMQ cerrada: %v", e)
	}()
	log.Printf("conectado a RabbitMQ (exchange=%s cola=%s)", Exchange, Queue)
	return conn, ch
}

func declarar(ch *amqp.Channel) error {
	// durable: el exchange y la cola sobreviven a un reinicio del broker
	if err := ch.ExchangeDeclare(Exchange, "direct", true, false, false, false, nil); err != nil {
		return err
	}
	if _, err := ch.QueueDeclare(Queue, true, false, false, false, nil); err != nil {
		return err
	}
	return ch.QueueBind(Queue, RoutingKey, Exchange, false, nil)
}
