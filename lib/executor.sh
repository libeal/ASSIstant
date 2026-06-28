#!/usr/bin/env bash

set -euo pipefail

linux_agent_api_read_input_line() {
    return 1
}

linux_agent_api_has_pending_decision_lines() {
    [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] || return 1
    jq -e 'type == "array" and length > 0' <<<"${LINUX_AGENT_API_INPUT_JSON:-[]}" >/dev/null 2>&1
}

linux_agent_probe_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'unavailable\n'
        return 0
    fi

    if sudo -n true >/dev/null 2>&1; then
        printf 'passwordless\n'
    elif sudo -n -l >/dev/null 2>&1; then
        printf 'interactive\n'
    else
        printf 'denied\n'
    fi
}

linux_agent_min_privilege_proxy_enabled() {
    linux_agent_config_bool_default '.execution.min_privilege_proxy' 'true'
}

linux_agent_least_privilege_user() {
    local configured candidate
    configured="$(linux_agent_config_get_default '.execution.least_privilege_user' 'nobody' 2>/dev/null || printf 'nobody')"
    for candidate in "${configured}" nobody nfsnobody daemon; do
        [[ -n "${candidate}" && "${candidate}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] || continue
        if id -u "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

linux_agent_execution_privilege_from_review() {
    local review_json="$1"
    local privileged_finding

    privileged_finding="$(jq -r '
        [(.findings // [])[] | select((.severity == "high" or .severity == "critical") and
            ((.code == "REGEX_WARN")
             or (.code == "PROTECTED_SERVICE")
             or (.code == "PROTECTED_PATH")
             or (.category == "privilege")
             or (.category == "protected_path")
             or (.category == "protected_service")))]
        | length > 0
    ' <<<"${review_json}" 2>/dev/null || printf 'false')"
    if [[ "${privileged_finding}" == "true" ]]; then
        printf 'current\n'
    else
        printf 'least\n'
    fi
}

linux_agent_prepare_execution_command() {
    local requested_privilege="$1"
    local output_var="$2"
    shift 2
    local -n output_command_ref="${output_var}"
    output_command_ref=()

    if [[ "${requested_privilege}" != "least" ]] || [[ "$(linux_agent_min_privilege_proxy_enabled)" != "true" ]]; then
        output_command_ref=("$@")
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        output_command_ref=("$@")
        return 0
    fi

    local target_user target_uid target_gid
    if ! target_user="$(linux_agent_least_privilege_user)"; then
        return 1
    fi

    if command -v runuser >/dev/null 2>&1; then
        output_command_ref=(runuser -u "${target_user}" -- "$@")
        return 0
    fi

    if command -v setpriv >/dev/null 2>&1; then
        target_uid="$(id -u "${target_user}")"
        target_gid="$(id -g "${target_user}")"
        output_command_ref=(setpriv --reuid "${target_uid}" --regid "${target_gid}" --init-groups "$@")
        return 0
    fi

    return 1
}

linux_agent_execution_proxy_metadata() {
    local requested_privilege="$1"
    local prepared_root="$2"
    local error_message="${3:-}"
    local target_user=""
    if [[ "${requested_privilege}" == "least" && "$(id -u)" -eq 0 ]]; then
        target_user="$(linux_agent_least_privilege_user 2>/dev/null || true)"
    fi

    jq -cn \
        --arg requested_privilege "${requested_privilege}" \
        --arg execution_user "$(id -un 2>/dev/null || printf 'unknown')" \
        --arg target_user "${target_user}" \
        --arg prepared_root "${prepared_root}" \
        --arg error "${error_message}" \
        --argjson enabled "$(linux_agent_min_privilege_proxy_enabled)" \
        '{
            enabled:$enabled,
            requested_privilege:$requested_privilege,
            execution_user:$execution_user,
            target_user:(if $target_user == "" then null else $target_user end),
            prepared_root:($prepared_root == "true"),
            error:(if $error == "" then null else $error end)
        }'
}

linux_agent_confirm_execution() {
    local prompt="$1"
    local api_answer=""
    if linux_agent_api_read_input_line api_answer; then
        [[ "${api_answer}" =~ ^[Yy]$ ]]
        return $?
    fi
    printf '%s [y/N]: ' "${prompt}" >&2
    local answer=""
    IFS= read -r answer || true
    [[ "${answer}" =~ ^[Yy]$ ]]
}

linux_agent_auto_execute_low_risk_enabled() {
    linux_agent_config_bool_default '.agent_loop.auto_execute_low_risk' 'true'
}

linux_agent_auto_execute_shell_low_risk_enabled() {
    linux_agent_config_bool_default '.agent_loop.auto_execute_shell_low_risk' 'false'
}

linux_agent_config_bool_with_legacy_default() {
    local key="$1"
    local legacy_key="$2"
    local default_value="$3"
    local value

    value="$(jq -r "${key} // empty" <<<"${LINUX_AGENT_CONFIG_JSON:-{}}" 2>/dev/null || true)"
    if [[ -n "${value}" ]]; then
        case "${value,,}" in
            true|1|yes|on) printf 'true\n' ;;
            *) printf 'false\n' ;;
        esac
        return 0
    fi

    if [[ -n "${legacy_key}" ]]; then
        linux_agent_config_bool_default "${legacy_key}" "${default_value}"
    else
        linux_agent_config_bool_default "${key}" "${default_value}"
    fi
}

