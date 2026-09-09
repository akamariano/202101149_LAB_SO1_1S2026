package ebpfprobe
//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -target bpfel probe probe.c -- -I.
