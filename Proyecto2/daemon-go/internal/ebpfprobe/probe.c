//go:build ignore
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>

struct trace_event_raw_sys_enter_kill {
    unsigned short common_type;
    unsigned char common_flags;
    unsigned char common_preempt_count;
    int common_pid;
    int syscall_nr;
    __u64 pid;
    __u64 sig;
};
struct kill_event {
    __u32 caller_pid;
    __u32 target_pid;
    __u32 signal;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");
SEC("tracepoint/syscalls/sys_enter_kill")
int handle_sys_enter_kill(struct trace_event_raw_sys_enter_kill *ctx) {
    __u64 target_pid = ctx->pid;
    __u64 signal = ctx->sig;
    struct kill_event *evt;
if (ctx->sig == 0) {
    return 0;
}    
evt = bpf_ringbuf_reserve(&events, sizeof(struct kill_event), 0);
if (!evt) {
    return 0;
}

evt->caller_pid = bpf_get_current_pid_tgid() >> 32;
evt->target_pid = ctx->pid;
evt->signal = ctx->sig;

bpf_ringbuf_submit(evt, 0);
    bpf_printk("Kill syscall intercepted: target_pid=%llu signal=%llu\n", target_pid, signal);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";