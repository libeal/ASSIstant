#!/usr/bin/env bash

set -euo pipefail

linux_agent_detect_topic() {
    local user_input="$1"
    case "${user_input}" in
        *磁盘*|*空间*|*垃圾*|*日志*|*大文件*)
            printf 'disk\n'
            ;;
        *cpu*|*CPU*|*内存*|*memory*|*Memory*|*资源*|*负载*|*load*|*Load*|*top*)
            printf 'resource\n'
            ;;
        *进程*|*僵尸*|*ps*)
            printf 'process\n'
            ;;
        *端口*|*网络*|*连接*)
            printf 'network\n'
            ;;
        *服务*|*systemd*|*重启*)
            printf 'service\n'
            ;;
        *)
            printf 'minimal\n'
            ;;
    esac
}

linux_agent_sense_disk() {
    jq -cn \
        --arg df "$(df -h 2>/dev/null | head -n 8 || true)" \
        --arg var_usage "$(du -xhd 1 /var 2>/dev/null | sort -h | tail -n 5 || true)" \
        --arg big_file_count "$(find /var/log -type f -size +50M 2>/dev/null | wc -l | tr -d ' ' || true)" \
        '{topic:"disk", df_summary:$df, var_usage_summary:$var_usage, large_log_file_count:($big_file_count | tonumber? // 0)}'
}

linux_agent_sense_process() {
    jq -cn \
        --arg top_commands "$(ps -eo comm --sort=-%cpu 2>/dev/null | tail -n +2 | head -n 10 || true)" \
        --arg zombie_count "$(ps -eo stat 2>/dev/null | awk '$1 ~ /Z/ {count++} END {print count + 0}' || true)" \
        '{topic:"process", top_commands:$top_commands, zombie_count:($zombie_count | tonumber? // 0)}'
}

linux_agent_sense_resource() {
    local memory_summary="" top_processes="" load_summary="" cpu_count="" cpu_model=""
    memory_summary="$(free -h 2>/dev/null || true)"
    top_processes="$(ps -eo pid,user,%cpu,%mem,stat,comm --sort=-%cpu 2>/dev/null | head -n 12 || true)"
    load_summary="$(uptime 2>/dev/null || true)"
    cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '0')"
    cpu_model="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

    jq -cn \
        --arg memory_summary "${memory_summary}" \
        --arg top_processes "${top_processes}" \
        --arg load_summary "${load_summary}" \
        --arg cpu_count "${cpu_count}" \
        --arg cpu_model "${cpu_model}" \
        '{topic:"resource", load_summary:$load_summary, cpu_count:($cpu_count | tonumber? // 0), cpu_model:$cpu_model, memory_summary:$memory_summary, top_processes:$top_processes}'
}

linux_agent_sense_network() {
    local ss_output=""
    if command -v ss >/dev/null 2>&1; then
        ss_output="$(ss -tuln 2>/dev/null | awk 'NR > 1 {print $1" "$2" "$5}' | head -n 12 || true)"
    fi

    jq -cn \
        --arg socket_summary "${ss_output}" \
        '{topic:"network", socket_summary:$socket_summary}'
}

linux_agent_sense_logs() {
    local journal_count="0"
    if command -v journalctl >/dev/null 2>&1; then
        journal_count="$(journalctl -p 3 -n 20 --no-pager 2>/dev/null | wc -l | tr -d ' ' || true)"
    fi

    jq -cn \
        --argjson recent_error_lines "${journal_count:-0}" \
        --arg log_file_count "$(find /var/log -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ' || true)" \
        '{topic:"logs", recent_error_lines:$recent_error_lines, log_file_count:($log_file_count | tonumber? // 0)}'
}

linux_agent_sense_services() {
    local services_output=""
    local failed_output=""
    if command -v systemctl >/dev/null 2>&1; then
        services_output="$(systemctl list-units --type=service --no-pager 2>/dev/null | head -n 30 || true)"
        failed_output="$(systemctl --failed --no-pager 2>/dev/null || true)"
    fi

    jq -cn \
        --arg services_summary "${services_output}" \
        --arg failed_summary "${failed_output}" \
        '{topic:"service", services_summary:$services_summary, failed_summary:$failed_summary}'
}

linux_agent_sense_privilege() {
    local sudo_probe="unavailable"
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true >/dev/null 2>&1; then
            sudo_probe="passwordless"
        elif sudo -n -l >/dev/null 2>&1; then
            sudo_probe="interactive"
        else
            sudo_probe="denied"
        fi
    fi

    jq -cn \
        --arg user "$(id -un 2>/dev/null || true)" \
        --arg sudo_probe "${sudo_probe}" \
        '{topic:"privilege", user:$user, sudo_probe:$sudo_probe}'
}

linux_agent_sense_minimal() {
    jq -cn '{topic:"minimal", note:"未识别到具体运维主题，未采集系统遥测。"}'
}

linux_agent_sense_topic() {
    local topic="${1:-all}"
    case "${topic}" in
        disk)
            linux_agent_sense_disk
            ;;
        process)
            linux_agent_sense_process
            ;;
        resource)
            linux_agent_sense_resource
            ;;
        network)
            linux_agent_sense_network
            ;;
        service)
            linux_agent_sense_services
            ;;
        logs)
            linux_agent_sense_logs
            ;;
        privilege)
            linux_agent_sense_privilege
            ;;
        minimal)
            linux_agent_sense_minimal
            ;;
        all|*)
            jq -cn \
                --argjson disk "$(linux_agent_sense_disk)" \
                --argjson process "$(linux_agent_sense_process)" \
                --argjson resource "$(linux_agent_sense_resource)" \
                --argjson network "$(linux_agent_sense_network)" \
                --argjson logs "$(linux_agent_sense_logs)" \
                --argjson service "$(linux_agent_sense_services)" \
                --argjson privilege "$(linux_agent_sense_privilege)" \
                '{disk:$disk, process:$process, resource:$resource, network:$network, logs:$logs, service:$service, privilege:$privilege}'
            ;;
    esac
}
