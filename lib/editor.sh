#!/usr/bin/env bash

set -euo pipefail

linux_agent_render_skill_md() {
    local edit_json="$1" skill_name description scripts_json references_json assets_json
    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    description="$(jq -r '.skill.description' <<<"${edit_json}")"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    references_json="$(jq -c '.references' <<<"${edit_json}")"
    assets_json="$(jq -c '.assets' <<<"${edit_json}")"

    {
        printf -- '---\n'
        printf 'name: %s\n' "${skill_name}"
        printf 'description: %s\n' "$(jq -Rn --arg value "${description}" '$value | tojson')"
        printf -- '---\n\n'
        printf '# %s\n\n' "${skill_name}"
        printf '%s\n' "${description}"
        if [[ "$(jq 'length' <<<"${scripts_json}")" -gt 0 ]]; then
            printf '\n## Scripts\n\n'
            jq -r '.[] | "- `scripts/\(.name)`: \(.description)"' <<<"${scripts_json}"
            printf '\n每个脚本接收一个 JSON object 字符串作为唯一位置参数，并向 stdout 输出一个 JSON object。\n'
        fi
        if [[ "$(jq 'length' <<<"${references_json}")" -gt 0 ]]; then
            printf '\n## References\n\n'
            jq -r '.[] | "- 按需读取 `references/\(.path)`。"' <<<"${references_json}"
        fi
        if [[ "$(jq 'length' <<<"${assets_json}")" -gt 0 ]]; then
            printf '\n## Assets\n\n'
            jq -r '.[] | "- 输出需要时使用 `assets/\(.path)`。"' <<<"${assets_json}"
        fi
    }
}

linux_agent_render_user_skill_extension() {
    local scripts_json="$1" items='[]' script file_name tool_name content description review risk
    while IFS= read -r script; do
        [[ -n "${script}" ]] || continue
        file_name="$(jq -r '.name' <<<"${script}")"
        tool_name="${file_name%.sh}"
        content="$(jq -r '.content' <<<"${script}")"
        description="$(jq -r '.description' <<<"${script}")"
        review="$(linux_agent_policy_review_text "edit:${tool_name}" "${content}")"
        risk="$(jq -r '.risk_level // "critical"' <<<"${review}")"
        linux_agent_risk_is_valid "${risk}" || risk="critical"
        items="$(jq -cn \
            --argjson prior "${items}" \
            --arg name "${tool_name}" \
            --arg description "${description}" \
            --arg entrypoint "scripts/${file_name}" \
            --arg risk "${risk}" \
            '$prior + [{
                name:$name,
                description:$description,
                entrypoint:$entrypoint,
                risk:$risk,
                approval_scope:"skill_readonly",
                execution:{class:"runner",capability:"",dispatch:"always"},
                runtime_inputs:[],
                guards:[]
            }]')"
    done < <(jq -c '.[]' <<<"${scripts_json}")
    jq -S -n --argjson tools "${items}" '{
        schema_version:1,
        package_version:"1.0.0",
        core_api:1,
        category:"custom",
        tools:$tools,
        components:{}
    }'
}

linux_agent_write_edit_resources() {
    local edit_json="$1" staging_skill_dir="$2" group item relative content target
    mkdir -p "${staging_skill_dir}/scripts" "${staging_skill_dir}/references" "${staging_skill_dir}/assets"
    for group in scripts references assets; do
        while IFS= read -r item; do
            [[ -n "${item}" ]] || continue
            if [[ "${group}" == "scripts" ]]; then
                relative="$(jq -r '.name' <<<"${item}")"
            else
                relative="$(jq -r '.path' <<<"${item}")"
            fi
            content="$(jq -r '.content' <<<"${item}")"
            target="${staging_skill_dir}/${group}/${relative}"
            mkdir -p "$(dirname -- "${target}")"
            printf '%s' "${content}" >"${target}"
            if [[ "${group}" == "scripts" ]]; then
                chmod 0750 "${target}"
            else
                chmod 0640 "${target}"
            fi
        done < <(jq -c ".${group}[]" <<<"${edit_json}")
    done
    linux_agent_render_skill_md "${edit_json}" >"${staging_skill_dir}/SKILL.md"
    chmod 0640 "${staging_skill_dir}/SKILL.md"
    if [[ "$(jq '.scripts | length' <<<"${edit_json}")" -gt 0 ]]; then
        linux_agent_render_user_skill_extension "$(jq -c '.scripts' <<<"${edit_json}")" \
            >"${staging_skill_dir}/linux-agent.json"
        chmod 0640 "${staging_skill_dir}/linux-agent.json"
    fi
}

