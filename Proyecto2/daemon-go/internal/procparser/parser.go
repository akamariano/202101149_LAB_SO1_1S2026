package procparser

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type RAMTelemetry struct {
	TotalKB   int64 `json:"total_kb"`
	FreeKB    int64 `json:"free_kb"`
	BufferKB  int64 `json:"buffer_kb"`
	UsedRawKB int64 `json:"used_raw_kb"`
	UsedAdjKB int64 `json:"used_adj_kb"`
}

type ContainerInfo struct {
	PID        int64   `json:"pid"`
	Command    string  `json:"command"`
	ID         string  `json:"id"`
	VSZKB      int64   `json:"vsz_kb"`
	RSSKB      int64   `json:"rss_kb"`
	RAMPerc    float64 `json:"ram_perc"`
	CPUPerc    float64 `json:"cpu_perc"`
	CgroupPath string  `json:"cgroup_path"`
}

type TelemetryData struct {
	RAM        RAMTelemetry    `json:"ram"`
	Containers []ContainerInfo `json:"containers"`
}

// ParseProcFile lee el archivo /proc/continfo_pr2_so1_202101149 y lo deserializa
func ParseProcFile(procPath string) (*TelemetryData, error) {
	file, err := os.Open(procPath)
	if err != nil {
		return nil, fmt.Errorf("error al abrir proc file %s: %w", procPath, err)
	}
	defer file.Close()

	telemetry := &TelemetryData{
		Containers: make([]ContainerInfo, 0),
	}

	scanner := bufio.NewScanner(file)
	inProcessSection := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		if strings.Contains(line, "--- Lista de Procesos") {
			inProcessSection = true
			continue
		}

		if !inProcessSection {
			// Parsing de métricas de RAM
			parseRAMLine(line, &telemetry.RAM)
		} else {
			// Parsing de filas de contenedores
			if container, ok := parseContainerLine(line); ok {
				telemetry.Containers = append(telemetry.Containers, container)
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error al leer proc file: %w", err)
	}

	return telemetry, nil
}

func parseRAMLine(line string, ram *RAMTelemetry) {
	parts := strings.Split(line, ":")
	if len(parts) < 2 {
		return
	}
	key := strings.TrimSpace(parts[0])
	valPart := strings.TrimSpace(parts[1])

	// Extraer primer número antes de KB
	kbVal := parseFirstNumber(valPart)

	switch {
	case strings.HasPrefix(key, "Total RAM"):
		ram.TotalKB = kbVal
	case strings.HasPrefix(key, "Free RAM"):
		ram.FreeKB = kbVal
	case strings.HasPrefix(key, "Buffer RAM"):
		ram.BufferKB = kbVal
	case strings.HasPrefix(key, "Used RAM (Calculo Bruto)"):
		ram.UsedRawKB = kbVal
	case strings.HasPrefix(key, "Used RAM (Ajustado)"):
		ram.UsedAdjKB = kbVal
	}
}

func parseContainerLine(line string) (ContainerInfo, bool) {
	var c ContainerInfo
	if !strings.HasPrefix(line, "PID:") {
		return c, false
	}

	parts := strings.Split(line, "|")
	for _, part := range parts {
		subParts := strings.SplitN(strings.TrimSpace(part), ":", 2)
		if len(subParts) < 2 {
			continue
		}
		fieldKey := strings.TrimSpace(subParts[0])
		fieldVal := strings.TrimSpace(subParts[1])

		switch fieldKey {
		case "PID":
			c.PID, _ = strconv.ParseInt(fieldVal, 10, 64)
		case "Command":
			c.Command = fieldVal
		case "ID":
			c.ID = fieldVal
		case "VSZ":
			c.VSZKB = parseFirstNumber(fieldVal)
		case "RSS":
			c.RSSKB = parseFirstNumber(fieldVal)
		case "%RAM":
			valStr := strings.TrimSuffix(fieldVal, "%")
			c.RAMPerc, _ = strconv.ParseFloat(valStr, 64)
		case "%CPU":
			valStr := strings.TrimSuffix(fieldVal, "%")
			c.CPUPerc, _ = strconv.ParseFloat(valStr, 64)
		case "Cgroup":
			c.CgroupPath = fieldVal
		}
	}

	return c, true
}

func parseFirstNumber(str string) int64 {
	fields := strings.Fields(str)
	if len(fields) == 0 {
		return 0
	}
	val, _ := strconv.ParseInt(fields[0], 10, 64)
	return val
}