linux_agent_auto_approval_enabled() {
    local capability="$1"
    case "${capability}" in
        skill_readonly)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.skill_readonly' '.agent_loop.auto_execute_low_risk' 'true'
            ;;
        shell_readonly)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.shell_readonly' '.agent_loop.auto_execute_shell_low_risk' 'false'
            ;;
        file_match)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.file_match' '' 'true'
            ;;
        file_patch)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.file_patch' '' 'false'
            ;;
        file_download)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.file_download' '' 'false'
            ;;
        local_analyze)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.local_analyze' '' 'true'
            ;;
        remote_script)
            linux_agent_config_bool_with_legacy_default '.approvals.auto.remote_script' '' 'false'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

linux_agent_auto_approval_config_json() {
    jq -cn \
        --argjson skill_readonly "$(linux_agent_auto_approval_enabled skill_readonly)" \
        --argjson shell_readonly "$(linux_agent_auto_approval_enabled shell_readonly)" \
        --argjson file_match "$(linux_agent_auto_approval_enabled file_match)" \
        --argjson file_patch "$(linux_agent_auto_approval_enabled file_patch)" \
        --argjson file_download "$(linux_agent_auto_approval_enabled file_download)" \
        --argjson local_analyze "$(linux_agent_auto_approval_enabled local_analyze)" \
        --argjson remote_script "$(linux_agent_auto_approval_enabled remote_script)" \
        '{
            skill_readonly:$skill_readonly,
            shell_readonly:$shell_readonly,
            file_match:$file_match,
            file_patch:$file_patch,
            file_download:$file_download,
            local_analyze:$local_analyze,
            remote_script:$remote_script
        }'
}

linux_agent_step_auto_approval_capability() {
    local step_json="$1"
    local executor_type ref
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"
    case "${executor_type}" in
        skill_script)
            ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
            case "${ref}" in
                controlled-tools/file-match) printf 'file_match\n' ;;
                controlled-tools/file-patch) printf 'file_patch\n' ;;
                controlled-tools/file-download) printf 'file_download\n' ;;
                controlled-tools/local-analyze) printf 'local_analyze\n' ;;
                *) printf 'skill_readonly\n' ;;
            esac
            ;;
        shell)
            printf 'shell_readonly\n'
            ;;
        remote_script)
            printf 'remote_script\n'
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

linux_agent_should_auto_execute_step() {
    local step_json="$1"
    local review_json="$2"
    local executor_type ref capability

    [[ "$(jq -r '.approved // false' <<<"${review_json}")" == "true" ]] || return 1
    [[ "$(jq -r '.approval_required == false' <<<"${review_json}")" == "true" ]] || return 1
    [[ "$(jq -r '.risk_level // "unknown"' <<<"${review_json}")" == "low" ]] || return 1

    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"
    capability="$(linux_agent_step_auto_approval_capability "${step_json}")"
    [[ "$(linux_agent_auto_approval_enabled "${capability}")" == "true" ]] || return 1
    case "${executor_type}" in
        skill_script)
            ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
            [[ -n "${ref}" ]] && linux_agent_skill_is_registered "${ref}"
            ;;
        shell)
            return 0
            ;;
        remote_script)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

linux_agent_step_arguments_json() {
    local step_json="$1"
    local raw_args

    raw_args="$(jq -c 'if has("arguments") then .arguments else {} end' <<<"${step_json}")"
    linux_agent_normalize_json_object_argument "${raw_args}" || printf '{}\n'
}

linux_agent_prompt_step_decision() {
    local prompt="$1"
    local result_var="$2"
    local answer=""

    while true; do
        if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] && ! linux_agent_api_has_pending_decision_lines; then
            printf -v "${result_var}" '%s' "approval_required"
            return 0
        fi
        if linux_agent_api_read_input_line answer; then
            :
        else
            printf '%s [y/n/s/t]: ' "${prompt}" >&2
            IFS= read -r answer || true
        fi
        case "${answer,,}" in
            y|yes)
                printf -v "${result_var}" '%s' "approve"
                return 0
                ;;
            n|no|"")
                printf -v "${result_var}" '%s' "reject"
                return 0
                ;;
            s|skip)
                printf -v "${result_var}" '%s' "skip"
                return 0
                ;;
            t|terminate)
                printf -v "${result_var}" '%s' "terminate"
                return 0
                ;;
            approval_required)
                printf -v "${result_var}" '%s' "approval_required"
                return 0
                ;;
            *)
                if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]]; then
                    printf -v "${result_var}" '%s' "reject"
                    return 0
                fi
                printf '请输入 y 执行、n 拒绝、s 跳过/修改、t 终止。\n' >&2
                ;;
        esac
    done
}

linux_agent_prompt_revision_request() {
    local prompt="$1"
    local result_var="$2"
    local request=""

    if linux_agent_api_read_input_line request; then
        printf -v "${result_var}" '%s' "${request}"
        return 0
    fi
    printf '%s' "${prompt}" >&2
    IFS= read -r request || true
    printf -v "${result_var}" '%s' "${request}"
}

linux_agent_print_work_plan() {
    local plan_json="$1"
    printf '\n# 工作计划\n\n'
    printf '%s\n\n' "$(jq -r '.summary' <<<"${plan_json}")"
    jq -r '.steps[]? | "- \(.id): \(.title) [\(.executor_type), risk=\(.risk_level)]\n  预测: \(.expected_effect)"' <<<"${plan_json}"
    printf '\n'
}

