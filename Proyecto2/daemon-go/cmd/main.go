package main

import (
	"context"
	"daemon-go/internal/manager"
	"daemon-go/internal/procparser"
	"daemon-go/internal/valkey"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	ProcPath       = "/proc/continfo_pr2_so1_202101149"
	ValkeyAddr     = "localhost:6379"
	LoopIntervalSec = 30
)

func main() {
	log.Println("=========================================================")
	log.Println("=== Iniciando Daemon de Go - Proyecto 2 (SO1 202101149) ===")
	log.Println("=========================================================")

	rootDir := getRootDir()

	// 1. Inicializar servicios de Infraestructura (Valkey + Grafana)
	log.Println("[PASO 1] Iniciando contenedores de Valkey y Grafana vía Docker Compose...")
	dockerComposeFile := filepath.Join(rootDir, "docker-compose.yml")
	log.Printf("[INFO] Usando docker-compose file: %s", dockerComposeFile)
	if err := runCommand("docker", "compose", "-f", dockerComposeFile, "up", "-d"); err != nil {
		log.Printf("[ADVERTENCIA] Error al iniciar con 'docker compose': %v. Intentando 'docker-compose'...", err)
		if err2 := runCommand("docker-compose", "-f", dockerComposeFile, "up", "-d"); err2 != nil {
			log.Printf("[ADVERTENCIA] Error alternativo docker-compose: %v. Continuando...", err2)
		}
	}

	// 2. Cargar e inicializar el Módulo de Kernel
	log.Println("[PASO 2] Cargando módulo de kernel continfo...")
	kernelSrcDir := filepath.Join(rootDir, "kernel-module", "src")
	koPath := filepath.Join(kernelSrcDir, "continfo.ko")

	if _, err := os.Stat(ProcPath); err == nil {
		log.Printf("[INFO] El módulo de kernel continfo ya está cargado y activo en %s", ProcPath)
	} else {
		log.Printf("[INFO] Intentando cargar módulo %s...", koPath)
		_ = runCommand("insmod", koPath)
		if _, err := os.Stat(ProcPath); err != nil {
			log.Printf("[ADVERTENCIA] No se pudo cargar %s. Ejecute 'sudo insmod continfo.ko' en kernel-module/src", ProcPath)
		} else {
			log.Printf("[ÉXITO] Módulo continfo cargado correctamente en %s", ProcPath)
		}
	}

	// 3. Configurar e instalar el Cronjob en el Sistema Operativo
	log.Println("[PASO 3] Instalando Cronjob para despliegue aleatorio cada 2 minutos...")
	cronScriptPath := filepath.Join(rootDir, "cronjob", "deploy_random.sh")
	_ = os.Chmod(cronScriptPath, 0755)
	if err := installCronjob(cronScriptPath); err != nil {
		log.Printf("[ADVERTENCIA] No se pudo instalar cronjob de sistema: %v", err)
	}

	// 4. Inicializar Cliente de Valkey
	vClient := valkey.NewValkeyClient(ValkeyAddr)
	ctx := context.Background()

	// Configurar canal para señales de apagado limpio
	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-stopChan
		log.Println("\n=========================================================")
		log.Println("[FINALIZANDO] Deteniendo Daemon de Go y eliminando Cronjob...")
		_ = removeCronjob()
		log.Println("[FINALIZADO] Servicio detenido correctamente.")
		os.Exit(0)
	}()

	log.Printf("[PASO 4] Iniciando bucle principal infinito (cada %d segundos)...", LoopIntervalSec)

	for {
		log.Println("\n--- Iteracion de Telemetria y Gestion ---")

		// Lectura y parsing de /proc
		data, err := procparser.ParseProcFile(ProcPath)
		if err != nil {
			log.Printf("[ERROR] No se pudo leer %s: %v", ProcPath, err)
		} else {
			log.Printf("[PROC] RAM Total: %d KB | Usada Ajustada: %d KB | Contenedores Detectados: %d",
				data.RAM.TotalKB, data.RAM.UsedAdjKB, len(data.Containers))

			// Evaluación y toma de decisiones de contenedores
			decisionLogs, err := manager.EvaluateAndManageContainers(data.Containers)
			if err != nil {
				log.Printf("[ERROR] Error durante la evaluacion de contenedores: %v", err)
			}

			// Almacenamiento en Valkey
			if err := vClient.StoreTelemetry(ctx, data); err != nil {
				log.Printf("[VALKEY] Error al guardar telemetria: %v", err)
			}
			if len(decisionLogs) > 0 {
				_ = vClient.StoreLogs(ctx, decisionLogs)
			}
		}

		time.Sleep(LoopIntervalSec * time.Second)
	}
}

func getRootDir() string {
	exePath, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exePath)
		// Si estamos dentro de daemon-go, subir un nivel a Proyecto2
		if filepath.Base(dir) == "daemon-go" || filepath.Base(dir) == "cmd" {
			candidate := filepath.Clean(filepath.Join(dir, ".."))
			if _, err := os.Stat(filepath.Join(candidate, "docker-compose.yml")); err == nil {
				return candidate
			}
		}
	}
	// Fallback por defecto si no se determina dinámicamente
	defaultPath := "/home/mariano/202101149_LAB_SO1_1S2026/Proyecto2"
	return defaultPath
}

func installCronjob(scriptPath string) error {
	cronEntry := fmt.Sprintf("*/2 * * * * %s > /dev/null 2>&1", scriptPath)
	tmpCron := "/tmp/current_crontab"

	out, err := exec.Command("crontab", "-l").CombinedOutput()
	existingCron := string(out)

	// Si crontab está vacío o dice "no crontab for...", ignorar salida anterior
	if err != nil || strings.Contains(existingCron, "no crontab") {
		existingCron = ""
	}

	// Si ya está instalado el cronjob, no duplicar
	if strings.Contains(existingCron, scriptPath) {
		log.Println("[CRONJOB] El cronjob ya se encuentra registrado.")
		return nil
	}

	newCron := strings.TrimSpace(existingCron)
	if newCron != "" {
		newCron += "\n"
	}
	newCron += cronEntry + "\n"

	err = os.WriteFile(tmpCron, []byte(newCron), 0644)
	if err != nil {
		return err
	}

	return runCommand("crontab", tmpCron)
}

func removeCronjob() error {
	log.Println("[CRONJOB] Eliminando crontab del sistema...")
	return runCommand("crontab", "-r")
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, string(out))
	}
	return nil
}

func runCommandInDir(dir string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, string(out))
	}
	return nil
}