linux_agent_select_script_editor() {
    if [[ -n "${EDITOR:-}" ]]; then
        printf '%s\n' "${EDITOR}"
        return 0
    fi

    if command -v vi >/dev/null 2>&1; then
        printf 'vi\n'
        return 0
    fi

    return 1
}

linux_agent_open_script_editor() {
    local editor_cmd="$1"
    local target_file="$2"
    local editor_parts=()
    local tty_fd status errexit_was_set=0

    read -r -a editor_parts <<<"${editor_cmd}"
    case "$-" in
        *e*)
            errexit_was_set=1
            set +e
            ;;
    esac

    if { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        printf '\033[0m\033[?25h\033[2K\r\n' >&"${tty_fd}"
        "${editor_parts[@]}" "${target_file}" <&"${tty_fd}" >&"${tty_fd}" 2>&"${tty_fd}"
        status=$?
        printf '\033[0m\033[?25h\033[2K\r\n' >&"${tty_fd}"
        exec {tty_fd}>&-
        [[ "${errexit_was_set}" -eq 1 ]] && set -e
        return "${status}"
    fi

    if [[ -t 2 ]]; then
        printf '\033[0m\033[?25h\033[2K\r\n' >&2
    fi
    "${editor_parts[@]}" "${target_file}" >&2
    status=$?
    if [[ -t 2 ]]; then
        printf '\033[0m\033[?25h\033[2K\r\n' >&2
    fi
    [[ "${errexit_was_set}" -eq 1 ]] && set -e
    return "${status}"
}

linux_agent_file_stamp() {
    local target_file="$1"
    stat -c '%y' "${target_file}" 2>/dev/null || printf ''
}

