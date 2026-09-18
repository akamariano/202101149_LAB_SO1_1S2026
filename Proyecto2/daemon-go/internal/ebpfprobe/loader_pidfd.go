package ebpfprobe

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"time"

	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
)

// PidfdKillEvent mirrors the C struct pidfd_kill_event defined in probe_pidfd.c
type PidfdKillEvent struct {
	CallerPID uint32
	Signal    uint32
}

// PidfdProbe holds the loaded eBPF objects for the pidfd_send_signal tracepoint
type PidfdProbe struct {
	objs probepidfdObjects
	link link.Link
	rd   *ringbuf.Reader
	ch   chan PidfdKillEvent
}

// StartPidfdProbe loads the compiled eBPF program, attaches it to the
// sys_enter_pidfd_send_signal tracepoint, and starts a background reader
// that publishes SIGKILL events on a channel
func StartPidfdProbe() (*PidfdProbe, error) {
	var objs probepidfdObjects
	if err := loadProbepidfdObjects(&objs, nil); err != nil {
		return nil, fmt.Errorf("loading eBPF objects: %w", err)
	}

	tp, err := link.Tracepoint("syscalls", "sys_enter_pidfd_send_signal", objs.HandleSysEnterPidfdSendSignal, nil)
	if err != nil {
		objs.Close()
		return nil, fmt.Errorf("attaching tracepoint: %w", err)
	}

	rd, err := ringbuf.NewReader(objs.PidfdEvents)
	if err != nil {
		tp.Close()
		objs.Close()
		return nil, fmt.Errorf("opening ringbuf reader: %w", err)
	}

	p := &PidfdProbe{objs: objs, link: tp, rd: rd, ch: make(chan PidfdKillEvent, 32)}
	go p.readLoop()
	return p, nil
}

func (p *PidfdProbe) readLoop() {
	for {
		record, err := p.rd.Read()
		if err != nil {
			log.Printf("[EBPF] Error leyendo ring buffer de pidfd: %v", err)
			return
		}

		var evt PidfdKillEvent
		if err := binary.Read(bytes.NewReader(record.RawSample), binary.LittleEndian, &evt); err != nil {
			log.Printf("[EBPF] Error decodificando evento pidfd: %v", err)
			continue
		}

		select {
		case p.ch <- evt:
		default:
			// canal lleno, se descarta el evento mas viejo implicitamente
		}
	}
}

// WaitForKillConfirmation blocks until a SIGKILL event arrives on the
// ring buffer or the timeout expires. Returns true if an event was confirmed.
func (p *PidfdProbe) WaitForKillConfirmation(timeout time.Duration) (PidfdKillEvent, bool) {
	select {
	case evt := <-p.ch:
		return evt, true
	case <-time.After(timeout):
		return PidfdKillEvent{}, false
	}
}

func (p *PidfdProbe) Close() {
	p.rd.Close()
	p.link.Close()
	p.objs.Close()
}
