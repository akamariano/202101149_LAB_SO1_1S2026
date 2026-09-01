#include <linux/module.h>      /* Required for all kernel modules */
#include <linux/kernel.h>      /* KERN_INFO and kernel logging functions */
#include <linux/init.h>        /* Macros __init and __exit */
#include <linux/proc_fs.h>     /* /proc functions (proc_create, remove_proc_entry) */
#include <linux/seq_file.h>    /* seq_file interface (seq_printf, single_open) */
#include <linux/mm.h>          /* Memory definitions and si_meminfo */
#include <linux/sched/signal.h>/* Process iteration macros (for_each_process) */
#include <linux/cgroup.h>      /* Cgroup functions (cgroup_path, task_css_set) */
#include <linux/string.h>      /* String functions (strstr) */
#include <linux/timekeeping.h> /* Timekeeping functions (ktime_get_boottime_ns) */

MODULE_LICENSE("GPL");
MODULE_AUTHOR("202101149");
MODULE_DESCRIPTION("Kernel probe for RAM memory telemetry");
MODULE_VERSION("1.0");

#define PROC_NAME "continfo_pr2_so1_202101149"

/* Static pointer to hold the created /proc entry */
static struct proc_dir_entry *continfo_entry;

/* Function to display memory metrics when /proc file is read */
static int continfo_show(struct seq_file *m, void *v) {
    struct sysinfo sys_info;
    struct task_struct *task;
    
    /* Get system memory metrics */
    si_meminfo(&sys_info);

    /* Convert pages to Kilobytes (KB) */
    unsigned long factor_kb = PAGE_SIZE / 1024;
    
    /* Base calculations in KB */
    unsigned long total_ram_kb  = sys_info.totalram * factor_kb;
    unsigned long free_ram_kb   = sys_info.freeram * factor_kb;
    unsigned long buffer_ram_kb = sys_info.bufferram * factor_kb;
    
    /* Memory calculations: Raw (Bruto) vs Adjusted (Ajustado descontando buffers) */
    unsigned long used_raw_kb   = total_ram_kb - free_ram_kb;
    unsigned long used_adj_kb   = total_ram_kb - free_ram_kb - buffer_ram_kb;

    /* Conversions to MB */
    unsigned long total_ram_mb  = total_ram_kb / 1024;
    unsigned long free_ram_mb   = free_ram_kb / 1024;
    unsigned long buffer_ram_mb = buffer_ram_kb / 1024;
    unsigned long used_raw_mb   = used_raw_kb / 1024;
    unsigned long used_adj_mb   = used_adj_kb / 1024;

    /* Conversions to GB */
    unsigned long total_ram_gb  = total_ram_mb / 1024;
    unsigned long free_ram_gb   = free_ram_mb / 1024;
    unsigned long buffer_ram_gb = buffer_ram_mb / 1024;
    unsigned long used_raw_gb   = used_raw_mb / 1024;
    unsigned long used_adj_gb   = used_adj_mb / 1024;

    /* Write output to the seq_file buffer with text in Spanish */
    seq_printf(m, "--- Telemetria de Memoria RAM ---\n");
    seq_printf(m, "Total RAM               : %lu KB | %lu MB | %lu GB\n", total_ram_kb, total_ram_mb, total_ram_gb);
    seq_printf(m, "Free RAM                : %lu KB | %lu MB | %lu GB\n", free_ram_kb, free_ram_mb, free_ram_gb);
    seq_printf(m, "Buffer RAM              : %lu KB | %lu MB | %lu GB\n", buffer_ram_kb, buffer_ram_mb, buffer_ram_gb);
    seq_printf(m, "Used RAM (Calculo Bruto): %lu KB | %lu MB | %lu GB\n", used_raw_kb, used_raw_mb, used_raw_gb);
    seq_printf(m, "Used RAM (Ajustado)     : %lu KB | %lu MB | %lu GB\n", used_adj_kb, used_adj_mb, used_adj_gb);

    /* Write process list (Filtered for container processes) */
    seq_printf(m, "\n--- Lista de Procesos (Contenedores) ---\n");
    rcu_read_lock();
    for_each_process(task) {
        char cgroup_path_buf[256];
        cgroup_path(task_css_set(task)->dfl_cgrp, cgroup_path_buf, sizeof(cgroup_path_buf));
        char *match = strstr(cgroup_path_buf, "docker-");
        if (match != NULL) {
            char container_id[65] = "N/A";
            char *id_start = match + 7;
            char *dot = strchr(id_start, '.');
            if (dot != NULL) {
                size_t id_len = dot - id_start;
                if (id_len >= sizeof(container_id))
                    id_len = sizeof(container_id) - 1;
                strncpy(container_id, id_start, id_len);
                container_id[id_len] = '\0';
            } else {
                strncpy(container_id, id_start, sizeof(container_id) - 1);
                container_id[sizeof(container_id) - 1] = '\0';
            }

            unsigned long vsz_kb = 0;
            unsigned long rss_kb = 0;
            unsigned long ram_perc_int = 0;
            unsigned long ram_perc_dec = 0;
            u64 cpu_perc_int = 0;
            u64 cpu_perc_dec = 0;

            if (task->mm) {
                vsz_kb = task->mm->total_vm * factor_kb;
                rss_kb = get_mm_rss(task->mm) * factor_kb;

                if (total_ram_kb > 0) {
                    unsigned long ram_perc_x10 = (rss_kb * 1000) / total_ram_kb;
                    ram_perc_int = ram_perc_x10 / 10;
                    ram_perc_dec = ram_perc_x10 % 10;
                }
            }

            u64 cpu_time_ns = task->utime + task->stime;
            u64 current_time_ns = ktime_get_boottime_ns();
            u64 elapsed_ns = (current_time_ns > task->start_boottime) ? (current_time_ns - task->start_boottime) : 0;

            if (elapsed_ns > 0) {
                u64 cpu_perc_x10 = (cpu_time_ns * 1000) / elapsed_ns;
                cpu_perc_int = cpu_perc_x10 / 10;
                cpu_perc_dec = cpu_perc_x10 % 10;
            }

            seq_printf(m, "PID: %-6d | Command: %-16s | ID: %-12.12s | VSZ: %-10lu KB | RSS: %-10lu KB | %%RAM: %lu.%01lu%% | %%CPU: %llu.%01llu%% | Cgroup: %s\n",
                       task->pid, task->comm, container_id, vsz_kb, rss_kb, ram_perc_int, ram_perc_dec, cpu_perc_int, cpu_perc_dec, cgroup_path_buf);
        }
    }
    rcu_read_unlock();

    return 0;
}

/* Connect single_open with the display function */
static int continfo_open(struct inode *inode, struct file *file) {
    return single_open(file, continfo_show, NULL);
}

/* File operations structure for Kernel 5.6+ */
static const struct proc_ops continfo_ops = {
    .proc_open    = continfo_open,
    .proc_read    = seq_read,
    .proc_lseek   = seq_lseek,
    .proc_release = single_release,
};

/* Module initialization function */
static int __init continfo_init(void) {
    /* Create entry in /proc and assign to pointer */
    continfo_entry = proc_create(PROC_NAME, 0444, NULL, &continfo_ops);
    
    /* Verify if the creation failed */
    if (continfo_entry == NULL) {
        pr_err("Error: Could not create /proc/%s entry\n", PROC_NAME);
        return -ENOMEM;
    }

    pr_info("Module %s loaded successfully at /proc/%s\n", PROC_NAME, PROC_NAME);
    return 0;
}

/* Module cleanup function */
static void __exit continfo_exit(void) {
    /* Remove entry from /proc */
    remove_proc_entry(PROC_NAME, NULL);
    pr_info("Module %s unloaded successfully\n", PROC_NAME);
}

module_init(continfo_init);
module_exit(continfo_exit);