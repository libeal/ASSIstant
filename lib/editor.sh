#!/usr/bin/env bash

set -euo pipefail

linux_agent_render_skill_md() {
    local skill_name="$1"
    local description="$2"
    local scripts_json="$3"

    {
        printf -- '---\n'
        printf 'name: %s\n' "${skill_name}"
        printf 'description: %s\n' "${description}"
        printf -- '---\n\n'
        printf '# %s\n\n' "${skill_name}"
        printf '%s\n\n' "${description}"
        printf '## Scripts\n\n'
        jq -r '.[] | "- `scripts/\(.name)`: \(.description)"' <<<"${scripts_json}"
        printf '\n## Workflow\n\n'
        printf '按脚本文档选择最小必要脚本执行。脚本接收 JSON 字符串作为第一个参数，并输出 JSON。\n'
    }
}

linux_agent_write_skill_index() {
    local index_path="$1"
    local skill_name="$2"
    local description="$3"
    local scripts_json="$4"
    local tmp_path
    tmp_path="${LINUX_AGENT_TMP_DIR}/INDEX.${RANDOM}.md"
    mkdir -p "$(dirname "${index_path}")"

    if [[ -f "${index_path}" ]]; then
        awk -v skill="${skill_name}" '
            BEGIN {skip=0}
            /^## / {
                if ($0 == "## " skill) {skip=1; next}
                skip=0
            }
            skip == 0 {print}
        ' "${index_path}" > "${tmp_path}"
    else
        {
            printf '# Skill Index\n\n'
            printf '工作模式会把此文件作为可用 skill 摘要上传给 AI。脚本模式仅允许执行这里登记且在对应 `SKILL.md` 中说明的脚本。\n\n'
        } > "${tmp_path}"
    fi

    {
        printf '\n## %s\n\n' "${skill_name}"
        printf '%s\n\n' "${description}"
        jq -r --arg skill "${skill_name}" '.[] | "- `\($skill)/\(.name | sub("\\.sh$"; ""))`: \(.description)"' <<<"${scripts_json}"
    } >> "${tmp_path}"
    mv "${tmp_path}" "${index_path}"
}