linux_agent_print_step_for_approval() {
    local step_json="$1"
    printf '\n## 当前步骤: %s\n' "$(jq -r '.title' <<<"${step_json}")"
    printf 'ID: %s\n' "$(jq -r '.id' <<<"${step_json}")"
    printf '执行器: %s\n' "$(jq -r '.executor_type' <<<"${step_json}")"
    printf '风险: %s\n' "$(jq -r '.risk_level' <<<"${step_json}")"
    printf '理由: %s\n' "$(jq -r '.reason' <<<"${step_json}")"
    printf '预测效果: %s\n' "$(jq -r '.expected_effect' <<<"${step_json}")"
    case "$(jq -r '.executor_type' <<<"${step_json}")" in
        skill_script)
            printf '脚本: %s\n' "$(jq -r '.skill_script' <<<"${step_json}")"
            printf '参数: %s\n' "$(linux_agent_step_arguments_json "${step_json}")"
            ;;
        shell)
            printf '命令: %s\n' "$(jq -r '.command' <<<"${step_json}")"
            ;;
        remote_script)
            printf '远程脚本: %s\n' "$(jq -r '.url // .command // empty' <<<"${step_json}")"
            printf '参数: %s\n' "$(linux_agent_step_arguments_json "${step_json}")"
            if [[ "$(jq -r 'has("sha256")' <<<"${step_json}")" == "true" ]]; then
                printf 'sha256: %s\n' "$(jq -r '.sha256' <<<"${step_json}")"
                printf '大小: %s bytes\n' "$(jq -r '.size_bytes' <<<"${step_json}")"
                printf '行数: %s\n' "$(jq -r '.line_count' <<<"${step_json}")"
                printf '脚本预览（前 40 行，已脱敏）:\n%s\n' "$(jq -r '.preview // ""' <<<"${step_json}")"
            fi
            ;;
    esac
}

linux_agent_print_execution_result_summary() {
    local result_json="$1"
    local title="${2:-执行结果}"
    jq -r --arg title "${title}" '
        $title + ": "
        + (if (.ok // false) then "成功" else "失败" end)
        + "，exit_code="
        + ((.exit_code // "unknown") | tostring)
    ' <<<"${result_json}" >&2
}

linux_agent_print_step_result_summary() {
    linux_agent_print_execution_result_summary "$1" "步骤执行结果"
}

linux_agent_output_json_enabled() {
    [[ "${LINUX_AGENT_OUTPUT_JSON:-0}" == "1" ]]
}

linux_agent_user_output_label() {
    local key="$1"
    case "${key}" in
        status) printf '服务状态' ;;
        failed) printf '失败服务' ;;
        load) printf '系统负载' ;;
        memory) printf '内存' ;;
        top_processes) printf '高占用进程' ;;
        disk_usage) printf '磁盘使用' ;;
        top_dirs) printf '目录占用' ;;
        top_files) printf '大文件' ;;
        processes) printf '进程列表' ;;
        zombies) printf '僵尸进程' ;;
        error) printf '错误' ;;
        path|root_path|resolved_path) printf '路径' ;;
        service) printf '服务' ;;
        pattern) printf '匹配条件' ;;
        keyword) printf '关键字' ;;
        matches) printf '匹配结果' ;;
        journal_sample) printf 'Journal 样本' ;;
        candidates) printf '候选项' ;;
        rejected) printf '已排除项' ;;
        summary) printf '摘要' ;;
        archive) printf '备份文件' ;;
        stat) printf '文件状态' ;;
        action) printf '动作' ;;
        reason) printf '原因' ;;
        message) printf '消息' ;;
        reverse_dependencies) printf '反向依赖' ;;
        next_step) printf '下一步' ;;
        cpu_count) printf 'CPU 核心数' ;;
        cpu_model) printf 'CPU 型号' ;;
        min_size_mb) printf '最小大小 MB' ;;
        include_journal) printf '包含 Journal' ;;
        size_bytes) printf '大小 bytes' ;;
        threshold_bytes) printf '阈值 bytes' ;;
        previous_size_bytes) printf '清理前大小 bytes' ;;
        *)
            printf '%s' "${key//_/ }"
            ;;
    esac
}

