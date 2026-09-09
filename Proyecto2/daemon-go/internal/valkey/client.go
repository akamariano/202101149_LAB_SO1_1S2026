package valkey

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"
    "daemon-go/internal/procparser"
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
	wrapped := map[string]interface{}{
		"timestamp": time.Now().Unix(),
		"data":      data,
	}

	jsonData, err := json.Marshal(wrapped)
	if err != nil {
		return fmt.Errorf("error al serializar telemetria: %w", err)
	}

	key := fmt.Sprintf("telemetry:%d", time.Now().Unix())

	pipe := v.client.Pipeline()
	pipe.Set(ctx, "latest_telemetry", jsonData, 0)
	pipe.LPush(ctx, "telemetry_history", jsonData)
	pipe.LTrim(ctx, "telemetry_history", 0, 500)

	_, err = pipe.Exec(ctx)
	if err != nil {
		log.Printf("[WARN] No se pudo guardar telemetria en Valkey: %v", err)
		return err
	}

	log.Printf("[VALKEY] Telemetria registrada exitosamente en clave: %s", key)
	return nil
}
func (v *ValkeyClient) IncrementEBPFEventCount(ctx context.Context) error {
	return v.client.Incr(ctx, "ebpf_kill_events_total").Err()
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
func (v *ValkeyClient) StoreTopContainers(ctx context.Context, containers []procparser.ContainerInfo) error {
	pipe := v.client.Pipeline()

	pipe.Del(ctx, "top_ram")
	pipe.Del(ctx, "top_cpu")

	for _, c := range containers {
		label := fmt.Sprintf("%s (%s)", c.ID, c.Command)
		pipe.ZAdd(ctx, "top_ram", redis.Z{Score: float64(c.RSSKB), Member: label})
		pipe.ZAdd(ctx, "top_cpu", redis.Z{Score: c.CPUPerc, Member: label})
	}

	_, err := pipe.Exec(ctx)
	return err
}