linux_agent_select_script_editor() {
    local candidate
    if [[ -n "${EDITOR:-}" ]]; then
        printf '%s\n' "${EDITOR}"
        return 0
    fi

    for candidate in vi; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

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
    printf '%s\n' "${generated_content}" > "${original_file}"
    printf '%s\n' "${generated_content}" > "${edit_file}"
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
    local skill_name="$1"
    local staging_skill_dir="$2"
    local candidate_index="$3"
    local skill_dir index_path backup_dir had_backup
    skill_dir="$(linux_agent_skills_dir)/${skill_name}"
    index_path="$(linux_agent_skill_index_path)"
    backup_dir="${LINUX_AGENT_TMP_DIR}/edit-backup.${skill_name}.${RANDOM}.$$"
    had_backup=0

    mkdir -p "$(dirname "${skill_dir}")" "$(dirname "${index_path}")"
    if [[ -d "${skill_dir}" ]]; then
        mv "${skill_dir}" "${backup_dir}"
        had_backup=1
    fi

    if mv "${staging_skill_dir}" "${skill_dir}" && mv "${candidate_index}" "${index_path}"; then
        [[ "${had_backup}" -eq 1 ]] && rm -rf "${backup_dir}"
        return 0
    fi

    rm -rf "${skill_dir}"
    if [[ "${had_backup}" -eq 1 && -d "${backup_dir}" ]]; then
        mv "${backup_dir}" "${skill_dir}"
    fi
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

linux_agent_apply_skill_edit_package_direct() {
    local edit_json="$1"
    local review_json skill_name description skill_dir scripts_json edit_root staging_skill_dir staging_scripts_dir candidate_index
    local validation global_validation committed_scripts
    local script_items=()

    review_json="$(linux_agent_review_edit_package "${edit_json}")"
    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        jq -cn --argjson review "${review_json}" \
            '{ok:false, status:($review.status // "blocked"), review:$review}'
        return 0
    fi

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    description="$(jq -r '.skill.description' <<<"${edit_json}")"
    skill_dir="$(linux_agent_skills_dir)/${skill_name}"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    edit_root="${LINUX_AGENT_TMP_DIR}/edit/${skill_name}"
    staging_skill_dir="${edit_root}/staged"
    staging_scripts_dir="${staging_skill_dir}/scripts"
    candidate_index="${edit_root}/INDEX.md"
    committed_scripts="$(jq -c '[.scripts[].name]' <<<"${edit_json}")"

    rm -rf "${edit_root}"
    mkdir -p "${staging_scripts_dir}" "${staging_skill_dir}/references" "${staging_skill_dir}/assets"
    mapfile -t script_items < <(jq -c '.scripts[]' <<<"${edit_json}")

    for script in "${script_items[@]}"; do
        [[ -z "${script}" ]] && continue
        local script_name content script_path
        script_name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        script_path="${staging_scripts_dir}/${script_name}"
        printf '%s\n' "${content}" > "${script_path}"
        chmod +x "${script_path}"
    done

    linux_agent_render_skill_md "${skill_name}" "${description}" "${scripts_json}" > "${staging_skill_dir}/SKILL.md"
    if [[ -f "$(linux_agent_skill_index_path)" ]]; then
        cp "$(linux_agent_skill_index_path)" "${candidate_index}"
    fi
    linux_agent_write_skill_index "${candidate_index}" "${skill_name}" "${description}" "${scripts_json}"
    validation="$(linux_agent_validate_skill_at "${skill_name}" "${staging_skill_dir}" "${candidate_index}")"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf "${edit_root}"
        jq -cn --arg skill "${skill_name}" --argjson validation "${validation}" --argjson review "${review_json}" \
            '{ok:false, status:"validation_failed", skill:$skill, validation:$validation, review:$review}'
        return 0
    fi

    if ! linux_agent_commit_staged_skill "${skill_name}" "${staging_skill_dir}" "${candidate_index}"; then
        rm -rf "${edit_root}"
        jq -cn --arg skill "${skill_name}" '{ok:false, status:"commit_failed", skill:$skill}'
        return 0
    fi

    rm -rf "${edit_root}"
    global_validation="$(linux_agent_validate_skills)"
    jq -cn \
        --arg skill "${skill_name}" \
        --arg skill_dir "${skill_dir}" \
        --argjson scripts "${committed_scripts}" \
        --argjson validation "${validation}" \
        --argjson global_validation "${global_validation}" \
        --argjson review "${review_json}" \
        '{ok:true, status:"edited", skill:$skill, skill_dir:$skill_dir, scripts:$scripts, validation:$validation, global_validation:$global_validation, review:$review}'
}

linux_agent_apply_skill_edit_package() {
    local edit_json="$1"
    local skill_name description skill_dir scripts_json edit_root staging_skill_dir staging_scripts_dir candidate_index
    local validation global_validation committed_scripts
    local script_items=()
    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    description="$(jq -r '.skill.description' <<<"${edit_json}")"
    skill_dir="$(linux_agent_skills_dir)/${skill_name}"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    edit_root="${LINUX_AGENT_TMP_DIR}/edit/${skill_name}"
    staging_skill_dir="${edit_root}/staged"
    staging_scripts_dir="${staging_skill_dir}/scripts"
    candidate_index="${edit_root}/INDEX.md"
    committed_scripts="$(jq -c '[.scripts[].name]' <<<"${edit_json}")"

    rm -rf "${edit_root}"
    mkdir -p "${staging_scripts_dir}" "${staging_skill_dir}/references" "${staging_skill_dir}/assets"
    mapfile -t script_items < <(jq -c '.scripts[]' <<<"${edit_json}")

    for script in "${script_items[@]}"; do
        [[ -z "${script}" ]] && continue
        local script_name content review script_path edit_file edit_status
        script_name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        edit_file="${edit_root}/${script_name}"
        script_path="${staging_scripts_dir}/${script_name}"

        set +e
        linux_agent_edit_script_content "${skill_name}" "${script_name}" "${content}" "${edit_file}" content
        edit_status=$?
        set -e
        if [[ "${edit_status}" -ne 0 ]]; then
            rm -rf "${edit_root}"
            if [[ "${edit_status}" -eq 3 ]]; then
                local edit_revision_request revised_edit_json
                linux_agent_prompt_edit_revision_request edit_revision_request
                if [[ -n "${edit_revision_request}" ]]; then
                    rm -rf "${edit_root}"
                    if ! revised_edit_json="$(linux_agent_request_revised_edit_package "${edit_json}" "${script_name}" "${edit_revision_request}")"; then
                        if ! jq -e . <<<"${revised_edit_json}" >/dev/null 2>&1; then
                            revised_edit_json="$(jq -cn --arg raw "${revised_edit_json}" '{raw:$raw}')"
                        fi
                        jq -cn --arg skill "${skill_name}" --arg script "${script_name}" --argjson detail "${revised_edit_json}" \
                            '{ok:false, status:"edit_revision_failed", skill:$skill, script:$script, detail:$detail}'
                        return 0
                    fi
                    linux_agent_apply_skill_edit_package "${revised_edit_json}"
                    return 0
                fi
                jq -cn --arg skill "${skill_name}" --arg script "${script_name}" \
                    '{ok:false, status:"editor_cancelled", skill:$skill, script:$script}'
                return 0
            fi
            jq -cn --arg skill "${skill_name}" --arg script "${script_name}" \
                '{ok:false, status:"editor_failed", skill:$skill, script:$script}'
            return 0
        fi

        review="$(linux_agent_policy_review_text "edit:${skill_name}/${script_name}" "${content}")"
        if linux_agent_output_json_enabled; then
            printf '\n审查结果:\n%s\n' "$(jq . <<<"${review}")" >&2
        else
            linux_agent_print_edit_review "${review}"
        fi
        if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
            rm -rf "${edit_root}"
            jq -cn --arg skill "${skill_name}" --arg script "${script_name}" --argjson review "${review}" \
                '{ok:false, status:"blocked", skill:$skill, script:$script, review:$review}'
            return 0
        fi
        printf '%s\n' "${content}" > "${script_path}"
        chmod +x "${script_path}"
    done

    linux_agent_render_skill_md "${skill_name}" "${description}" "${scripts_json}" > "${staging_skill_dir}/SKILL.md"
    if [[ -f "$(linux_agent_skill_index_path)" ]]; then
        cp "$(linux_agent_skill_index_path)" "${candidate_index}"
    fi
    linux_agent_write_skill_index "${candidate_index}" "${skill_name}" "${description}" "${scripts_json}"
    validation="$(linux_agent_validate_skill_at "${skill_name}" "${staging_skill_dir}" "${candidate_index}")"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf "${edit_root}"
        jq -cn --arg skill "${skill_name}" --argjson validation "${validation}" \
            '{ok:false, status:"validation_failed", skill:$skill, validation:$validation}'
        return 0
    fi

    if ! linux_agent_commit_staged_skill "${skill_name}" "${staging_skill_dir}" "${candidate_index}"; then
        rm -rf "${edit_root}"
        jq -cn --arg skill "${skill_name}" '{ok:false, status:"commit_failed", skill:$skill}'
        return 0
    fi

    rm -rf "${edit_root}"
    global_validation="$(linux_agent_validate_skills)"
    jq -cn \
        --arg skill "${skill_name}" \
        --arg skill_dir "${skill_dir}" \
        --argjson scripts "${committed_scripts}" \
        --argjson validation "${validation}" \
        --argjson global_validation "${global_validation}" \
        '{ok:true, status:"edited", skill:$skill, skill_dir:$skill_dir, scripts:$scripts, validation:$validation, global_validation:$global_validation}'
}

linux_agent_process_edit_request() {
    local user_input="$1"
    local mode="${2:-edit}"
    local context_json request_context edit_json result final_status

    linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" --arg mode "${mode}" '{input:$input, mode:$mode}')"

    context_json="$(jq -cn '{edit_mode:true}')"
    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "edit")"
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
