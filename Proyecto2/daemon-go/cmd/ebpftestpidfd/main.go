package main

import (
	"daemon-go/internal/ebpfprobe"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	probe, err := ebpfprobe.StartPidfdProbe()
	if err != nil {
		log.Fatalf("Error iniciando sonda pidfd: %v", err)
	}
	defer probe.Close()

	log.Println("Sonda pidfd_send_signal activa. Corré 'sudo cat /sys/kernel/tracing/trace_pipe' en otra terminal para ver los eventos.")
	log.Println("Presioná Ctrl+C para detener.")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Println("Deteniendo sonda...")
}