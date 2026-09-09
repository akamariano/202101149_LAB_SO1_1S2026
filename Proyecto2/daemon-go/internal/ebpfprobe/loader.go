package ebpfprobe

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"

	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
)

// KillEvent mirrors the C struct kill_event defined in probe.c
// Field order and types must match exactly for binary decoding to work
type KillEvent struct {
	CallerPID uint32
	TargetPID uint32
	Signal    uint32
}

// Probe holds the loaded eBPF objects and the tracepoint link,
// kept alive for as long as the probe should keep capturing events
type Probe struct {
	objs probeObjects
	link link.Link
	rd   *ringbuf.Reader
}

// Start loads the compiled eBPF program, attaches it to the sys_enter_kill
// tracepoint, and opens a reader on the ring buffer map
func Start() (*Probe, error) {
	var objs probeObjects
	if err := loadProbeObjects(&objs, nil); err != nil {
		return nil, fmt.Errorf("loading eBPF objects: %w", err)
	}

	tp, err := link.Tracepoint("syscalls", "sys_enter_kill", objs.HandleSysEnterKill, nil)
	if err != nil {
		objs.Close()
		return nil, fmt.Errorf("attaching tracepoint: %w", err)
	}

	rd, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		tp.Close()
		objs.Close()
		return nil, fmt.Errorf("opening ringbuf reader: %w", err)
	}

	return &Probe{objs: objs, link: tp, rd: rd}, nil
}

// Close releases the tracepoint attachment, the ring buffer reader,
// and the loaded eBPF objects, in that order
func (p *Probe) Close() {
	p.rd.Close()
	p.link.Close()
	p.objs.Close()
}

// Events returns a channel that receives decoded kill events as they arrive.
// It runs a background goroutine reading from the ring buffer indefinitely
func (p *Probe) Events() <-chan KillEvent {
	out := make(chan KillEvent)
	go func() {
		defer close(out)
		for {
			record, err := p.rd.Read()
			if err != nil {
				log.Printf("[EBPF] Error leyendo ring buffer: %v", err)
				return
			}

			var evt KillEvent
			if err := binary.Read(bytes.NewReader(record.RawSample), binary.LittleEndian, &evt); err != nil {
				log.Printf("[EBPF] Error decodificando evento: %v", err)
				continue
			}

			out <- evt
		}
	}()
	return out
}