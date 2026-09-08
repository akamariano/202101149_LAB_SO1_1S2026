package valkey

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type ValkeyClient struct {
	client *redis.Client
}

func NewValkeyClient(addr string) *ValkeyClient {
	rdb := redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: "", // sin contraseña por defecto
		DB:       0,  // DB por defecto
	})

	return &ValkeyClient{client: rdb}
}

func (v *ValkeyClient) Ping(ctx context.Context) error {
	return v.client.Ping(ctx).Err()
}

func (v *ValkeyClient) StoreTelemetry(ctx context.Context, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("error al serializar telemetria: %w", err)
	}

	key := fmt.Sprintf("telemetry:%d", time.Now().Unix())
	
	// Guardar última lectura y enviar a lista de logs
	pipe := v.client.Pipeline()
	pipe.Set(ctx, "latest_telemetry", jsonData, 0)
	pipe.LPush(ctx, "telemetry_history", jsonData)
	pipe.LTrim(ctx, "telemetry_history", 0, 500) // Mantener últimos 500 registros

	_, err = pipe.Exec(ctx)
	if err != nil {
		log.Printf("[WARN] No se pudo guardar telemetria en Valkey: %v", err)
		return err
	}

	log.Printf("[VALKEY] Telemetria registrada exitosamente en clave: %s", key)
	return nil
}

func (v *ValkeyClient) StoreLogs(ctx context.Context, logs interface{}) error {
	jsonData, err := json.Marshal(logs)
	if err != nil {
		return fmt.Errorf("error al serializar logs: %w", err)
	}

	pipe := v.client.Pipeline()
	pipe.LPush(ctx, "decision_logs", jsonData)
	pipe.LTrim(ctx, "decision_logs", 0, 500)

	_, err = pipe.Exec(ctx)
	if err != nil {
		log.Printf("[WARN] No se pudieron guardar logs de decision en Valkey: %v", err)
		return err
	}

	return nil
}
