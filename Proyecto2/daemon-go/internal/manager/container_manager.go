package manager

import (
	"daemon-go/internal/ebpfprobe"
	"daemon-go/internal/procparser"
	"fmt"
	"log"
	"os/exec"
	"sort"
	"strings"
	"time"
)

type ContainerCategory string

const (
	CategoryLow  ContainerCategory = "LOW"
	CategoryHigh ContainerCategory = "HIGH"
)

type CategorizedContainer struct {
	procparser.ContainerInfo
	Category ContainerCategory
}

type DecisionLog struct {
	Timestamp     string   `json:"timestamp"`
	Action        string   `json:"action"`
	ContainerID   string   `json:"container_id"`
	Reason        string   `json:"reason"`
	TotalLow      int      `json:"total_low"`
	TotalHigh     int      `json:"total_high"`
	ProtectedList []string `json:"protected_list"`
	EBPFConfirmed bool     `json:"ebpf_confirmed"`
}

// Protected container names/IDs that must NEVER be killed
var ProtectedNames = []string{
	"valkey_db",
	"grafana_dashboard",
	"valkey",
	"grafana",
}
var activePidfdProbe *ebpfprobe.PidfdProbe

const ebpfConfirmTimeout = 3 * time.Second

// SetPidfdProbe registra la sonda eBPF activa para que stopAndRemoveContainer
// pueda esperar la confirmacion real de SIGKILL antes de reportar exito
func SetPidfdProbe(p *ebpfprobe.PidfdProbe) {
	activePidfdProbe = p
}
// EvaluateAndManageContainers analiza los contenedores y aplica las restricciones del sistema
func EvaluateAndManageContainers(containers []procparser.ContainerInfo) ([]DecisionLog, error) {
	logs := make([]DecisionLog, 0)

	var lowContainers []CategorizedContainer
	var highContainers []CategorizedContainer

	for _, c := range containers {
		if isProtected(c) {
			log.Printf("[INFO] Contenedor protegido omitido: %s (%s)", c.ID, c.Command)
			continue
		}

		cat := classifyContainer(c)
		cc := CategorizedContainer{ContainerInfo: c, Category: cat}

		if cat == CategoryLow {
			lowContainers = append(lowContainers, cc)
		} else {
			highContainers = append(highContainers, cc)
		}
	}

	// Ordenamiento descendente (de mayor consumo a menor consumo) para eliminar los más pesados en exceso
	sortContainersDescending(lowContainers)
	sortContainersDescending(highContainers)

	log.Printf("[MANAGER] Encontrados: %d Bajo Consumo, %d Alto Consumo (No Protegidos)", len(lowContainers), len(highContainers))

	// Invariante 1: Mantener exactamente 3 de bajo consumo. Eliminar los excedentes más pesados.
	if len(lowContainers) > 3 {
		excessCount := len(lowContainers) - 3
		for i := 0; i < excessCount; i++ {
			c := lowContainers[i] // El más pesado del exceso
			reason := fmt.Sprintf("Exceso de bajo consumo (Límite: 3, eliminando ID: %s con RSS: %d KB)", c.ID, c.RSSKB)
			if confirmed, err := stopAndRemoveContainer(c.ID); err == nil {
	logs = append(logs, DecisionLog{
		Timestamp:     time.Now().Format(time.RFC3339),
		Action:        "KILL",
		ContainerID:   c.ID,
		Reason:        reason,
		TotalLow:      len(lowContainers),
		TotalHigh:     len(highContainers),
		EBPFConfirmed: confirmed,
	})
}
		}
	}

	// Invariante 2: Mantener exactamente 2 de alto consumo. Eliminar los excedentes más pesados.
	if len(highContainers) > 2 {
		excessCount := len(highContainers) - 2
		for i := 0; i < excessCount; i++ {
			c := highContainers[i] // El más pesado del exceso
			reason := fmt.Sprintf("Exceso de alto consumo (Límite: 2, eliminando ID: %s con %%CPU: %.1f%%)", c.ID, c.CPUPerc)
			if confirmed, err := stopAndRemoveContainer(c.ID); err == nil {
	logs = append(logs, DecisionLog{
		Timestamp:     time.Now().Format(time.RFC3339),
		Action:        "KILL",
		ContainerID:   c.ID,
		Reason:        reason,
		TotalLow:      len(lowContainers),
		TotalHigh:     len(highContainers),
		EBPFConfirmed: confirmed,
	})
}
		}
	}

	return logs, nil
}

func sortContainersDescending(list []CategorizedContainer) {
	sort.Slice(list, func(i, j int) bool {
		if list[i].RSSKB != list[j].RSSKB {
			return list[i].RSSKB > list[j].RSSKB // Mayor consumo primero
		}
		if list[i].CPUPerc != list[j].CPUPerc {
			return list[i].CPUPerc > list[j].CPUPerc
		}
		return list[i].VSZKB > list[j].VSZKB
	})
}

func classifyContainer(c procparser.ContainerInfo) ContainerCategory {
	cmdLower := strings.ToLower(c.Command)
	cgroupLower := strings.ToLower(c.CgroupPath)

	// Intruso o go-client o bucle CPU o uso significativo
	if strings.Contains(cgroupLower, "intruso") ||
		strings.Contains(cmdLower, "intruso") ||
		strings.Contains(cmdLower, "go-client") ||
		c.CPUPerc > 5.0 ||
		c.RSSKB > 10000 {
		return CategoryHigh
	}

	return CategoryLow
}

func sortContainers(list []CategorizedContainer) {
	sort.Slice(list, func(i, j int) bool {
		// Priorizar por mayor RSS, luego mayor %CPU, luego mayor VSZ
		if list[i].RSSKB != list[j].RSSKB {
			return list[i].RSSKB < list[j].RSSKB // Orden ascendente para conservar los menores
		}
		if list[i].CPUPerc != list[j].CPUPerc {
			return list[i].CPUPerc < list[j].CPUPerc
		}
		return list[i].VSZKB < list[j].VSZKB
	})
}

func isProtected(c procparser.ContainerInfo) bool {
	cmdLower := strings.ToLower(c.Command)
	cgroupLower := strings.ToLower(c.CgroupPath)

	for _, name := range ProtectedNames {
		if strings.Contains(cmdLower, name) || strings.Contains(cgroupLower, name) {
			return true
		}
	}
	return false
}

func stopAndRemoveContainer(containerID string) (bool, error) {
	log.Printf("[MANAGER] Deteniendo y eliminando contenedor: %s", containerID)
	cmd := exec.Command("sudo", "docker", "rm", "-f", containerID)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] Error al eliminar contenedor %s: %v | Salida: %s", containerID, err, string(out))
		return false, err
	}

	confirmed := false
	if activePidfdProbe != nil {
		confirmed = activePidfdProbe.WaitForKillConfirmation(ebpfConfirmTimeout)
	}

	if confirmed {
		log.Printf("[SUCCESS] Contenedor %s eliminado y confirmado por eBPF (SIGKILL detectado)", containerID)
	} else {
		log.Printf("[SUCCESS] Contenedor %s eliminado (sin confirmacion eBPF dentro del timeout)", containerID)
	}
	return confirmed, nil
}
