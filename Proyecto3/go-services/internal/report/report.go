// Package report contiene el modelo JSON del reporte militar y su conversión
// al mensaje protobuf. Lo comparten todos los binarios de go-services.
package report

import (
	"fmt"
	"os"
	"strings"
	"time"

	pb "mumnk8s/proto"
)

// WarReport es el JSON que envía Locust (y reenvía la API de Rust).
type WarReport struct {
	Country         string `json:"country"`
	WarplanesInAir  int32  `json:"warplanes_in_air"`
	WarshipsInWater int32  `json:"warships_in_water"`
	Timestamp       string `json:"timestamp"`
}

// ToProto valida el reporte y lo convierte a WarReportRequest.
// "GTM" -> Countries_gtm; países fuera del enum se rechazan.
func (r WarReport) ToProto() (*pb.WarReportRequest, error) {
	code, ok := pb.Countries_value[strings.ToLower(r.Country)]
	if !ok || code == int32(pb.Countries_countries_unknown) {
		return nil, fmt.Errorf("país no soportado: %q", r.Country)
	}
	if r.WarplanesInAir < 0 || r.WarshipsInWater < 0 {
		return nil, fmt.Errorf("las cantidades no pueden ser negativas")
	}
	ts := r.Timestamp
	if ts == "" {
		ts = time.Now().UTC().Format(time.RFC3339)
	} else if _, err := time.Parse(time.RFC3339, ts); err != nil {
		return nil, fmt.Errorf("timestamp inválido (se espera RFC3339): %q", ts)
	}
	return &pb.WarReportRequest{
		Country:         pb.Countries(code),
		WarplanesInAir:  r.WarplanesInAir,
		WarshipsInWater: r.WarshipsInWater,
		Timestamp:       ts,
	}, nil
}

// CountryCode devuelve el código de 3 letras en mayúsculas ("GTM") de un enum.
func CountryCode(c pb.Countries) string { return strings.ToUpper(c.String()) }

// Env devuelve la variable de entorno o un valor por defecto.
func Env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// FromProto hace la conversión inversa: del mensaje protobuf al JSON que viaja por RabbitMQ.
func FromProto(req *pb.WarReportRequest) WarReport {
	return WarReport{
		Country:         CountryCode(req.GetCountry()),
		WarplanesInAir:  req.GetWarplanesInAir(),
		WarshipsInWater: req.GetWarshipsInWater(),
		Timestamp:       req.GetTimestamp(),
	}
}
