package manager

import (
	"daemon-go/internal/procparser"
	"fmt"
	"log"
	"os/exec"
	"sort"
	"strings"
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
}

// Protected container names/IDs that must NEVER be killed
var ProtectedNames = []string{
	"valkey_db",
	"grafana_dashboard",
	"valkey",
	"grafana",
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

	// Ordenamiento por uso de recursos (RAM/RSS, CPU, VSZ)
	sortContainers(lowContainers)
	sortContainers(highContainers)

	log.Printf("[MANAGER] Encontrados: %d Bajo Consumo, %d Alto Consumo (No Protegidos)", len(lowContainers), len(highContainers))

	// Invariante 1: Mantener al menos 3 de bajo consumo. Eliminar excesos si los hay.
	if len(lowContainers) > 3 {
		excess := lowContainers[3:] // Los de mayor consumo en exceso
		for _, c := range excess {
			reason := fmt.Sprintf("Exceso de bajo consumo (Mantenidos 3, eliminando extra ID: %s con RSS: %d KB)", c.ID, c.RSSKB)
			if err := stopAndRemoveContainer(c.ID); err == nil {
				logs = append(logs, DecisionLog{
					Action:      "KILL",
					ContainerID: c.ID,
					Reason:      reason,
					TotalLow:    len(lowContainers),
					TotalHigh:   len(highContainers),
				})
			}
		}
	}

	// Invariante 2: Mantener al menos 2 de alto consumo. Eliminar excesos si los hay.
	if len(highContainers) > 2 {
		excess := highContainers[2:] // Los de mayor consumo en exceso
		for _, c := range excess {
			reason := fmt.Sprintf("Exceso de alto consumo (Mantenidos 2, eliminando extra ID: %s con %%CPU: %.1f%%)", c.ID, c.CPUPerc)
			if err := stopAndRemoveContainer(c.ID); err == nil {
				logs = append(logs, DecisionLog{
					Action:      "KILL",
					ContainerID: c.ID,
					Reason:      reason,
					TotalLow:    len(lowContainers),
					TotalHigh:   len(highContainers),
				})
			}
		}
	}

	return logs, nil
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

func stopAndRemoveContainer(containerID string) error {
	log.Printf("[MANAGER] Deteniendo y eliminando contenedor: %s", containerID)
	cmd := exec.Command("sudo", "docker", "rm", "-f", containerID)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] Error al eliminar contenedor %s: %v | Salida: %s", containerID, err, string(out))
		return err
	}
	log.Printf("[SUCCESS] Contenedor %s eliminado exitosamente", containerID)
	return nil
}
