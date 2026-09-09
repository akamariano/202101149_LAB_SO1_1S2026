package main

import (
	"daemon-go/internal/ebpfprobe"
	"log"
)

func main() {
	probe, err := ebpfprobe.Start()
	if err != nil {
		log.Fatalf("Error iniciando sonda eBPF: %v", err)
	}
	defer probe.Close()

	log.Println("Sonda eBPF activa, escuchando llamadas a kill...")
	for evt := range probe.Events() {
		log.Printf("Evento capturado: caller_pid=%d target_pid=%d signal=%d", evt.CallerPID, evt.TargetPID, evt.Signal)
	}
}