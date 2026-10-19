// falco-bridge: recibe las alertas de Falco (http_output, un POST con el JSON de cada
// alerta) y las guarda en Valkey para que Grafana las muestre con el mismo datasource que
// usa para los reportes.
//
// Claves:
//
//	falco:alertas          stream  una entrada por alerta (hora, prioridad, regla, pod, ...)
//	falco:total            string  contador de todas las alertas
//	falco:total:mumnk8s    string  contador de las alertas de la regla propia (tag "mumnk8s")
//
// Se usa un stream porque el plugin redis-datasource de Grafana lo lee con XREVRANGE como una
// tabla (una fila por alerta, una columna por campo). Con una lista o un hash no se puede.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"slices"
	"time"
	_ "time/tzdata" // la imagen alpine no trae zonas horarias

	"github.com/valkey-io/valkey-go"

	"mumnk8s/internal/report"
)

// Alerta es el JSON que envía Falco con json_output: true
type Alerta struct {
	Time         time.Time      `json:"time"`
	Rule         string         `json:"rule"`
	Priority     string         `json:"priority"`
	Output       string         `json:"output"`
	Hostname     string         `json:"hostname"`
	Tags         []string       `json:"tags"`
	OutputFields map[string]any `json:"output_fields"`
}

// campo devuelve un output_field como texto ("" si la regla no lo incluye)
func (a Alerta) campo(k string) string {
	v, ok := a.OutputFields[k]
	if !ok || v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func main() {
	addr := report.Env("HTTP_ADDR", ":2801")
	valkeyAddr := report.Env("VALKEY_ADDR", "valkey:6379")
	zona, err := time.LoadLocation(report.Env("ZONA_HORARIA", "America/Guatemala"))
	if err != nil {
		log.Fatalf("zona horaria: %v", err)
	}

	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{valkeyAddr}})
	if err != nil {
		log.Fatalf("no se pudo conectar a Valkey %s: %v", valkeyAddr, err)
	}
	defer client.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /", func(w http.ResponseWriter, r *http.Request) {
		var a Alerta
		if err := json.NewDecoder(r.Body).Decode(&a); err != nil {
			http.Error(w, "JSON inválido: "+err.Error(), http.StatusBadRequest)
			return
		}
		propia := slices.Contains(a.Tags, "mumnk8s")
		// El orden de los campos es el orden de las columnas en la tabla de Grafana.
		// MAXLEN ~ 500: el stream no crece sin límite.
		cmds := valkey.Commands{
			client.B().Arbitrary("XADD").Keys("falco:alertas").Args(
				"MAXLEN", "~", "500", "*",
				"hora", a.Time.In(zona).Format("2006-01-02 15:04:05"),
				"prioridad", a.Priority,
				"regla", a.Rule,
				"pod", a.campo("k8s.pod.name"),
				"contenedor", a.campo("container.name"),
				"comando", a.campo("proc.cmdline"),
				"archivo", a.campo("fd.name"),
				"resultado", a.campo("evt.res"),
				"nodo", a.Hostname,
			).Build(),
			client.B().Incr().Key("falco:total").Build(),
		}
		if propia {
			cmds = append(cmds, client.B().Incr().Key("falco:total:mumnk8s").Build())
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		for _, res := range client.DoMulti(ctx, cmds...) {
			if err := res.Error(); err != nil {
				log.Printf("no se pudo guardar la alerta %q: %v", a.Rule, err)
				http.Error(w, "Valkey no disponible", http.StatusServiceUnavailable)
				return
			}
		}
		log.Printf("alerta %s: %s (pod=%s comando=%q)", a.Priority, a.Rule, a.campo("k8s.pod.name"), a.campo("proc.cmdline"))
		w.WriteHeader(http.StatusNoContent)
	})

	log.Printf("falco-bridge en %s -> Valkey %s (stream falco:alertas)", addr, valkeyAddr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