linux_agent_print_user_output() {
    local result_json="$1"
    local title="${2:-步骤输出}"
    local output_fd="${LINUX_AGENT_USER_OUTPUT_FD:-2}"
    local payload payload_type raw entry key value_type label printed

    if ! printf '%s' "${result_json}" | jq -e . >/dev/null 2>&1; then
        [[ -n "${result_json}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${result_json}" >&"${output_fd}"
        return 0
    fi

    if [[ "$(jq -r 'if type == "object" and has("output") then "yes" else "no" end' <<<"${result_json}")" == "yes" ]]; then
        payload="$(jq -c '.output' <<<"${result_json}")"
    else
        payload="$(jq -c '.' <<<"${result_json}")"
    fi

    payload_type="$(jq -r 'type' <<<"${payload}")"
    if [[ "${payload_type}" == "null" ]]; then
        return 0
    fi

    if [[ "${payload_type}" == "object" && "$(jq -r 'has("raw")' <<<"${payload}")" == "true" ]]; then
        raw="$(jq -r '.raw // empty' <<<"${payload}")"
        [[ -n "${raw}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${raw}" >&"${output_fd}"
        return 0
    fi

    if [[ "${payload_type}" == "string" ]]; then
        raw="$(jq -r '.' <<<"${payload}")"
        [[ -n "${raw}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${raw}" >&"${output_fd}"
        return 0
    fi

    if [[ "${payload_type}" != "object" ]]; then
        printf '%s:\n' "${title}" >&"${output_fd}"
        jq . <<<"${payload}" >&"${output_fd}"
        return 0
    fi

    printed=0
    while IFS= read -r entry; do
        key="$(jq -r '.key' <<<"${entry}")"
        value_type="$(jq -r '.value | type' <<<"${entry}")"
        label="$(linux_agent_user_output_label "${key}")"
        if [[ "${printed}" -eq 0 ]]; then
            printf '%s:\n' "${title}" >&"${output_fd}"
            printed=1
        else
            printf '\n' >&"${output_fd}"
        fi

        if [[ "${value_type}" == "string" ]]; then
            printf '%s:\n' "${label}" >&"${output_fd}"
            jq -r '.value' <<<"${entry}" >&"${output_fd}"
        elif [[ "${value_type}" == "number" || "${value_type}" == "boolean" ]]; then
            printf '%s: %s\n' "${label}" "$(jq -r '.value | tostring' <<<"${entry}")" >&"${output_fd}"
        else
            printf '%s:\n' "${label}" >&"${output_fd}"
            jq '.value' <<<"${entry}" >&"${output_fd}"
        fi
    done < <(jq -c '
        def visible:
            if . == null then false
            elif type == "string" then length > 0
            elif type == "array" then length > 0
            elif type == "object" then length > 0
            else true end;
        with_entries(select((.key != "ok" and .key != "tool") and (.value | visible)))
        | to_entries[]
    ' <<<"${payload}")
}

linux_agent_print_step_output_preview() {
    linux_agent_print_user_output "$1" "步骤输出"
}

linux_agent_print_script_result() {
    local result_json="$1"
    local status_label render_json

    if [[ "$(jq -r '.ok // false' <<<"${result_json}")" == "true" ]]; then
        status_label="成功"
    else
        status_label="失败"
    fi

    if jq -e 'has("status")' <<<"${result_json}" >/dev/null 2>&1; then
        printf '脚本状态: %s\n' "$(jq -r '.status' <<<"${result_json}")"
    else
        printf '脚本执行结果: %s\n' "${status_label}"
    fi
    render_json="$(jq -c 'if type == "object" then del(.status) else . end' <<<"${result_json}")"
    LINUX_AGENT_USER_OUTPUT_FD=1 linux_agent_print_user_output "${render_json}" "脚本输出"
}

linux_agent_print_terminal_stream() {
    local title="$1"
    local text="$2"
    local render_json
    [[ -n "${text}" ]] || return 0

    if printf '%s' "${text}" | jq -e . >/dev/null 2>&1; then
        render_json="$(jq -c . <<<"${text}")"
    else
        render_json="$(jq -cn --arg raw "${text}" '{output:{raw:$raw}}')"
    fi
    LINUX_AGENT_USER_OUTPUT_FD=1 linux_agent_print_user_output "${render_json}" "${title}"
}

linux_agent_print_terminal_result() {
    local result_json="$1"
    local stdout_text stderr_text

    linux_agent_print_execution_result_summary "${result_json}" "终端执行结果"
    stdout_text="$(jq -r '.stdout // empty' <<<"${result_json}")"
    stderr_text="$(jq -r '.stderr // empty' <<<"${result_json}")"
    linux_agent_print_terminal_stream "终端输出" "${stdout_text}"
    linux_agent_print_terminal_stream "终端错误" "${stderr_text}"
}

linux_agent_terminal_review() {
    local command_text="$1"
    linux_agent_policy_review_text "terminal" "${command_text}"
}

linux_agent_print_work_execution_status() {
    local execution_json="$1"
    jq -r '
        "工作流执行完成: status=" + (.status // "unknown")
        + "，steps=" + ((.results // []) | length | tostring)
    ' <<<"${execution_json}"
}

linux_agent_compact_execution_result() {
    local execution_json="$1"
    jq -c '
        {
            status,
            execution_user,
            sudo_probe,
            findings,
            review,
            approval_step,
            iterations,
            auto_executed_count,
            final_answer,
            checkpoint_required,
            stopped_reason,
            results:[
                .results[]? | {
                    step:{
                        id:.step.id,
                        title:.step.title,
                        executor_type:.step.executor_type,
                        risk_level:(.step.risk_level // null),
                        skill_script:(.step.skill_script // null),
                        command:(.step.command // null)
                    },
                    result:{
                        ok:(.result.ok // false),
                        status:(.result.status // null),
                        exit_code:(.result.exit_code // null),
                        tool:(.result.output.tool // null),
                        action:(.result.output.action // null),
                        output:(.result.output // null),
                        auto_approved:(.result.auto_approved // false),
                        execution_proxy:(.result.execution_proxy // null),
                        observer:(.result.observer // null)
                    }
                }
            ]
        }
    ' <<<"${execution_json}"
}

linux_agent_download_remote_script() {
    local url="$1"
    local output_path="$2"
    curl -fsSL --max-time 30 "${url}" -o "${output_path}"
}

linux_agent_remote_script_policy() {
    local policy
    policy="$(linux_agent_config_get_default '.remote_script_policy' 'download_review')"
    case "${policy}" in
        download_review|disabled)
            printf '%s\n' "${policy}"
            ;;
        *)
            printf 'download_review\n'
            ;;
    esac
}

linux_agent_step_review_material() {
    local step_json="$1"
    local executor_type
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"

    case "${executor_type}" in
        skill_script)
            local ref args content
            ref="$(jq -r '.skill_script' <<<"${step_json}")"
            args="$(linux_agent_step_arguments_json "${step_json}")"
            content="$(linux_agent_skill_script_content "${ref}" 2>/dev/null || true)"
            printf 'skill_script=%s\narguments=%s\n%s\n' "${ref}" "${args}" "${content}"
            ;;
        shell)
            jq -r '.command // empty' <<<"${step_json}"
            ;;
        remote_script)
            jq -r '.downloaded_path // empty' <<<"${step_json}" | while IFS= read -r downloaded_path; do
                if [[ -n "${downloaded_path}" && -f "${downloaded_path}" ]]; then
                    cat "${downloaded_path}"
                fi
            done
            ;;
        *)
            printf ''
            ;;
    esac
}

linux_agent_prepare_remote_step() {
    local step_json="$1"
    local url tmp_path sha size line_count preview raw_preview policy
    policy="$(linux_agent_remote_script_policy)"
    if [[ "${policy}" == "disabled" ]]; then
        jq -cn --arg error "远程脚本策略已禁用。" '{ok:false, error:$error}'
        return 1
    fi

    url="$(jq -r '.url // .command // empty' <<<"${step_json}")"
    if [[ -z "${url}" || ! "${url}" =~ ^https:// ]]; then
        jq -cn --arg error "远程脚本必须提供 https URL。" --arg url "${url}" '{ok:false, error:$error, url:$url}'
        return 1
    fi

    tmp_path="${LINUX_AGENT_TMP_DIR}/remote_$(date +%Y%m%d_%H%M%S)_${RANDOM}.sh"
    if ! linux_agent_download_remote_script "${url}" "${tmp_path}"; then
        jq -cn --arg error "远程脚本下载失败。" --arg url "${url}" '{ok:false, error:$error, url:$url}'
        return 1
    fi
    sha="$(sha256sum "${tmp_path}" | awk '{print $1}')"
    size="$(wc -c < "${tmp_path}" | tr -d ' ')"
    if [[ ! "${size}" =~ ^[0-9]+$ || "${size}" -eq 0 ]]; then
        jq -cn --arg error "远程脚本为空。" --arg url "${url}" --arg sha256 "${sha}" '{ok:false, error:$error, url:$url, sha256:$sha256}'
        return 1
    fi
    if [[ "${size}" -gt 262144 ]]; then
        jq -cn --arg error "远程脚本超过 256KB 限制。" --arg url "${url}" --arg sha256 "${sha}" --argjson size "${size}" \
            '{ok:false, error:$error, url:$url, sha256:$sha256, size_bytes:$size}'
        return 1
    fi
    if ! grep -Iq . "${tmp_path}"; then
        jq -cn --arg error "远程脚本不是文本内容。" --arg url "${url}" --arg sha256 "${sha}" --argjson size "${size}" \
            '{ok:false, error:$error, url:$url, sha256:$sha256, size_bytes:$size}'
        return 1
    fi

    line_count="$(awk 'END {print NR + 0}' "${tmp_path}")"
    raw_preview="$(head -n 40 "${tmp_path}")"
    preview="$(linux_agent_sanitize_text "${raw_preview}" 4000)"
    jq -c \
        --arg path "${tmp_path}" \
        --arg sha256 "${sha}" \
        --arg preview "${preview}" \
        --argjson size "${size}" \
        --argjson line_count "${line_count:-0}" \
        '. + {
            downloaded_path:$path,
            sha256:$sha256,
            size_bytes:$size,
            line_count:$line_count,
            preview:$preview,
            risk_level:(if .risk_level == "critical" then "critical" else "high" end)
        }' <<<"${step_json}"
}

linux_agent_execute_observed_command_output() {
    local scope="$1"
    local subject_json="$2"
    shift 2
    [[ "${1:-}" == "--" ]] && shift

    local stdout_file stderr_file run_meta exit_code observer stdout_text stderr_text combined
    local requested_privilege proxy_meta proxy_error
    local -a prepared_command

    requested_privilege="${LINUX_AGENT_EXECUTION_PRIVILEGE:-least}"
    if ! linux_agent_prepare_execution_command "${requested_privilege}" prepared_command "$@"; then
        proxy_error="least privilege proxy is unavailable; refusing to run as root without an explicit privileged path"
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "false" "${proxy_error}")"
        jq -cn \
            --arg output "${proxy_error}" \
            --argjson proxy "${proxy_meta}" \
            '{ok:false, exit_code:126, output:{raw:$output}, execution_proxy:$proxy}'
        return 0
    fi
    if [[ "${requested_privilege}" == "least" && "$(id -u)" -eq 0 ]]; then
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "true")"
    else
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "false")"
    fi

    stdout_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/observer.stdout.XXXXXX")"
    stderr_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/observer.stderr.XXXXXX")"

    run_meta="$(linux_agent_run_observed_process "${scope}" "${subject_json}" "${stdout_file}" "${stderr_file}" -- "${prepared_command[@]}")"
    exit_code="$(jq -r '.exit_code' <<<"${run_meta}")"
    observer="$(jq -c '.observer' <<<"${run_meta}")"
    stdout_text="$(cat "${stdout_file}" 2>/dev/null || true)"
    stderr_text="$(cat "${stderr_file}" 2>/dev/null || true)"
    rm -f "${stdout_file}" "${stderr_file}"

    combined="${stdout_text}"
    if [[ -n "${stderr_text}" ]]; then
        if [[ -n "${combined}" ]]; then
            combined="${combined}"$'\n'"${stderr_text}"
        else
            combined="${stderr_text}"
        fi
    fi

    if printf '%s' "${combined}" | jq -e . >/dev/null 2>&1; then
        jq -cn \
            --argjson output "$(printf '%s' "${combined}" | jq -c .)" \
            --argjson exit_code "${exit_code}" \
            --argjson observer "${observer}" \
            --argjson proxy "${proxy_meta}" \
            '{ok:($exit_code == 0), exit_code:$exit_code, output:$output, observer:$observer, execution_proxy:$proxy}'
    else
        jq -cn \
            --arg output "${combined}" \
            --argjson exit_code "${exit_code}" \
            --argjson observer "${observer}" \
            --argjson proxy "${proxy_meta}" \
            '{ok:($exit_code == 0), exit_code:$exit_code, output:{raw:$output}, observer:$observer, execution_proxy:$proxy}'
    fi
}

linux_agent_execute_step_command() {
    local step_json="$1"
    local review_json="${2:-}"
    local executor_type subject
    local -a command_args
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"

    case "${executor_type}" in
        skill_script)
            local ref script_path args
            ref="$(jq -r '.skill_script' <<<"${step_json}")"
            script_path="$(linux_agent_skill_script_path "${ref}")"
            args="$(linux_agent_step_arguments_json "${step_json}")"
            command_args=(bash "${script_path}" "${args}")
            ;;
        shell)
            command_args=(bash -lc "$(jq -r '.command // empty' <<<"${step_json}")")
            ;;
        remote_script)
            command_args=(bash "$(jq -r '.downloaded_path' <<<"${step_json}")" "$(linux_agent_step_arguments_json "${step_json}")")
            ;;
        *)
            jq -cn --arg executor_type "${executor_type}" \
                '{ok:false, exit_code:2, output:{raw:("unsupported executor_type: " + $executor_type)}}'
            return 0
            ;;
    esac

    subject="$(jq -cn --argjson step "${step_json}" '{kind:"work_step", step:$step}')"
    LINUX_AGENT_EXECUTION_PRIVILEGE="$(linux_agent_execution_privilege_from_review "${review_json:-{}}")" \
        linux_agent_execute_observed_command_output "step_${executor_type}" "${subject}" -- "${command_args[@]}"
}

linux_agent_skipped_steps_after() {
    local plan_json="$1"
    local index="$2"
    jq -c --argjson index "${index}" '.steps[($index + 1):] // []' <<<"${plan_json}"
}

linux_agent_request_repair_plan() {
    local user_input="$1"
    local plan_json="$2"
    local executed_steps="$3"
    local failed_step="$4"
    local failed_result="$5"
    local skipped_steps="$6"
    local failure_context repair

    failure_context="$(jq -cn \
        --arg input "${user_input}" \
        --argjson plan "${plan_json}" \
        --argjson executed_steps "${executed_steps}" \
        --argjson failed_step "${failed_step}" \
        --argjson failed_result "${failed_result}" \
        --argjson skipped_steps "${skipped_steps}" \
        '
        def step_summary($s): {
            id:($s.id // null),
            title:($s.title // null),
            executor_type:($s.executor_type // null),
            skill_script:($s.skill_script // null),
            risk_level:($s.risk_level // null),
            has_command:($s | has("command")),
            url:($s.url // null),
            sha256:($s.sha256 // null),
            size_bytes:($s.size_bytes // null)
        };
        def result_summary($r): {
            ok:($r.ok // null),
            exit_code:($r.exit_code // null),
            tool:($r.output.tool // null),
            action:($r.output.action // null),
            output_keys:(if ($r.output? | type) == "object" then ($r.output | keys) else [] end)
        };
        {
            current_request:$input,
            plan:{summary:($plan.summary // ""), step_count:(($plan.steps // []) | length), steps:[($plan.steps // [])[] | step_summary(.)]},
            executed_steps:[($executed_steps // [])[] | {step:step_summary(.step), result:result_summary(.result)}],
            failed_step:step_summary($failed_step),
            failed_result:result_summary($failed_result),
            skipped_steps:[($skipped_steps // [])[] | step_summary(.)]
        }')"
    failure_context="$(linux_agent_sanitize_json "${failure_context}")"

    linux_agent_record_ai_request_files "${failure_context}"
    repair="$(linux_agent_call_ai_with_context "生成回滚或报错解决方案" "${failure_context}" "repair")"
    repair="$(linux_agent_normalize_model_response "${repair}")"
    if linux_agent_ai_response_is_error "${repair}"; then
        linux_agent_log_event "repair_failed" "${repair}"
        printf '\n# 回滚或修复建议\n' >&2
        printf '无法生成修复建议: %s\n' "$(linux_agent_ai_error_text "${repair}")" >&2
        return 0
    fi
    if ! linux_agent_validate_work_response "${repair}" || [[ "$(jq -r '.response_type // empty' <<<"${repair}")" != "work_plan" ]]; then
        linux_agent_log_event "repair_invalid_response" "${repair}"
        printf '\n# 回滚或修复建议\n' >&2
        printf '无法生成修复建议: 模型响应不符合 work_plan schema。\n' >&2
        return 0
    fi
    linux_agent_log_event "repair_planned" "${repair}"
    printf '\n# 回滚或修复建议（不会自动执行）\n' >&2
    printf '%s\n' "$(jq . <<<"${repair}")" >&2
}

linux_agent_request_revised_work_plan() {
    local user_input="$1"
    local plan_json="$2"
    local executed_steps="$3"
    local current_step="$4"
    local revision_request="$5"
    local remaining_steps="$6"
    local revision_context request_context revised_plan

    revision_context="$(jq -cn \
        --arg input "${user_input}" \
        --arg revision_request "${revision_request}" \
        --argjson plan "${plan_json}" \
        --argjson executed_steps "${executed_steps}" \
        --argjson current_step "${current_step}" \
        --argjson remaining_steps "${remaining_steps}" \
        '{
            work_revision:true,
            original_request:$input,
            revision_request:$revision_request,
            plan:{summary:($plan.summary // ""), step_count:(($plan.steps // []) | length), steps:($plan.steps // [])},
            executed_steps:($executed_steps // []),
            skipped_step:$current_step,
            remaining_steps:($remaining_steps // [])
        }')"
    request_context="$(jq -cn \
        --arg mode "work_revision" \
        --arg current_request "${revision_request}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request
        }')"

    linux_agent_log_event "work_revision_requested" "${revision_context}"
    linux_agent_record_ai_request_files "${request_context}"
    revised_plan="$(linux_agent_call_ai_with_context "${revision_request}" "${request_context}" "work_plan" "${revision_context}")"
    revised_plan="$(linux_agent_normalize_model_response "${revised_plan}")"
    if ! linux_agent_validate_work_response "${revised_plan}" || [[ "$(jq -r '.response_type // empty' <<<"${revised_plan}")" != "work_plan" ]]; then
        jq -cn --arg error "模型未返回可执行的续写工作计划。" --argjson raw "${revised_plan}" \
            '{ok:false, error:$error, raw:$raw}'
        return 1
    fi

    linux_agent_log_event "revision_planned" "${revised_plan}"
    printf '\n# 根据修改需求生成续写计划\n' >&2
    printf '%s\n' "$(jq . <<<"${revised_plan}")" >&2
    printf '%s\n' "${revised_plan}"
}

linux_agent_execute_work_plan() {
    local plan_json="$1"
    local user_input="$2"
    local execution_user sudo_probe step_count results executed_steps status

    execution_user="$(id -un 2>/dev/null || printf 'unknown')"
    sudo_probe="$(linux_agent_probe_sudo)"
    step_count="$(jq '.steps | length' <<<"${plan_json}")"
    results='[]'
    executed_steps='[]'
    status="executed"

    linux_agent_print_work_plan "${plan_json}" >&2

    local i=0
    while [[ "${i}" -lt "${step_count}" ]]; do
        local step step_review_text review result skipped prepared step_decision revision_request auto_approved
        step="$(jq -c --argjson index "${i}" '.steps[$index]' <<<"${plan_json}")"
        auto_approved=0
        linux_agent_log_step_status "${step}" "pending"

        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "remote_script" ]]; then
            prepared="$(linux_agent_prepare_remote_step "${step}" 2>&1)" || {
                local failed_detail skipped_steps
                failed_detail="$(jq -cn --arg raw "${prepared}" '{ok:false, output:{raw:$raw}}')"
                linux_agent_log_step_status "${step}" "failed" "${failed_detail}"
                skipped_steps="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped; do
                    [[ -n "${skipped}" ]] && linux_agent_log_step_status "${skipped}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped_steps}")
                linux_agent_request_repair_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${failed_detail}" "${skipped_steps}"
                jq -cn --arg status "failed" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
                return 0
            }
            step="${prepared}"
            printf '远程脚本已下载: %s\nsha256: %s\nsize: %s bytes\n' \
                "$(jq -r '.downloaded_path' <<<"${step}")" \
                "$(jq -r '.sha256' <<<"${step}")" \
                "$(jq -r '.size_bytes' <<<"${step}")" >&2
        fi

        linux_agent_print_step_for_approval "${step}" >&2
        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "skill_script" ]] && ! linux_agent_skill_is_registered "$(jq -r '.skill_script' <<<"${step}")"; then
            local blocked_detail skipped_steps
            blocked_detail="$(jq -cn --arg ref "$(jq -r '.skill_script' <<<"${step}")" '{approved:false, risk_level:"critical", findings:[{severity:"critical", code:"SKILL_SCRIPT_UNREGISTERED", ref:$ref, message:"AI 提出的 skill 脚本未登记。"}]}')"
            linux_agent_log_step_status "${step}" "blocked" "${blocked_detail}"
            skipped_steps="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped_steps}")
            jq -cn --arg status "blocked" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${blocked_detail}")" --argjson results "${results}" \
                '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}'
            return 0
        fi
        step_review_text="$(linux_agent_step_review_material "${step}")"
        review="$(linux_agent_policy_review_step "${step}" "${step_review_text}" "$(if [[ "$(jq -r '.executor_type' <<<"${step}")" == "remote_script" ]]; then printf 'remote'; else printf 'local'; fi)")"
        linux_agent_log_event "step_policy_checked" "$(jq -cn --argjson step "${step}" --argjson review "${review}" '{step:$step, review:$review}')"

        if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
            linux_agent_log_step_status "${step}" "blocked" "${review}"
            skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped}")
            jq -cn --arg status "blocked" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${review}")" --argjson results "${results}" \
                '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}'
            return 0
        fi

        if [[ "$(jq -r '.approval_required' <<<"${review}")" == "true" ]]; then
            printf '审查风险: %s，发现项: %s\n' "$(jq -r '.risk_level' <<<"${review}")" "$(jq '.findings | length' <<<"${review}")" >&2
        fi
        if linux_agent_should_auto_execute_step "${step}" "${review}" && ! linux_agent_api_has_pending_decision_lines; then
            step_decision="approve"
            auto_approved=1
            linux_agent_log_step_status "${step}" "auto_approved" "${review}"
            printf '低风险步骤已自动批准执行: %s\n' "$(jq -r '.title' <<<"${step}")" >&2
        else
            linux_agent_prompt_step_decision "批准执行该步骤？" step_decision
        fi
        case "${step_decision}" in
            approval_required)
                linux_agent_log_step_status "${step}" "approval_required" "${review}"
                jq -cn \
                    --arg status "approval_required" \
                    --arg execution_user "${execution_user}" \
                    --arg sudo_probe "${sudo_probe}" \
                    --argjson approval_step "${step}" \
                    --argjson review "${review}" \
                    --argjson results "${results}" \
                    '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, approval_step:$approval_step, review:$review, results:$results}'
                return 0
                ;;
            reject)
                linux_agent_log_step_status "${step}" "rejected"
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")
                jq -cn --arg status "rejected" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
                return 0
                ;;
            terminate)
                linux_agent_log_step_status "${step}" "terminated"
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")
                jq -cn --arg status "terminated" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
                return 0
                ;;
            skip)
                linux_agent_prompt_revision_request "请输入修改需求（直接回车则跳过当前步骤并继续）: " revision_request
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                if [[ -z "${revision_request}" ]]; then
                    result="$(jq -cn '{ok:true, status:"skipped", exit_code:null, output:{action:"skipped_by_user", message:"用户跳过当前步骤。"}}')"
                    linux_agent_log_step_status "${step}" "skipped_user" "${result}"
                    results="$(jq -cn --argjson prior "${results}" --argjson step "${step}" --argjson result "${result}" '$prior + [{step:$step, result:$result}]')"
                    printf '已跳过当前步骤，继续执行后续步骤。\n' >&2
                    i=$((i + 1))
                    continue
                fi

                local revision_detail revised_plan revised_execution combined_results
                revision_detail="$(jq -cn \
                    --arg revision_request "${revision_request}" \
                    --argjson remaining_steps "${skipped}" \
                    '{ok:true, status:"revision_requested", revision_request:$revision_request, remaining_step_count:($remaining_steps | length)}')"
                linux_agent_log_step_status "${step}" "revision_requested" "${revision_detail}"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")

                if ! revised_plan="$(linux_agent_request_revised_work_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${revision_request}" "${skipped}")"; then
                    result="$(jq -cn --arg error "${revised_plan}" '{ok:false, status:"revision_failed", output:{raw:$error}}')"
                    linux_agent_log_step_status "${step}" "failed" "${result}"
                    jq -cn --arg status "revision_failed" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                        '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
                    return 0
                fi
                revised_execution="$(linux_agent_execute_work_plan "${revised_plan}" "${user_input}")"
                combined_results="$(jq -cn --argjson prior "${results}" --argjson next "$(jq '.results // []' <<<"${revised_execution}")" '$prior + $next')"
                jq -c --argjson results "${combined_results}" '.results = $results' <<<"${revised_execution}"
                return 0
                ;;
        esac

        linux_agent_log_step_status "${step}" "approved"
        linux_agent_log_step_status "${step}" "running"
        result="$(linux_agent_execute_step_command "${step}" "${review}")"
        if [[ "${auto_approved}" -eq 1 ]]; then
            result="$(jq -c '. + {auto_approved:true}' <<<"${result}")"
        fi
        results="$(jq -cn --argjson prior "${results}" --argjson step "${step}" --argjson result "${result}" '$prior + [{step:$step, result:$result}]')"

        if [[ "$(jq -r '.ok' <<<"${result}")" == "true" ]]; then
            linux_agent_log_step_status "${step}" "succeeded" "${result}"
            executed_steps="$(jq -cn --argjson prior "${executed_steps}" --argjson step "${step}" --argjson result "${result}" '$prior + [{step:$step, result:$result}]')"
            linux_agent_print_step_result_summary "${result}"
            linux_agent_print_step_output_preview "${result}"
        else
            status="failed"
            linux_agent_log_step_status "${step}" "failed" "${result}"
            linux_agent_print_step_result_summary "${result}"
            linux_agent_print_step_output_preview "${result}"
            skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped}")
            linux_agent_request_repair_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${result}" "${skipped}"
            jq -cn --arg status "${status}" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
            return 0
        fi

        i=$((i + 1))
    done

    jq -cn --arg status "${status}" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
        '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}'
}
