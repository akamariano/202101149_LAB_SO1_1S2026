package report

// Flujo alternativo con Dapr (/dapr-<carnet>). Lo comparten el publicador (grpc-client,
// Deployment 1) y el suscriptor (grpc-server, Deployment 2).
const (
	// Nombre del Component de Dapr (k8s/90-dapr.yaml), de tipo pubsub.rabbitmq
	DaprPubsub = "pubsub-rabbitmq"
	// Tópico: Dapr crea en RabbitMQ un exchange fanout con este nombre y una cola
	// "<app-id>-<tópico>" por cada aplicación suscrita
	DaprTopic = "war_reports_dapr"
	// Metadata gRPC con la que api-rest le indica al grpc-client por dónde enviar el reporte
	FlujoHeader = "x-flujo"
	FlujoDapr   = "dapr"
)
