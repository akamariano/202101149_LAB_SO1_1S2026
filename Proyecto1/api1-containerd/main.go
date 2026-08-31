package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

const (
	carnet  = "202101149"
	apiName = "API1"
	vmNum   = "1"
)

type HealthResponse struct {
	Status    string `json:"status"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
	VM        string `json:"VM"`
	Carnet    string `json:"carnet"`
}

type CallResponse struct {
	APIName    string `json:"apiname"`
	Message    string `json:"message"`
	Connection bool   `json:"connection"`
	Carnet     string `json:"carnet"`
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	resp := HealthResponse{
		Status:    "UP",
		Message:   fmt.Sprintf("%s is Ready", apiName),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		VM:        vmNum,
		Carnet:    carnet,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func callOtherAPI(targetName, targetVM, targetURL string) CallResponse {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(targetURL + "/health")
	if err != nil {
		return CallResponse{targetName, fmt.Sprintf("ERROR: The %s located on the VM%s is not working", targetName, targetVM), false, carnet}
	}
	defer resp.Body.Close()

	var health HealthResponse
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil || health.Status != "UP" {
		return CallResponse{targetName, fmt.Sprintf("ERROR: The %s located on the VM%s is not working", targetName, targetVM), false, carnet}
	}

	return CallResponse{targetName, fmt.Sprintf("The %s located on the VM%s is working", targetName, targetVM), true, carnet}
}

func main() {
	api2URL := getenv("API2_URL", "http://localhost:8082")
	api3URL := getenv("API3_URL", "http://localhost:8083")
	port := getenv("PORT", "8081")

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/api1/"+carnet+"/call-api2", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(callOtherAPI("API2", "1", api2URL))
	})
	mux.HandleFunc("/api1/"+carnet+"/call-api3", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(callOtherAPI("API3", "2", api3URL))
	})

	log.Printf("API1 escuchando en :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
