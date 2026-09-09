//go:build ignore

#include <vmlinux.h>
#include <bpf/bpf_helpers.h>

#define SIGKILL_NUM 9

struct trace_event_raw_sys_enter_pidfd_send_signal {
    unsigned short common_type;
    unsigned char common_flags;
    unsigned char common_preempt_count;
    int common_pid;
    int syscall_nr;
    __u64 pidfd;
    __u64 sig;
};

struct pidfd_kill_event {
    __u32 caller_pid;
    __u32 signal;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} pidfd_events SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_pidfd_send_signal")
int handle_sys_enter_pidfd_send_signal(struct trace_event_raw_sys_enter_pidfd_send_signal *ctx) {
    if (ctx->sig != SIGKILL_NUM) {
        return 0;
    }

    struct pidfd_kill_event *evt;
    evt = bpf_ringbuf_reserve(&pidfd_events, sizeof(struct pidfd_kill_event), 0);
    if (!evt) {
        return 0;
    }

    evt->caller_pid = bpf_get_current_pid_tgid() >> 32;
    evt->signal = ctx->sig;

    bpf_ringbuf_submit(evt, 0);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