linux_agent_print_edit_findings() {
    local findings_json="$1"
    local count

    count="$(jq 'length' <<<"${findings_json}")"
    [[ "${count}" -gt 0 ]] || return 0
    jq -r '
        .[]? |
        "- [" + ((.severity // "info") | tostring) + "] "
        + ((.code // "finding") | tostring)
        + ": "
        + ((.message // .reason // .path // .ref // (. | tostring)) | tostring)
    ' <<<"${findings_json}"
}

linux_agent_print_edit_plan() {
    local edit_json="$1"
    local notes

    printf '\n# Skill 编辑计划\n\n'
    printf 'Skill: %s\n' "$(jq -r '.skill.name' <<<"${edit_json}")"
    printf '说明: %s\n\n' "$(jq -r '.skill.description' <<<"${edit_json}")"
    jq -r '.scripts[]? | "脚本: \(.name)\n用途: \(.description)\n"' <<<"${edit_json}"
    notes="$(jq -r '.notes // empty' <<<"${edit_json}")"
    if [[ -n "${notes}" ]]; then
        printf '备注:\n%s\n' "${notes}"
    fi
}

linux_agent_print_edit_review() {
    local review_json="$1"
    local approved risk finding_count findings

    approved="$(jq -r '.approved // false' <<<"${review_json}")"
    risk="$(jq -r '.risk_level // "unknown"' <<<"${review_json}")"
    finding_count="$(jq '.findings | length' <<<"${review_json}")"
    if [[ "${approved}" == "true" ]]; then
        printf '\n脚本审查: 通过，风险=%s，发现项=%s\n' "${risk}" "${finding_count}" >&2
    else
        printf '\n脚本审查: 阻断，风险=%s，发现项=%s\n' "${risk}" "${finding_count}" >&2
    fi

    findings="$(jq -c '.findings // []' <<<"${review_json}")"
    linux_agent_print_edit_findings "${findings}" >&2
}

linux_agent_print_edit_validation_line() {
    local label="$1"
    local validation_json="$2"
    local ok finding_count findings

    ok="$(jq -r '.ok // false' <<<"${validation_json}")"
    finding_count="$(jq '.findings | length' <<<"${validation_json}")"
    if [[ "${ok}" == "true" ]]; then
        printf '%s: 通过，发现项=%s\n' "${label}" "${finding_count}"
    else
        printf '%s: 失败，发现项=%s\n' "${label}" "${finding_count}"
    fi

    findings="$(jq -c '.findings // []' <<<"${validation_json}")"
    linux_agent_print_edit_findings "${findings}"
}

linux_agent_print_edit_result() {
    local result_json="$1"
    local ok status scripts validation global_validation

    ok="$(jq -r '.ok // false' <<<"${result_json}")"
    status="$(jq -r '.status // "unknown"' <<<"${result_json}")"
    if [[ "${ok}" == "true" ]]; then
        printf '\nSkill 保存结果: 成功\n'
    else
        printf '\nSkill 保存结果: 失败，status=%s\n' "${status}"
    fi

    if jq -e 'has("skill")' <<<"${result_json}" >/dev/null 2>&1; then
        printf 'Skill: %s\n' "$(jq -r '.skill' <<<"${result_json}")"
    fi
    if jq -e 'has("script")' <<<"${result_json}" >/dev/null 2>&1; then
        printf '脚本: %s\n' "$(jq -r '.script' <<<"${result_json}")"
    fi
    if jq -e 'has("skill_dir")' <<<"${result_json}" >/dev/null 2>&1; then
        printf '目录: %s\n' "$(jq -r '.skill_dir' <<<"${result_json}")"
    fi
    scripts="$(jq -r '(.scripts // []) | join(", ")' <<<"${result_json}")"
    if [[ -n "${scripts}" ]]; then
        printf '已保存脚本: %s\n' "${scripts}"
    fi

    if jq -e 'has("validation")' <<<"${result_json}" >/dev/null 2>&1; then
        validation="$(jq -c '.validation' <<<"${result_json}")"
        linux_agent_print_edit_validation_line "候选校验" "${validation}"
    fi
    if jq -e 'has("global_validation")' <<<"${result_json}" >/dev/null 2>&1; then
        global_validation="$(jq -c '.global_validation' <<<"${result_json}")"
        linux_agent_print_edit_validation_line "全局校验" "${global_validation}"
    fi
    if jq -e 'has("review")' <<<"${result_json}" >/dev/null 2>&1; then
        linux_agent_print_edit_review "$(jq -c '.review' <<<"${result_json}")"
    fi
}

linux_agent_prompt_edit_revision_request() {
    local result_var="$1"
    local request=""

    printf '请输入修改需求（直接回车则取消保存）: ' >&2
    IFS= read -r request || true
    printf -v "${result_var}" '%s' "${request}"
}

linux_agent_request_revised_edit_package() {
    local original_edit_json="$1"
    local script_name="$2"
    local revision_request="$3"
    local revision_context request_context revised_edit_json

    revision_context="$(jq -cn \
        --arg revision_request "${revision_request}" \
        --arg script "${script_name}" \
        --argjson original_edit "${original_edit_json}" \
        '{
            edit_revision:true,
            revision_request:$revision_request,
            cancelled_script:$script,
            original_edit:$original_edit
        }')"
    request_context="$(jq -cn \
        --arg mode "edit_revision" \
        --arg current_request "${revision_request}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request
        }')"
    request_context="$(linux_agent_add_skill_context "${request_context}" "edit_revision")"
    request_context="$(linux_agent_add_mcp_context "${request_context}" "edit_revision")"

    linux_agent_log_event "edit_revision_requested" "${revision_context}"
    linux_agent_record_ai_request_files "${request_context}"
    revised_edit_json="$(linux_agent_call_ai_with_context "${revision_request}" "${request_context}" "edit" "${revision_context}")"
    if linux_agent_ai_response_is_error "${revised_edit_json}"; then
        linux_agent_log_event "ai_failed" "${revised_edit_json}"
        jq -cn \
            --arg status "$(jq -r '.status' <<<"${revised_edit_json}")" \
            --arg error "$(linux_agent_ai_error_text "${revised_edit_json}")" \
            --argjson response "${revised_edit_json}" \
            '{ok:false, status:$status, error:$error, response:$response}'
        return 1
    fi
    if ! linux_agent_validate_edit_response "${revised_edit_json}"; then
        linux_agent_log_event "ai_invalid_response" "${revised_edit_json}"
        jq -cn --argjson response "${revised_edit_json}" \
            '{ok:false, status:"ai_invalid_response", error:"模型响应不符合 skill_edit schema。", response:$response}'
        return 1
    fi
    linux_agent_log_event "edit_planned" "${revised_edit_json}"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(jq . <<<"${revised_edit_json}")" >&2
    else
        linux_agent_print_edit_plan "${revised_edit_json}" >&2
    fi
    printf '%s\n' "${revised_edit_json}"
}

linux_agent_edit_script_content() {
    local skill_name="$1"
    local script_name="$2"
    local generated_content="$3"
    local edit_file="$4"
    local result_var="$5"
    local original_file editor_cmd edited_content diff_text before_stamp after_stamp

    original_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/script.original.XXXXXX")"
    mkdir -p "$(dirname "${edit_file}")"
    printf '%s\n' "${generated_content}" >"${original_file}"
    printf '%s\n' "${generated_content}" >"${edit_file}"
    before_stamp="$(linux_agent_file_stamp "${edit_file}")"

    printf '\n# AI 生成脚本: %s/%s\n\n' "${skill_name}" "${script_name}" >&2
    printf '%s\n' "${generated_content}" >&2

    if ! editor_cmd="$(linux_agent_select_script_editor)"; then
        linux_agent_print_error "未找到可用编辑器，请设置 EDITOR 或安装 vi。"
        rm -f "${original_file}"
        return 2
    fi

    linux_agent_print_info "即将打开编辑器确认/修改脚本: ${editor_cmd}" >&2
    if ! linux_agent_open_script_editor "${editor_cmd}" "${edit_file}"; then
        linux_agent_print_error "编辑器退出失败，取消保存脚本。"
        rm -f "${original_file}"
        return 2
    fi

    after_stamp="$(linux_agent_file_stamp "${edit_file}")"
    if [[ -z "${after_stamp}" ]] || { [[ "${after_stamp}" == "${before_stamp}" ]] && cmp -s "${original_file}" "${edit_file}"; }; then
        linux_agent_print_error "编辑器未保存脚本，取消保存脚本。"
        rm -f "${original_file}"
        return 3
    fi

    if [[ ! -s "${edit_file}" ]]; then
        linux_agent_print_error "编辑后的脚本为空，取消保存脚本。"
        rm -f "${original_file}"
        return 3
    fi

    edited_content="$(cat "${edit_file}")"
    diff_text="$(diff -u --label "AI原稿:${script_name}" --label "用户修改:${script_name}" "${original_file}" "${edit_file}" || true)"
    if [[ -n "${diff_text}" ]]; then
        linux_agent_log_event "script_manual_edit" "$(jq -cn \
            --arg skill "${skill_name}" \
            --arg script "${script_name}" \
            --arg diff "${diff_text}" \
            '{skill:$skill, script:$script, diff:$diff}')"
        printf '\n# 用户修改 diff\n\n%s\n' "${diff_text}" >&2
    fi

    rm -f "${original_file}"
    printf -v "${result_var}" '%s' "${edited_content}"
    return 0
}

linux_agent_commit_staged_skill() {
    local staging_skill_dir="$1"
    local user_root result status

    user_root="$(linux_agent_user_skills_dir)"
    if ! linux_agent_runtime_lock_exclusive_nonblocking; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="runtime_busy"
        LINUX_AGENT_SKILL_COMMIT_RESULT='{"ok":false,"status":"runtime_busy","code":"runtime_busy","error":"Runtime is executing or being changed"}'
        return 1
    fi
    mkdir -p -- "${user_root}" || {
        linux_agent_runtime_lock_release
        LINUX_AGENT_SKILL_COMMIT_STATUS="skill_root_unavailable"
        return 1
    }

    if result="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_lifecycle.py" install "${staging_skill_dir}" \
        --root "${user_root}" \
        --origin user \
        --index "$(linux_agent_skill_index_path)" \
        --replace 2>/dev/null)"; then
        linux_agent_runtime_lock_release
        LINUX_AGENT_SKILL_COMMIT_RESULT="${result}"
        LINUX_AGENT_SKILL_COMMIT_STATUS="edited"
        LINUX_AGENT_SKILL_COMMIT_WARNING="$(jq -r '.warning // empty' <<<"${result}")"
        return 0
    fi

    linux_agent_runtime_lock_release
    LINUX_AGENT_SKILL_COMMIT_RESULT="${result}"
    status="$(jq -r '.code // .status // "commit_failed"' <<<"${result}" 2>/dev/null || printf 'commit_failed')"
    LINUX_AGENT_SKILL_COMMIT_STATUS="${status}"
    return 1
}

linux_agent_review_edit_package() {
    local edit_json="$1"
    local skill_name scripts_json reviews ok
    local script_items=()

    if ! linux_agent_validate_edit_response "${edit_json}"; then
        jq -cn '{ok:false, status:"invalid_edit_package", error:"skill_edit JSON 不符合 schema。"}'
        return 0
    fi

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    reviews='[]'
    ok="true"
    mapfile -t script_items < <(jq -c '.scripts[]' <<<"${edit_json}")

    for script in "${script_items[@]}"; do
        [[ -z "${script}" ]] && continue
        local script_name content review
        script_name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        if [[ -z "${content}" ]]; then
            review="$(jq -cn '{approved:false, approval_required:true, risk_level:"critical", findings:[{severity:"critical", code:"SCRIPT_EMPTY", message:"脚本内容不能为空。"}]}')"
        else
            review="$(linux_agent_policy_review_text "edit:${skill_name}/${script_name}" "${content}")"
        fi
        if [[ "$(jq -r '.approved // false' <<<"${review}")" != "true" ]]; then
            ok="false"
        fi
        reviews="$(jq -cn \
            --argjson prior "${reviews}" \
            --arg name "${script_name}" \
            --arg description "$(jq -r '.description' <<<"${script}")" \
            --argjson review "${review}" \
            '$prior + [{name:$name, description:$description, review:$review}]')"
    done

    jq -cn \
        --argjson ok "${ok}" \
        --arg skill "${skill_name}" \
        --arg description "$(jq -r '.skill.description' <<<"${edit_json}")" \
        --argjson scripts "${scripts_json}" \
        --argjson reviews "${reviews}" \
        '{ok:$ok, status:(if $ok then "approved" else "blocked" end), skill:$skill, description:$description, scripts:$scripts, reviews:$reviews}'
}

linux_agent_skill_edit_preflight() {
    local edit_json="$1" skill_name observer_gate observer_subject

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
        jq -cn --arg skill "${skill_name}" \
            '{ok:false,status:"skill_conflict",code:"skill_conflict",skill:$skill,error:"A user Skill may not replace a built-in Skill."}'
        return 1
    fi

    observer_subject="$(jq -cn --arg skill "${skill_name}" '{kind:"skill_edit_apply",skill:$skill}')"
    if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
        ! observer_gate="$(linux_agent_observer_execution_gate "edit_apply" "${observer_subject}")"; then
        printf '%s\n' "${observer_gate}"
        return 1
    fi

    jq -cn --arg skill "${skill_name}" '{ok:true,status:"ready",skill:$skill}'
}

linux_agent_finalize_skill_edit() {
    local edit_json="$1" review_json="$2"
    local skill_name skill_dir user_root staging_root staging_skill_dir validation global_validation
    local committed_scripts audit_payload audit_rc commit_error

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    user_root="$(linux_agent_user_skills_dir)"
    skill_dir="${user_root}/${skill_name}"
    committed_scripts="$(jq -c '[.scripts[].name]' <<<"${edit_json}")"
    mkdir -p -- "${user_root}"
    staging_root="$(mktemp -d "${user_root}/.staging.${skill_name}.XXXXXX")"
    staging_skill_dir="${staging_root}/${skill_name}"
    mkdir -p -- "${staging_skill_dir}"

    if ! linux_agent_write_edit_resources "${edit_json}" "${staging_skill_dir}"; then
        rm -rf -- "${staging_root}"
        jq -cn --arg skill "${skill_name}" \
            '{ok:false,status:"package_render_failed",code:"package_render_failed",skill:$skill}'
        return 0
    fi

    validation="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" validate \
        "${staging_skill_dir}" --origin user 2>/dev/null || true)"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf -- "${staging_root}"
        jq -cn \
            --arg skill "${skill_name}" \
            --argjson validation "${validation}" \
            --argjson review "${review_json}" \
            '{ok:false,status:"validation_failed",skill:$skill,validation:$validation,review:$review}'
        return 0
    fi

    audit_payload="$(jq -cn --arg skill "${skill_name}" --argjson scripts "${committed_scripts}" \
        '{skill:$skill,scripts:$scripts}')"
    audit_rc=0
    linux_agent_audit_require_event "edit_commit_started" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        rm -rf -- "${staging_root}"
        linux_agent_audit_failure_result "${audit_rc}" "edit_commit_started"
        return 0
    fi

    if ! linux_agent_web_sensitive_edits_enabled; then
        rm -rf -- "${staging_root}"
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi

    LINUX_AGENT_SKILL_COMMIT_RESULT=""
    LINUX_AGENT_SKILL_COMMIT_STATUS=""
    LINUX_AGENT_SKILL_COMMIT_WARNING=""
    if ! linux_agent_commit_staged_skill "${staging_skill_dir}"; then
        rm -rf -- "${staging_root}"
        commit_error="$(jq -r '.error // empty' <<<"${LINUX_AGENT_SKILL_COMMIT_RESULT:-{}}" 2>/dev/null || true)"
        jq -cn \
            --arg skill "${skill_name}" \
            --arg status "${LINUX_AGENT_SKILL_COMMIT_STATUS:-commit_failed}" \
            --arg error "${commit_error}" \
            '{ok:false,status:$status,code:$status,skill:$skill}
             + (if $error == "" then {} else {error:$error} end)'
        return 0
    fi
    rm -rf -- "${staging_root}"

    global_validation="$(linux_agent_validate_skills)"
    jq -cn \
        --arg skill "${skill_name}" \
        --arg skill_dir "${skill_dir}" \
        --argjson scripts "${committed_scripts}" \
        --argjson validation "${validation}" \
        --argjson global_validation "${global_validation}" \
        --argjson review "${review_json}" \
        --arg warning "${LINUX_AGENT_SKILL_COMMIT_WARNING:-}" \
        '{ok:true,status:"edited",skill:$skill,skill_dir:$skill_dir,scripts:$scripts,
          validation:$validation,global_validation:$global_validation,review:$review}
         + (if $warning == "" then {} else {warning:$warning} end)'
}

linux_agent_apply_skill_edit_package_direct() {
    local edit_json="$1"
    local review_json preflight

    review_json="$(linux_agent_review_edit_package "${edit_json}")"
    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        jq -cn --argjson review "${review_json}" \
            '{ok:false,status:($review.status // "blocked"),review:$review}'
        return 0
    fi
    if ! preflight="$(linux_agent_skill_edit_preflight "${edit_json}")"; then
        printf '%s\n' "${preflight}"
        return 0
    fi

    linux_agent_finalize_skill_edit "${edit_json}" "${review_json}"
}

linux_agent_apply_skill_edit_package() {
    local edit_json="$1"
    local skill_name scripts_json edit_root preflight review_json
    local script_items=()

    review_json="$(linux_agent_review_edit_package "${edit_json}")"
    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        jq -cn --argjson review "${review_json}" \
            '{ok:false,status:($review.status // "blocked"),review:$review}'
        return 0
    fi
    if ! preflight="$(linux_agent_skill_edit_preflight "${edit_json}")"; then
        printf '%s\n' "${preflight}"
        return 0
    fi

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    edit_root="${LINUX_AGENT_TMP_DIR}/edit/${skill_name}"
    rm -rf -- "${edit_root}"
    mkdir -p -- "${edit_root}"
    mapfile -t script_items < <(jq -c '.scripts[]' <<<"${edit_json}")

    for script in "${script_items[@]}"; do
        [[ -n "${script}" ]] || continue
        local script_name content review edit_file edit_status
        script_name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        edit_file="${edit_root}/${script_name}"

        set +e
        linux_agent_edit_script_content "${skill_name}" "${script_name}" "${content}" "${edit_file}" content
        edit_status=$?
        set -e
        if [[ "${edit_status}" -ne 0 ]]; then
            rm -rf -- "${edit_root}"
            if [[ "${edit_status}" -eq 3 ]]; then
                local edit_revision_request revised_edit_json
                linux_agent_prompt_edit_revision_request edit_revision_request
                if [[ -n "${edit_revision_request}" ]]; then
                    if ! revised_edit_json="$(linux_agent_request_revised_edit_package \
                        "${edit_json}" "${script_name}" "${edit_revision_request}")"; then
                        if ! jq -e . <<<"${revised_edit_json}" >/dev/null 2>&1; then
                            revised_edit_json="$(jq -cn --arg raw "${revised_edit_json}" '{raw:$raw}')"
                        fi
                        jq -cn \
                            --arg skill "${skill_name}" \
                            --arg script "${script_name}" \
                            --argjson detail "${revised_edit_json}" \
                            '{ok:false,status:"edit_revision_failed",skill:$skill,script:$script,detail:$detail}'
                        return 0
                    fi
                    linux_agent_apply_skill_edit_package "${revised_edit_json}"
                    return 0
                fi
                jq -cn --arg skill "${skill_name}" --arg script "${script_name}" \
                    '{ok:false,status:"editor_cancelled",skill:$skill,script:$script}'
                return 0
            fi
            jq -cn --arg skill "${skill_name}" --arg script "${script_name}" \
                '{ok:false,status:"editor_failed",skill:$skill,script:$script}'
            return 0
        fi

        review="$(linux_agent_policy_review_text "edit:${skill_name}/${script_name}" "${content}")"
        if linux_agent_output_json_enabled; then
            printf '\n审查结果:\n%s\n' "$(jq . <<<"${review}")" >&2
        else
            linux_agent_print_edit_review "${review}"
        fi
        if [[ "$(jq -r '.approved // false' <<<"${review}")" != "true" ]]; then
            rm -rf -- "${edit_root}"
            jq -cn \
                --arg skill "${skill_name}" \
                --arg script "${script_name}" \
                --argjson review "${review}" \
                '{ok:false,status:"blocked",skill:$skill,script:$script,review:$review}'
            return 0
        fi
        scripts_json="$(jq -c --arg name "${script_name}" --arg content "${content}" \
            'map(if .name == $name then .content = $content else . end)' <<<"${scripts_json}")"
    done
    rm -rf -- "${edit_root}"

    edit_json="$(jq -c --argjson scripts "${scripts_json}" '.scripts = $scripts' <<<"${edit_json}")"
    review_json="$(linux_agent_review_edit_package "${edit_json}")"
    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        jq -cn --argjson review "${review_json}" \
            '{ok:false,status:($review.status // "blocked"),review:$review}'
        return 0
    fi
    linux_agent_finalize_skill_edit "${edit_json}" "${review_json}"
}

linux_agent_process_edit_request() {
    local user_input="$1"
    local mode="${2:-edit}"
    local context_json request_context edit_json result final_status

    linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" --arg mode "${mode}" '{input:$input, mode:$mode}')"

    context_json="$(jq -cn '{edit_mode:true}')"
    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "edit")"
    request_context="$(linux_agent_add_skill_context "${request_context}" "edit")"
    request_context="$(linux_agent_add_mcp_context "${request_context}" "edit")"
    linux_agent_record_ai_request_files "${request_context}"
    edit_json="$(linux_agent_call_ai_with_context "${user_input}" "${request_context}" "edit" "${context_json}")"
    if linux_agent_ai_response_is_error "${edit_json}"; then
        linux_agent_log_event "ai_failed" "${edit_json}"
        linux_agent_print_error "$(linux_agent_ai_error_text "${edit_json}")"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_failed"}')"
        return 1
    fi
    if ! linux_agent_validate_edit_response "${edit_json}"; then
        linux_agent_log_event "ai_invalid_response" "${edit_json}"
        linux_agent_print_error "模型响应不符合 skill_edit schema。"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_invalid_response"}')"
        return 1
    fi

    linux_agent_log_event "edit_planned" "${edit_json}"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(jq . <<<"${edit_json}")"
    else
        linux_agent_print_edit_plan "${edit_json}"
    fi

    result="$(linux_agent_apply_skill_edit_package "${edit_json}")"
    linux_agent_log_event "edit_applied" "${result}"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(jq . <<<"${result}")"
    else
        linux_agent_print_edit_result "${result}"
    fi

    if [[ "$(jq -r '.ok // false' <<<"${result}")" == "true" ]]; then
        final_status="edited"
    else
        final_status="$(jq -r '.status // "failed"' <<<"${result}")"
    fi

    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    linux_agent_record_conversation_turn "edit" "${user_input}" "$(jq -c '.skill // {}' <<<"${edit_json}")" "${final_status}" "request"
}
