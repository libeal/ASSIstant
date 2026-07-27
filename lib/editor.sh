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
        jq -r --arg skill "${skill_name}" \
            '.[] | "- `scripts/\(.name)`（登记引用 `\($skill)/\(.name | sub("\\.sh$"; ""))`）：\(.description)"' \
            <<<"${scripts_json}"
        printf '\n## 参数规范\n\n'
        printf '调用形式为 `bash scripts/<name>.sh '\''<json-object>'\''`。唯一位置参数必须是 JSON object；每个脚本条目中的 description 必须说明字段类型、必填性、默认值和约束。stdout 只输出一个 JSON object，调用方依据 `ok`、`status` 和 `error` 判断业务结果。\n'
        printf '\n## Workflow\n\n'
        printf '按脚本文档选择最小必要脚本执行。脚本接收 JSON 字符串作为第一个参数，并输出 JSON。\n'
    }
}

linux_agent_render_user_skill_manifest() {
    local skill_name="$1"
    local description="$2"
    local scripts_json="$3"
    local items='[]' script name content review risk

    while IFS= read -r script; do
        [[ -n "${script}" ]] || continue
        name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        review="$(linux_agent_policy_review_text "edit:${skill_name}/${name}" "${content}")"
        risk="$(jq -r '.risk_level // "critical"' <<<"${review}")"
        linux_agent_risk_is_valid "${risk}" || risk="critical"
        items="$(jq -cn --argjson prior "${items}" --arg name "${name}" --arg risk "${risk}" \
            '$prior + [{name:$name, risk:$risk, execution_class:"runner", capability:""}]')"
    done < <(jq -c '.[]' <<<"${scripts_json}")

    jq -S -n --arg name "${skill_name}" --arg description "${description}" --argjson scripts "${items}" \
        '{schema_version:1, name:$name, description:$description, scripts:$scripts}'
}

linux_agent_write_skill_index() {
    local index_path="$1"
    local skill_name="$2"
    local description="$3"
    local scripts_json="$4"
    local tmp_path
    mkdir -p "$(dirname "${index_path}")"
    tmp_path="$(mktemp "$(dirname "${index_path}")/.INDEX.XXXXXX.tmp")"

    if [[ -f "${index_path}" ]]; then
        awk -v skill="${skill_name}" '
            BEGIN {skip=0}
            /^## / {
                if ($0 == "## " skill) {skip=1; next}
                skip=0
            }
            skip == 0 {print}
        ' "${index_path}" >"${tmp_path}"
    else
        {
            printf '# Skill Index\n\n'
            printf '工作模式会把此文件作为可用 skill 摘要上传给 AI。脚本模式仅允许执行这里登记且在对应 `SKILL.md` 中说明的脚本。\n\n'
        } >"${tmp_path}"
    fi

    {
        printf '\n## %s\n\n' "${skill_name}"
        printf '%s\n\n' "${description}"
        jq -r --arg skill "${skill_name}" '.[] | "- `\($skill)/\(.name | sub("\\.sh$"; ""))`: \(.description)"' <<<"${scripts_json}"
    } >>"${tmp_path}"
    chmod 0644 "${tmp_path}"
    python3 - "${tmp_path}" "$(dirname "${index_path}")" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY | (os.O_DIRECTORY if os.path.isdir(path) else 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
    mv -T "${tmp_path}" "${index_path}"
    python3 - "$(dirname "${index_path}")" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
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

linux_agent_fsync_skill_paths() {
    python3 - "$@" <<'PY'
import os
import pathlib
import stat
import sys


def sync_fd(path, flags):
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


for raw in sys.argv[1:]:
    path = pathlib.Path(raw)
    if path.is_dir():
        for child in sorted(path.rglob("*"), key=lambda item: len(item.parts), reverse=True):
            metadata = child.lstat()
            if stat.S_ISREG(metadata.st_mode):
                sync_fd(os.fspath(child), os.O_RDONLY)
            elif stat.S_ISDIR(metadata.st_mode):
                sync_fd(os.fspath(child), os.O_RDONLY | os.O_DIRECTORY)
            else:
                raise OSError(f"unsafe fsync path: {child}")
        sync_fd(os.fspath(path), os.O_RDONLY | os.O_DIRECTORY)
    else:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError(f"unsafe fsync path: {path}")
        sync_fd(os.fspath(path), os.O_RDONLY)
PY
}

linux_agent_skill_commit_journal_path() {
    printf '%s/.commit-recovery.json\n' "$1"
}

linux_agent_write_skill_commit_journal() {
    local user_root="$1" skill_name="$2" staging_name="$3" candidate_name="$4"
    local backup_name="$5" index_backup_name="$6" had_skill="$7" had_index="$8"
    local skill_identity="$9" index_identity="${10}" state="${11}"
    local journal payload

    [[ -d "${user_root}" && ! -L "${user_root}" ]] || return 1
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    [[ "${staging_name}" =~ ^[.][A-Za-z0-9._-]+$ &&
        "${candidate_name}" =~ ^[.][A-Za-z0-9._-]+$ &&
        "${backup_name}" =~ ^[.]backup[.]${skill_name}[.][A-Za-z0-9._-]+$ &&
        "${index_backup_name}" =~ ^[.]backup-index[.]${skill_name}[.][A-Za-z0-9._-]+$ ]] || return 1
    [[ "${had_skill}" =~ ^[01]$ && "${had_index}" =~ ^[01]$ ]] || return 1
    [[ "${skill_identity}" =~ ^$|^[0-9]+:[0-9]+$ &&
        "${index_identity}" =~ ^$|^[0-9]+:[0-9]+$ ]] || return 1
    [[ "${state}" == "prepared" || "${state}" == "committed" ]] || return 1

    journal="$(linux_agent_skill_commit_journal_path "${user_root}")"
    payload="$(jq -cn \
        --arg skill "${skill_name}" \
        --arg staging "${staging_name}" \
        --arg candidate "${candidate_name}" \
        --arg backup "${backup_name}" \
        --arg index_backup "${index_backup_name}" \
        --arg skill_identity "${skill_identity}" \
        --arg index_identity "${index_identity}" \
        --arg state "${state}" \
        --argjson had_skill "$([[ "${had_skill}" == "1" ]] && printf true || printf false)" \
        --argjson had_index "$([[ "${had_index}" == "1" ]] && printf true || printf false)" \
        '{
            schema_version:1,
            state:$state,
            skill:$skill,
            staging:$staging,
            candidate_index:$candidate,
            skill_backup:$backup,
            index_backup:$index_backup,
            had_skill:$had_skill,
            had_index:$had_index,
            skill_identity:$skill_identity,
            index_identity:$index_identity
        }')" || return 1

    python3 - "${journal}" "${payload}" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

journal = pathlib.Path(sys.argv[1])
payload = (sys.argv[2] + "\n").encode("utf-8")
parent = journal.parent
metadata = parent.lstat()
if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit("Skill journal parent must be a non-symlink directory")
descriptor, raw_path = tempfile.mkstemp(
    prefix=".commit-recovery.", suffix=".tmp", dir=parent
)
temporary = pathlib.Path(raw_path)
try:
    os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("Skill journal write made no forward progress")
        offset += written
    os.fsync(descriptor)
    os.close(descriptor)
    descriptor = -1
    os.replace(temporary, journal)
    directory = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
}

linux_agent_remove_skill_commit_journal() {
    local user_root="$1" journal
    journal="$(linux_agent_skill_commit_journal_path "${user_root}")"
    python3 - "${journal}" <<'PY'
import os
import pathlib
import stat
import sys

journal = pathlib.Path(sys.argv[1])
try:
    metadata = journal.lstat()
except FileNotFoundError:
    raise SystemExit(0)
if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit("Skill commit journal must be a regular non-symlink file")
journal.unlink()
directory = os.open(
    journal.parent,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

linux_agent_recover_pending_skill_commit_locked() {
    local user_root="$1" journal journal_json skill_name state staging_name candidate_name
    local backup_name index_backup_name had_skill had_index skill_identity index_identity
    local skill_dir index_path staging_path candidate_path backup_dir index_backup actual_identity

    journal="$(linux_agent_skill_commit_journal_path "${user_root}")"
    [[ ! -e "${journal}" && ! -L "${journal}" ]] && return 0
    [[ -f "${journal}" && ! -L "${journal}" ]] || return 1
    journal_json="$(cat -- "${journal}")" || return 1
    jq -e '
        type == "object" and length == 11
        and .schema_version == 1
        and (.state == "prepared" or .state == "committed")
        and (.skill | type == "string")
        and (.staging | type == "string")
        and (.candidate_index | type == "string")
        and (.skill_backup | type == "string")
        and (.index_backup | type == "string")
        and (.had_skill | type == "boolean")
        and (.had_index | type == "boolean")
        and (.skill_identity | type == "string")
        and (.index_identity | type == "string")
    ' <<<"${journal_json}" >/dev/null 2>&1 || return 1

    skill_name="$(jq -r '.skill' <<<"${journal_json}")"
    state="$(jq -r '.state' <<<"${journal_json}")"
    staging_name="$(jq -r '.staging' <<<"${journal_json}")"
    candidate_name="$(jq -r '.candidate_index' <<<"${journal_json}")"
    backup_name="$(jq -r '.skill_backup' <<<"${journal_json}")"
    index_backup_name="$(jq -r '.index_backup' <<<"${journal_json}")"
    had_skill="$(jq -r 'if .had_skill then 1 else 0 end' <<<"${journal_json}")"
    had_index="$(jq -r 'if .had_index then 1 else 0 end' <<<"${journal_json}")"
    skill_identity="$(jq -r '.skill_identity' <<<"${journal_json}")"
    index_identity="$(jq -r '.index_identity' <<<"${journal_json}")"

    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    [[ "${staging_name}" =~ ^[.][A-Za-z0-9._-]+$ &&
        "${candidate_name}" =~ ^[.][A-Za-z0-9._-]+$ &&
        "${backup_name}" =~ ^[.]backup[.]${skill_name}[.][A-Za-z0-9._-]+$ &&
        "${index_backup_name}" =~ ^[.]backup-index[.]${skill_name}[.][A-Za-z0-9._-]+$ ]] || return 1
    [[ "${skill_identity}" =~ ^$|^[0-9]+:[0-9]+$ &&
        "${index_identity}" =~ ^$|^[0-9]+:[0-9]+$ ]] || return 1

    skill_dir="${user_root}/${skill_name}"
    index_path="${user_root}/INDEX.md"
    staging_path="${user_root}/${staging_name}"
    candidate_path="${user_root}/${candidate_name}"
    backup_dir="${user_root}/${backup_name}"
    index_backup="${user_root}/${index_backup_name}"

    if [[ "${state}" == "committed" ]]; then
        [[ -d "${skill_dir}" && ! -L "${skill_dir}" &&
            -f "${index_path}" && ! -L "${index_path}" ]] || return 1
    else
        if [[ "${had_skill}" == "1" ]]; then
            if [[ -d "${backup_dir}" && ! -L "${backup_dir}" ]]; then
                if [[ -e "${skill_dir}" || -L "${skill_dir}" ]]; then
                    rm -rf -- "${skill_dir}" || return 1
                fi
                mv -T -- "${backup_dir}" "${skill_dir}" || return 1
            else
                [[ -d "${skill_dir}" && ! -L "${skill_dir}" ]] || return 1
                actual_identity="$(stat -c '%d:%i' -- "${skill_dir}" 2>/dev/null || true)"
                [[ -n "${skill_identity}" && "${actual_identity}" == "${skill_identity}" ]] || return 1
            fi
        elif [[ -e "${skill_dir}" || -L "${skill_dir}" ]]; then
            rm -rf -- "${skill_dir}" || return 1
        fi

        if [[ "${had_index}" == "1" ]]; then
            if [[ -f "${index_backup}" && ! -L "${index_backup}" ]]; then
                if [[ -e "${index_path}" || -L "${index_path}" ]]; then
                    rm -f -- "${index_path}" || return 1
                fi
                mv -T -- "${index_backup}" "${index_path}" || return 1
            else
                [[ -f "${index_path}" && ! -L "${index_path}" ]] || return 1
                actual_identity="$(stat -c '%d:%i' -- "${index_path}" 2>/dev/null || true)"
                [[ -n "${index_identity}" && "${actual_identity}" == "${index_identity}" ]] || return 1
            fi
        elif [[ -e "${index_path}" || -L "${index_path}" ]]; then
            rm -f -- "${index_path}" || return 1
        fi
    fi

    [[ ! -e "${backup_dir}" && ! -L "${backup_dir}" ]] || rm -rf -- "${backup_dir}"
    [[ ! -e "${index_backup}" && ! -L "${index_backup}" ]] || rm -f -- "${index_backup}"
    [[ ! -e "${staging_path}" && ! -L "${staging_path}" ]] || rm -rf -- "${staging_path}"
    [[ ! -e "${candidate_path}" && ! -L "${candidate_path}" ]] || rm -f -- "${candidate_path}"
    linux_agent_fsync_skill_paths "${user_root}" || return 1
    linux_agent_remove_skill_commit_journal "${user_root}"
}

linux_agent_recover_pending_skill_commit_with_runtime_lock() {
    local user_root journal lock_path lock_fd rc owner_uid
    user_root="$(linux_agent_user_skills_dir)"
    journal="$(linux_agent_skill_commit_journal_path "${user_root}")"
    [[ ! -e "${journal}" && ! -L "${journal}" ]] && return 0
    [[ -d "${user_root}" && ! -L "${user_root}" ]] || return 1
    owner_uid="$(stat -c '%u' -- "${user_root}" 2>/dev/null || true)"
    [[ -n "${owner_uid}" && "${owner_uid}" == "$(id -u)" ]] || return 1
    lock_path="${user_root}/.commit.lock"
    if [[ -e "${lock_path}" && (! -f "${lock_path}" || -L "${lock_path}") ]]; then
        return 1
    fi
    exec {lock_fd}>>"${lock_path}" || return 1
    chmod 0600 "${lock_path}" 2>/dev/null || true
    if ! flock -x "${lock_fd}"; then
        exec {lock_fd}>&-
        return 1
    fi
    if linux_agent_recover_pending_skill_commit_locked "${user_root}"; then
        rc=0
    else
        rc=$?
    fi
    flock -u "${lock_fd}" 2>/dev/null || true
    exec {lock_fd}>&-
    return "${rc}"
}

linux_agent_recover_pending_skill_commit() {
    local rc=0

    linux_agent_runtime_lock_shared || return 1
    if linux_agent_recover_pending_skill_commit_with_runtime_lock; then
        rc=0
    else
        rc=$?
    fi
    linux_agent_runtime_lock_release
    return "${rc}"
}

linux_agent_normalize_staged_skill_permissions() {
    local staging_skill_dir="$1"
    local candidate_index="$2" path

    # A managed Web process owns the overlay, while the Runner only receives
    # read/execute access through the inherited Runner group.  mktemp creates
    # 0700 directories and files, so normalize the complete package before it
    # can become visible through the atomic rename.
    linux_agent_managed_mode_enabled || return 0
    [[ -d "${staging_skill_dir}" && ! -L "${staging_skill_dir}" ]] || return 1
    [[ -f "${candidate_index}" && ! -L "${candidate_index}" ]] || return 1

    while IFS= read -r -d '' path; do
        chmod 2750 -- "${path}" || return 1
    done < <(find "${staging_skill_dir}" -type d -print0)
    while IFS= read -r -d '' path; do
        chmod 0640 -- "${path}" || return 1
    done < <(find "${staging_skill_dir}" -type f -print0)
    if [[ -d "${staging_skill_dir}/scripts" ]]; then
        while IFS= read -r -d '' path; do
            chmod 0750 -- "${path}" || return 1
        done < <(find "${staging_skill_dir}/scripts" -type f -print0)
    fi
    chmod 0640 -- "${candidate_index}"
}

linux_agent_rollback_staged_skill() {
    local skill_dir="$1" index_path="$2" backup_dir="$3" index_backup="$4"
    local had_skill_backup="$5" had_index_backup="$6" new_skill="$7" new_index="$8"
    local rollback_failed=0

    if [[ "${new_skill}" == "1" && (-e "${skill_dir}" || -L "${skill_dir}") ]]; then
        rm -rf -- "${skill_dir}" || rollback_failed=1
    fi
    if [[ "${new_index}" == "1" && (-e "${index_path}" || -L "${index_path}") ]]; then
        rm -f -- "${index_path}" || rollback_failed=1
    fi
    if [[ "${had_skill_backup}" == "1" && -d "${backup_dir}" && ! -e "${skill_dir}" && ! -L "${skill_dir}" ]]; then
        mv -T -- "${backup_dir}" "${skill_dir}" || rollback_failed=1
    fi
    if [[ "${had_index_backup}" == "1" && -f "${index_backup}" && ! -e "${index_path}" && ! -L "${index_path}" ]]; then
        mv -T -- "${index_backup}" "${index_path}" || rollback_failed=1
    fi
    linux_agent_fsync_skill_paths "$(dirname -- "${skill_dir}")" >/dev/null 2>&1 || rollback_failed=1
    return "${rollback_failed}"
}

linux_agent_rollback_staged_skill_or_mark() {
    if ! linux_agent_rollback_staged_skill "$@"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="rollback_failed"
    fi
}

linux_agent_abort_skill_commit() {
    local user_root="$1"
    shift
    if linux_agent_rollback_staged_skill "$@"; then
        if ! linux_agent_remove_skill_commit_journal "${user_root}"; then
            LINUX_AGENT_SKILL_COMMIT_STATUS="rollback_failed"
        fi
    else
        LINUX_AGENT_SKILL_COMMIT_STATUS="rollback_failed"
    fi
}

linux_agent_refresh_skill_index_candidate() {
    local candidate_index="$1"
    local index_path="$2"
    local skill_name="$3"
    local description="${4:-}"
    local scripts_json="${5:-}"
    local section_path refreshed_path

    # The Web request builds a candidate before it acquires the commit lock.
    # Rebuild it from the index that is current *inside* the lock so concurrent
    # edits of different Skills cannot overwrite one another.  The optional
    # metadata arguments are supplied by the normal editor paths; the section
    # extraction fallback keeps the low-level/test adapter backwards compatible.
    if [[ -n "${scripts_json}" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"${scripts_json}"; then
        if [[ -f "${index_path}" ]]; then
            cp -- "${index_path}" "${candidate_index}"
        else
            : >"${candidate_index}"
        fi
        linux_agent_write_skill_index "${candidate_index}" "${skill_name}" "${description}" "${scripts_json}"
        return 0
    fi

    # Legacy callers already provide a rendered candidate.  Merge only its
    # requested heading into the latest index rather than installing stale
    # sections from a prior read.
    section_path="$(mktemp "$(dirname -- "${candidate_index}")/.INDEX-section.XXXXXX.tmp")" || return 1
    refreshed_path="$(mktemp "$(dirname -- "${candidate_index}")/.INDEX-refresh.XXXXXX.tmp")" || {
        rm -f -- "${section_path}"
        return 1
    }
    if ! grep -Fq -- "## ${skill_name}" "${candidate_index}"; then
        # Compatibility for low-level adapters that supply an opaque index
        # artifact. Normal editor candidates always contain the Skill heading.
        rm -f -- "${section_path}" "${refreshed_path}"
        return 0
    fi
    if [[ "$(grep -Fxc -- "## ${skill_name}" "${candidate_index}")" != "1" ]]; then
        rm -f -- "${section_path}" "${refreshed_path}"
        return 1
    fi
    awk -v heading="## ${skill_name}" '
        capture && $0 ~ /^## / && $0 != heading {exit}
        $0 == heading {capture=1}
        capture {print}
    ' "${candidate_index}" >"${section_path}"
    if [[ ! -s "${section_path}" ]]; then
        rm -f -- "${section_path}" "${refreshed_path}"
        return 1
    fi
    if [[ -f "${index_path}" ]]; then
        awk -v heading="## ${skill_name}" '
            $0 == heading {skip=1; next}
            skip && $0 ~ /^## / {skip=0}
            !skip {print}
        ' "${index_path}" >"${refreshed_path}"
    else
        {
            printf '# Skill Index\n\n'
            printf '工作模式会把此文件作为可用 skill 摘要上传给 AI。脚本模式仅允许执行这里登记且在对应 `SKILL.md` 中说明的脚本。\n\n'
        } >"${refreshed_path}"
    fi
    printf '\n' >>"${refreshed_path}"
    cat "${section_path}" >>"${refreshed_path}"
    chmod 0644 "${refreshed_path}"
    mv -T -- "${refreshed_path}" "${candidate_index}"
    rm -f -- "${section_path}"
}

linux_agent_commit_staged_skill_locked() {
    local skill_name="$1"
    local staging_skill_dir="$2"
    local candidate_index="$3"
    local description="${4:-}"
    local scripts_json="${5:-}"
    local skill_dir index_path backup_dir index_backup user_root unsafe validation cleanup_pending
    local skill_identity index_identity
    local original_had_skill=0 original_had_index=0
    local had_skill_backup=0 had_index_backup=0 new_skill=0 new_index=0
    LINUX_AGENT_SKILL_COMMIT_STATUS="commit_failed"
    LINUX_AGENT_SKILL_COMMIT_WARNING=""
    user_root="$(linux_agent_user_skills_dir)"
    skill_dir="${user_root}/${skill_name}"
    index_path="$(linux_agent_user_skill_index_path)"
    backup_dir="${user_root}/.backup.${skill_name}.${RANDOM}.$$"
    index_backup="${user_root}/.backup-index.${skill_name}.${RANDOM}.$$"

    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    if ! mkdir -p -- "${user_root}"; then
        return 1
    fi
    [[ -d "${user_root}" && ! -L "${user_root}" ]] || return 1
    if ! linux_agent_recover_pending_skill_commit_locked "${user_root}"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="commit_recovery_failed"
        return 1
    fi
    if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="skill_conflict"
        return 1
    fi
    [[ -d "${staging_skill_dir}" && ! -L "${staging_skill_dir}" &&
        "$(dirname -- "${staging_skill_dir}")" == "${user_root}" ]] || return 1
    [[ -f "${candidate_index}" && ! -L "${candidate_index}" &&
        "$(dirname -- "${candidate_index}")" == "${user_root}" ]] || return 1
    if [[ -e "${skill_dir}" || -L "${skill_dir}" ]]; then
        [[ -d "${skill_dir}" && ! -L "${skill_dir}" ]] || return 1
    fi
    if [[ -e "${index_path}" || -L "${index_path}" ]]; then
        [[ -f "${index_path}" && ! -L "${index_path}" ]] || return 1
    fi
    if [[ -d "${skill_dir}" ]]; then
        original_had_skill=1
        skill_identity="$(stat -c '%d:%i' -- "${skill_dir}" 2>/dev/null || true)"
        [[ -n "${skill_identity}" ]] || return 1
    else
        skill_identity=""
    fi
    if [[ -f "${index_path}" ]]; then
        original_had_index=1
        index_identity="$(stat -c '%d:%i' -- "${index_path}" 2>/dev/null || true)"
        [[ -n "${index_identity}" ]] || return 1
    else
        index_identity=""
    fi
    unsafe="$(find "${staging_skill_dir}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
    [[ -z "${unsafe}" ]] || return 1

    if ! linux_agent_refresh_skill_index_candidate \
        "${candidate_index}" "${index_path}" "${skill_name}" "${description}" "${scripts_json}"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="index_rebuild_failed"
        return 1
    fi
    # The candidate was constructed before the lock in the normal Web path;
    # validate again after rebuilding it from the current durable index.
    if [[ -n "${scripts_json}" ]] &&
        ! validation="$(linux_agent_validate_skill_at "${skill_name}" "${staging_skill_dir}" "${candidate_index}" user)"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="validation_failed"
        return 1
    elif [[ -n "${scripts_json}" ]] &&
        [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="validation_failed"
        return 1
    fi
    if ! linux_agent_fsync_skill_paths "${staging_skill_dir}" "${candidate_index}"; then
        return 1
    fi
    if ! linux_agent_web_sensitive_edits_enabled; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="sensitive_edits_disabled"
        return 1
    fi
    if ! linux_agent_normalize_staged_skill_permissions "${staging_skill_dir}" "${candidate_index}"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="permission_normalization_failed"
        return 1
    fi

    if ! linux_agent_write_skill_commit_journal \
        "${user_root}" "${skill_name}" "$(basename -- "${staging_skill_dir}")" \
        "$(basename -- "${candidate_index}")" "$(basename -- "${backup_dir}")" \
        "$(basename -- "${index_backup}")" "${original_had_skill}" "${original_had_index}" \
        "${skill_identity}" "${index_identity}" prepared; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="commit_journal_unavailable"
        return 1
    fi

    if [[ -d "${skill_dir}" ]]; then
        if ! mv -T -- "${skill_dir}" "${backup_dir}"; then
            linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
                "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
            return 1
        fi
        had_skill_backup=1
    fi
    if [[ -f "${index_path}" ]]; then
        if ! mv -T -- "${index_path}" "${index_backup}"; then
            linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
                "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
            return 1
        fi
        had_index_backup=1
    fi

    if ! linux_agent_web_sensitive_edits_enabled; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="sensitive_edits_disabled"
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    if ! mv -T -- "${staging_skill_dir}" "${skill_dir}"; then
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    new_skill=1

    if ! linux_agent_web_sensitive_edits_enabled; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="sensitive_edits_disabled"
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    if ! mv -T -- "${candidate_index}" "${index_path}"; then
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    new_index=1

    if ! linux_agent_fsync_skill_paths "${user_root}"; then
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    if ! linux_agent_write_skill_commit_journal \
        "${user_root}" "${skill_name}" "$(basename -- "${staging_skill_dir}")" \
        "$(basename -- "${candidate_index}")" "$(basename -- "${backup_dir}")" \
        "$(basename -- "${index_backup}")" "${original_had_skill}" "${original_had_index}" \
        "${skill_identity}" "${index_identity}" committed; then
        linux_agent_abort_skill_commit "${user_root}" "${skill_dir}" "${index_path}" "${backup_dir}" "${index_backup}" \
            "${had_skill_backup}" "${had_index_backup}" "${new_skill}" "${new_index}"
        return 1
    fi
    cleanup_pending=0
    if [[ "${had_skill_backup}" == "1" ]] && ! rm -rf -- "${backup_dir}"; then
        cleanup_pending=1
    fi
    if [[ "${had_index_backup}" == "1" ]] && ! rm -f -- "${index_backup}"; then
        cleanup_pending=1
    fi
    if ((cleanup_pending == 0)) && ! linux_agent_fsync_skill_paths "${user_root}"; then
        cleanup_pending=1
    fi
    if ((cleanup_pending == 0)) && ! linux_agent_remove_skill_commit_journal "${user_root}"; then
        cleanup_pending=1
    fi
    if ((cleanup_pending == 1)); then
        # The new package and index are already durable.  Keep any old backup
        # paths for recovery and report a warning instead of making callers
        # retry a commit that has already taken effect.
        LINUX_AGENT_SKILL_COMMIT_WARNING="commit_cleanup_pending"
    fi
    LINUX_AGENT_SKILL_COMMIT_STATUS="edited"
    return 0
}

linux_agent_commit_staged_skill() {
    local skill_name="$1"
    local staging_skill_dir="$2"
    local candidate_index="$3"
    local description="${4:-}"
    local scripts_json="${5:-}"
    local user_root lock_path lock_fd rc

    user_root="$(linux_agent_user_skills_dir)"
    mkdir -p -- "${user_root}" || return 1
    [[ -d "${user_root}" && ! -L "${user_root}" ]] || return 1
    lock_path="${user_root}/.commit.lock"
    if [[ -e "${lock_path}" && (! -f "${lock_path}" || -L "${lock_path}") ]]; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="commit_lock_invalid"
        return 1
    fi
    if ! exec {lock_fd}>>"${lock_path}"; then
        LINUX_AGENT_SKILL_COMMIT_STATUS="commit_lock_unavailable"
        return 1
    fi
    chmod 0600 "${lock_path}" 2>/dev/null || true
    if ! flock -x "${lock_fd}"; then
        exec {lock_fd}>&-
        LINUX_AGENT_SKILL_COMMIT_STATUS="commit_lock_unavailable"
        return 1
    fi
    if linux_agent_commit_staged_skill_locked \
        "${skill_name}" "${staging_skill_dir}" "${candidate_index}" \
        "${description}" "${scripts_json}"; then
        rc=0
    else
        rc=$?
    fi
    flock -u "${lock_fd}" 2>/dev/null || true
    exec {lock_fd}>&-
    return "${rc}"
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
    local validation global_validation committed_scripts observer_gate observer_subject audit_rc audit_payload user_root
    local script_items=()

    review_json="$(linux_agent_review_edit_package "${edit_json}")"
    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        jq -cn --argjson review "${review_json}" \
            '{ok:false, status:($review.status // "blocked"), review:$review}'
        return 0
    fi

    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    user_root="$(linux_agent_user_skills_dir)"
    if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
        jq -cn --arg skill "${skill_name}" '{ok:false, status:"skill_conflict", code:"skill_conflict", skill:$skill, error:"A user Skill may not replace a built-in Skill."}'
        return 0
    fi
    observer_subject="$(jq -cn --arg skill "${skill_name}" '{kind:"skill_edit_apply", skill:$skill}')"
    if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
        ! observer_gate="$(linux_agent_observer_execution_gate "edit_apply" "${observer_subject}")"; then
        printf '%s\n' "${observer_gate}"
        return 0
    fi
    description="$(jq -r '.skill.description' <<<"${edit_json}")"
    skill_dir="${user_root}/${skill_name}"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    edit_root="${LINUX_AGENT_TMP_DIR}/edit/${skill_name}"
    mkdir -p "${user_root}"
    staging_skill_dir="$(mktemp -d "${user_root}/.staging.${skill_name}.XXXXXX")"
    staging_scripts_dir="${staging_skill_dir}/scripts"
    candidate_index="$(mktemp "${user_root}/.INDEX.${skill_name}.XXXXXX.tmp")"
    committed_scripts="$(jq -c '[.scripts[].name]' <<<"${edit_json}")"

    mkdir -p "${staging_scripts_dir}" "${staging_skill_dir}/references" "${staging_skill_dir}/assets"
    mapfile -t script_items < <(jq -c '.scripts[]' <<<"${edit_json}")

    for script in "${script_items[@]}"; do
        [[ -z "${script}" ]] && continue
        local script_name content script_path
        script_name="$(jq -r '.name' <<<"${script}")"
        content="$(jq -r '.content' <<<"${script}")"
        script_path="${staging_scripts_dir}/${script_name}"
        printf '%s\n' "${content}" >"${script_path}"
        chmod +x "${script_path}"
    done

    linux_agent_render_skill_md "${skill_name}" "${description}" "${scripts_json}" >"${staging_skill_dir}/SKILL.md"
    linux_agent_render_user_skill_manifest "${skill_name}" "${description}" "${scripts_json}" >"${staging_skill_dir}/manifest.json"
    if [[ -f "$(linux_agent_user_skill_index_path)" ]]; then
        cp "$(linux_agent_user_skill_index_path)" "${candidate_index}"
    else
        : >"${candidate_index}"
    fi
    linux_agent_write_skill_index "${candidate_index}" "${skill_name}" "${description}" "${scripts_json}"
    validation="$(linux_agent_validate_skill_at "${skill_name}" "${staging_skill_dir}" "${candidate_index}" user)"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        jq -cn --arg skill "${skill_name}" --argjson validation "${validation}" --argjson review "${review_json}" \
            '{ok:false, status:"validation_failed", skill:$skill, validation:$validation, review:$review}'
        return 0
    fi

    audit_payload="$(jq -cn --arg skill "${skill_name}" --argjson scripts "${committed_scripts}" '{skill:$skill, scripts:$scripts}')"
    audit_rc=0
    linux_agent_audit_require_event "edit_commit_started" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        linux_agent_audit_failure_result "${audit_rc}" "edit_commit_started"
        return 0
    fi

    if ! linux_agent_web_sensitive_edits_enabled; then
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi

    if ! linux_agent_commit_staged_skill \
        "${skill_name}" "${staging_skill_dir}" "${candidate_index}" \
        "${description}" "${scripts_json}"; then
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        if [[ "${LINUX_AGENT_SKILL_COMMIT_STATUS:-}" == "sensitive_edits_disabled" ]]; then
            linux_agent_sensitive_edits_disabled_result
        else
            jq -cn --arg skill "${skill_name}" --arg status "${LINUX_AGENT_SKILL_COMMIT_STATUS:-commit_failed}" \
                '{ok:false, status:$status, code:$status, skill:$skill}'
        fi
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
        --arg warning "${LINUX_AGENT_SKILL_COMMIT_WARNING:-}" \
        '{ok:true, status:"edited", skill:$skill, skill_dir:$skill_dir, scripts:$scripts, validation:$validation, global_validation:$global_validation, review:$review}
         + (if $warning == "" then {} else {warning:$warning} end)'
}

linux_agent_apply_skill_edit_package() {
    local edit_json="$1"
    local skill_name description skill_dir scripts_json edit_root staging_skill_dir staging_scripts_dir candidate_index
    local validation global_validation committed_scripts observer_gate observer_subject audit_rc audit_payload user_root
    local script_items=()
    skill_name="$(jq -r '.skill.name' <<<"${edit_json}")"
    user_root="$(linux_agent_user_skills_dir)"
    if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
        jq -cn --arg skill "${skill_name}" '{ok:false, status:"skill_conflict", code:"skill_conflict", skill:$skill, error:"A user Skill may not replace a built-in Skill."}'
        return 0
    fi
    observer_subject="$(jq -cn --arg skill "${skill_name}" '{kind:"skill_edit_apply", skill:$skill}')"
    if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
        ! observer_gate="$(linux_agent_observer_execution_gate "edit_apply" "${observer_subject}")"; then
        printf '%s\n' "${observer_gate}"
        return 0
    fi
    description="$(jq -r '.skill.description' <<<"${edit_json}")"
    skill_dir="${user_root}/${skill_name}"
    scripts_json="$(jq -c '.scripts' <<<"${edit_json}")"
    edit_root="${LINUX_AGENT_TMP_DIR}/edit/${skill_name}"
    mkdir -p "${user_root}"
    staging_skill_dir="$(mktemp -d "${user_root}/.staging.${skill_name}.XXXXXX")"
    staging_scripts_dir="${staging_skill_dir}/scripts"
    candidate_index="$(mktemp "${user_root}/.INDEX.${skill_name}.XXXXXX.tmp")"
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
            rm -rf "${staging_skill_dir}"
            rm -f "${candidate_index}"
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
        printf '%s\n' "${content}" >"${script_path}"
        chmod +x "${script_path}"
        scripts_json="$(jq -c --arg name "${script_name}" --arg content "${content}" \
            'map(if .name == $name then .content = $content else . end)' <<<"${scripts_json}")"
    done

    linux_agent_render_skill_md "${skill_name}" "${description}" "${scripts_json}" >"${staging_skill_dir}/SKILL.md"
    linux_agent_render_user_skill_manifest "${skill_name}" "${description}" "${scripts_json}" >"${staging_skill_dir}/manifest.json"
    if [[ -f "$(linux_agent_user_skill_index_path)" ]]; then
        cp "$(linux_agent_user_skill_index_path)" "${candidate_index}"
    else
        : >"${candidate_index}"
    fi
    linux_agent_write_skill_index "${candidate_index}" "${skill_name}" "${description}" "${scripts_json}"
    validation="$(linux_agent_validate_skill_at "${skill_name}" "${staging_skill_dir}" "${candidate_index}" user)"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf "${edit_root}"
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        jq -cn --arg skill "${skill_name}" --argjson validation "${validation}" \
            '{ok:false, status:"validation_failed", skill:$skill, validation:$validation}'
        return 0
    fi

    audit_payload="$(jq -cn --arg skill "${skill_name}" --argjson scripts "${committed_scripts}" '{skill:$skill, scripts:$scripts}')"
    audit_rc=0
    linux_agent_audit_require_event "edit_commit_started" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        rm -rf "${edit_root}"
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        linux_agent_audit_failure_result "${audit_rc}" "edit_commit_started"
        return 0
    fi

    if ! linux_agent_web_sensitive_edits_enabled; then
        rm -rf "${edit_root}"
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi

    if ! linux_agent_commit_staged_skill \
        "${skill_name}" "${staging_skill_dir}" "${candidate_index}" \
        "${description}" "${scripts_json}"; then
        rm -rf "${edit_root}"
        rm -rf "${staging_skill_dir}"
        rm -f "${candidate_index}"
        if [[ "${LINUX_AGENT_SKILL_COMMIT_STATUS:-}" == "sensitive_edits_disabled" ]]; then
            linux_agent_sensitive_edits_disabled_result
        else
            jq -cn --arg skill "${skill_name}" --arg status "${LINUX_AGENT_SKILL_COMMIT_STATUS:-commit_failed}" \
                '{ok:false, status:$status, code:$status, skill:$skill}'
        fi
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
        --arg warning "${LINUX_AGENT_SKILL_COMMIT_WARNING:-}" \
        '{ok:true, status:"edited", skill:$skill, skill_dir:$skill_dir, scripts:$scripts, validation:$validation, global_validation:$global_validation}
         + (if $warning == "" then {} else {warning:$warning} end)'
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
