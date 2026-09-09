package ebpfprobe

//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -target bpfel probepidfd probe_pidfd.c -- -I.
