#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"
linux_agent_test_install_failure_trap "interactive"

# shellcheck source=../lib/interactive.sh
source "${ROOT_DIR}/lib/interactive.sh"

! linux_agent_slash_menu_rows | grep -q '^/mode[[:space:]]'
[[ "$(linux_agent_slash_command_complete "/mo")" == "/mode" ]]
[[ "$(linux_agent_slash_command_complete "/terminal")" == "/terminal" ]]
if linux_agent_slash_command_complete "//" >/dev/null 2>&1; then
    printf 'expected // to be rejected as an unknown slash command\n' >&2
    exit 1
fi

bare_slash_output="$(
    linux_agent_test_capture "bare slash menu" 30 "${ROOT_DIR}" merge \
        bash bin/agent <<<$'/\n/exit\n'
)"
grep -q '当前环境不能打开交互菜单' <<<"${bare_slash_output}"
if grep -q '已切换到工作模式' <<<"${bare_slash_output}"; then
    printf 'bare slash unexpectedly auto-selected /work\n' >&2
    exit 1
fi

slash_output="$(
    linux_agent_test_capture "unknown slash command" 30 "${ROOT_DIR}" merge \
        bash bin/agent <<<$'//\n/exit\n'
)"
grep -q '未知 / 命令: //' <<<"${slash_output}"
if grep -q '\[sudo\] password' <<<"${slash_output}"; then
    printf 'unknown slash command unexpectedly reached sudo probing\n' >&2
    exit 1
fi

terminal_output="$(
    linux_agent_test_capture "interactive terminal mode" 60 "${ROOT_DIR}" merge \
        bash bin/agent <<<$'/terminal\nprintf terminal-mode-ok\ny\n/work\n/exit\n'
)"
grep -q 'terminal-mode-ok' <<<"${terminal_output}"
grep -q '终端执行结果: 成功' <<<"${terminal_output}"
grep -q '终端输出' <<<"${terminal_output}"
grep -q '已切换到终端模式' <<<"${terminal_output}"

terminal_json_output="$(
    linux_agent_test_capture "terminal structured output" 45 "${ROOT_DIR}" merge \
        bash bin/agent terminal "printf '%s\n' '{\"ok\":true,\"tool\":\"demo.terminal\",\"summary\":\"json-ok\",\"count\":2}'" \
        <<<$'y\n'
)"
grep -q '终端执行结果: 成功' <<<"${terminal_json_output}"
grep -q '摘要' <<<"${terminal_json_output}"
grep -q 'json-ok' <<<"${terminal_json_output}"
grep -q 'count: 2' <<<"${terminal_json_output}"
! grep -q '"tool"' <<<"${terminal_json_output}"

terminal_machine_json="$(
    linux_agent_test_capture "terminal machine JSON" 45 "${ROOT_DIR}" discard \
        env LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent terminal "printf terminal-json-mode" \
        <<<$'y\n'
)"
jq -e '.status == "executed" and ([.output_blocks[]? | select(.kind == "stdout") | .text] | first) == "terminal-json-mode"' <<<"${terminal_machine_json}" >/dev/null

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((24000 + RANDOM % 1000))" "${tmp_root}"

if command -v script >/dev/null 2>&1; then
    backspace_project="${tmp_root}/project-backspace"
    mkdir -p "${backspace_project}"
    cp -a \
        "${ROOT_DIR}/bin" \
        "${ROOT_DIR}/config" \
        "${ROOT_DIR}/lib" \
        "${ROOT_DIR}/policies" \
        "${ROOT_DIR}/prompts" \
        "${ROOT_DIR}/skills" \
        "${backspace_project}/"
    configure_fake_ai "${backspace_project}"
    tmp_config="$(mktemp)"
    jq '.observer.enabled="disabled" | .approvals.auto.shell_readonly=true' "${backspace_project}/config/config.json" >"${tmp_config}"
    mv "${tmp_config}" "${backspace_project}/config/config.json"
    backspace_typescript="${tmp_root}/backspace.typescript"
    linux_agent_test_run "PTY backspace handling" 60 "${backspace_project}" discard \
        script -q -e -c "bash bin/agent" "${backspace_typescript}" \
        <<<$'/terminal\necho 中文AB\177\177CD\n/exit\n'
    backspace_output="$(tr -d '\r' <"${backspace_typescript}")"
    grep -q '\[terminal\]> echo 中文CD' <<<"${backspace_output}"
    grep -q '中文CD' <<<"${backspace_output}"
    ! grep -q '\[terminal\]> echo 中文ABCD' <<<"${backspace_output}"
fi

copy_project() {
    local target="$1"
    mkdir -p "${target}"
    cp -a \
        "${ROOT_DIR}/bin" \
        "${ROOT_DIR}/config" \
        "${ROOT_DIR}/lib" \
        "${ROOT_DIR}/policies" \
        "${ROOT_DIR}/prompts" \
        "${ROOT_DIR}/skills" \
        "${target}/"
    configure_fake_ai "${target}"
}

project_session="${tmp_root}/project-session"
copy_project "${project_session}"
session_output="$(
    linux_agent_test_capture "interactive session audit" 90 "${project_session}" merge \
        bash bin/agent <<<$'/terminal\nprintf one\ny\nprintf two\ny\n/exit\n'
)"
grep -q 'one' <<<"${session_output}"
grep -q 'two' <<<"${session_output}"
session_log_count="$(find "${project_session}/logs" -name '*.jsonl' | wc -l | tr -d ' ')"
[[ "${session_log_count}" -eq 1 ]]
session_log="$(find "${project_session}/logs" -name '*.jsonl' -print -quit)"
[[ "$(jq -r 'select(.stage=="session_started") | .stage' "${session_log}" | wc -l | tr -d ' ')" -eq 1 ]]
[[ "$(jq -r 'select(.stage=="session_finished") | .stage' "${session_log}" | wc -l | tr -d ' ')" -eq 1 ]]
[[ "$(jq -r 'select(.stage=="turn_started") | .stage' "${session_log}" | wc -l | tr -d ' ')" -eq 2 ]]
observer_line="$(jq -r '.stage' "${session_log}" | awk '/^observer_/ {print NR; exit}')"
turn_line="$(jq -r '.stage' "${session_log}" | awk '$0=="turn_started" {print NR; exit}')"
[[ -n "${observer_line}" && -n "${turn_line}" && "${observer_line}" -lt "${turn_line}" ]]
session_id="$(basename "${session_log}" .jsonl)"
audit_output="$(
    linux_agent_test_capture "interactive audit report" 30 "${project_session}" inherit \
        bash bin/agent audit "${session_id}"
)"
grep -q '# 审计报告' <<<"${audit_output}"
[[ "$(find "${project_session}/logs" -name '*.jsonl' | wc -l | tr -d ' ')" -eq 1 ]]

project_context="${tmp_root}/project-context"
copy_project "${project_context}"
context_output="$(
    linux_agent_test_capture "interactive conversation context" 120 "${project_context}" merge \
        bash bin/agent <<<$'第一轮上下文测试\n第二轮上下文测试\n/exit\n'
)"
grep -q '已收到请求：第一轮上下文测试' <<<"${context_output}"
grep -q '已收到请求：第二轮上下文测试' <<<"${context_output}"
context_log="$(find "${project_context}/logs" -name '*.jsonl' -print -quit)"
mapfile -t context_turn_counts < <(
    jq -r '
        select(.stage == "request_context_built")
        | if (.payload.conversation_turns? | type) == "number" then .payload.conversation_turns
          elif (.payload.conversation_context? | type) == "array" then (.payload.conversation_context | length)
          else -1 end
    ' "${context_log}"
)
[[ "${#context_turn_counts[@]}" -eq 2 ]]
[[ "${context_turn_counts[0]}" == "0" ]]
[[ "${context_turn_counts[1]}" == "1" ]]
[[ -z "$(find "${project_context}/tmp" -name conversation-history.json -print -quit)" ]]

project_ctrlz="${tmp_root}/project-ctrlz"
copy_project "${project_ctrlz}"
ctrlz_output="$(
    linux_agent_test_capture "interactive Ctrl-Z" 30 "${project_ctrlz}" merge \
        bash bin/agent <<<$'\032\n'
)"
grep -q 'Linux 运维 Agent 已就绪' <<<"${ctrlz_output}"
ctrlz_log="$(find "${project_ctrlz}/logs" -name '*.jsonl' -print -quit)"
grep -q '"event":"ctrl_z"' "${ctrlz_log}"
[[ "$(jq -r 'select(.stage=="session_finished") | .payload.status' "${ctrlz_log}" | tail -1)" == "exited_ctrl_z" ]]

project_edit="${tmp_root}/project-edit"
copy_project "${project_edit}"
editor_modify="${tmp_root}/editor-modify.sh"
cat >"${editor_modify}" <<'EOF'
#!/usr/bin/env bash
printf '\n# manual edit marker\n' >> "$1"
EOF
chmod +x "${editor_modify}"

edit_output="$(
    linux_agent_test_capture "interactive edit save" 90 "${project_edit}" merge \
        env EDITOR="${editor_modify}" bash bin/agent edit "创建一个测试 skill"
)"
grep -q 'Skill 编辑计划' <<<"${edit_output}"
grep -q 'Skill 保存结果: 成功' <<<"${edit_output}"
grep -q '候选校验: 通过' <<<"${edit_output}"
! grep -q '"response_type":' <<<"${edit_output}"
! grep -q '"content":' <<<"${edit_output}"
! grep -q '"validation":' <<<"${edit_output}"
! grep -q '"ok": true' <<<"${edit_output}"
! grep -q '批准保存该脚本' <<<"${edit_output}"
grep -q 'manual edit marker' "${project_edit}/data/skills/custom-generated/scripts/generated.sh"
grep -R -q 'script_manual_edit' "${project_edit}/logs"
[[ ! -d "${project_edit}/sessions" ]]

project_edit_json="${tmp_root}/project-edit-json"
copy_project "${project_edit_json}"
edit_json_output="$(
    linux_agent_test_capture "interactive edit JSON" 90 "${project_edit_json}" merge \
        env EDITOR="${editor_modify}" LINUX_AGENT_OUTPUT_JSON=1 \
        bash bin/agent edit "创建一个 JSON 兼容测试 skill"
)"
grep -q '"response_type": "skill_edit"' <<<"${edit_json_output}"
grep -q '"ok": true' <<<"${edit_json_output}"

project_blocked="${tmp_root}/project-blocked"
copy_project "${project_blocked}"
editor_block="${tmp_root}/editor-block.sh"
cat >"${editor_block}" <<'EOF'
#!/usr/bin/env bash
printf '#!/usr/bin/env bash\nrm -rf /\n' > "$1"
EOF
chmod +x "${editor_block}"

blocked_output="$(
    linux_agent_test_capture "interactive blocked edit" 90 "${project_blocked}" merge \
        env EDITOR="${editor_block}" bash bin/agent edit "创建一个危险测试 skill" || true
)"
grep -q '脚本审查: 阻断' <<<"${blocked_output}"
grep -q 'Skill 保存结果: 失败，status=blocked' <<<"${blocked_output}"
[[ ! -f "${project_blocked}/skills/custom-generated/scripts/generated.sh" ]]
[[ ! -d "${project_blocked}/skills/custom-generated" ]]
[[ ! -f "${project_blocked}/data/skills/custom-generated/scripts/generated.sh" ]]
[[ ! -d "${project_blocked}/data/skills/custom-generated" ]]

project_failed="${tmp_root}/project-failed"
copy_project "${project_failed}"
editor_fail="${tmp_root}/editor-fail.sh"
cat >"${editor_fail}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${editor_fail}"

failed_output="$(
    linux_agent_test_capture "interactive failed editor" 90 "${project_failed}" merge \
        env EDITOR="${editor_fail}" bash bin/agent edit "创建一个失败测试 skill" || true
)"
grep -q 'Skill 保存结果: 失败，status=editor_failed' <<<"${failed_output}"
[[ ! -d "${project_failed}/skills/custom-generated" ]]
[[ ! -d "${project_failed}/data/skills/custom-generated" ]]

project_cancelled="${tmp_root}/project-cancelled"
copy_project "${project_cancelled}"
editor_cancel="${tmp_root}/editor-cancel.sh"
cat >"${editor_cancel}" <<'EOF'
#!/usr/bin/env bash
# 模拟 vi :q!：正常退出，但不保存文件。
exit 0
EOF
chmod +x "${editor_cancel}"

cancelled_output="$(
    linux_agent_test_capture "interactive cancelled editor" 90 "${project_cancelled}" merge \
        env EDITOR="${editor_cancel}" bash bin/agent edit "创建一个取消保存测试 skill" || true
)"
grep -q 'Skill 保存结果: 失败，status=editor_cancelled' <<<"${cancelled_output}"
grep -q '编辑器未保存脚本' <<<"${cancelled_output}"
[[ ! -d "${project_cancelled}/skills/custom-generated" ]]
[[ ! -d "${project_cancelled}/data/skills/custom-generated" ]]

project_revised_edit="${tmp_root}/project-revised-edit"
copy_project "${project_revised_edit}"
editor_cancel_then_save="${tmp_root}/editor-cancel-then-save.sh"
cat >"${editor_cancel_then_save}" <<'EOF'
#!/usr/bin/env bash
count_file="${EDITOR_COUNTER:?}"
count="$(cat "${count_file}" 2>/dev/null || printf 0)"
count=$((count + 1))
printf '%s' "${count}" > "${count_file}"
if [[ "${count}" -eq 1 ]]; then
    exit 0
fi
printf '\n# revised edit marker\n' >> "$1"
EOF
chmod +x "${editor_cancel_then_save}"

revised_edit_output="$(
    linux_agent_test_capture "interactive revised edit" 120 "${project_revised_edit}" merge \
        env EDITOR_COUNTER="${tmp_root}/editor-count" EDITOR="${editor_cancel_then_save}" \
        bash bin/agent edit "创建一个需要修改后保存的 skill" \
        <<<$'请重新生成更简单的脚本\n'
)"
grep -q '编辑器未保存脚本' <<<"${revised_edit_output}"
grep -q 'Skill 保存结果: 成功' <<<"${revised_edit_output}"
grep -q 'revised edit marker' "${project_revised_edit}/data/skills/custom-generated/scripts/generated.sh"
grep -R -q 'edit_revision_requested' "${project_revised_edit}/logs"
[[ ! -d "${project_revised_edit}/sessions" ]]

project_vi="${tmp_root}/project-vi"
copy_project "${project_vi}"
fake_bin="${tmp_root}/fake-bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/vi" <<'EOF'
#!/usr/bin/env bash
printf '\n# default vi marker\n' >> "$1"
EOF
chmod +x "${fake_bin}/vi"

vi_output="$(
    linux_agent_test_capture "interactive default vi" 90 "${project_vi}" merge \
        env -u EDITOR PATH="${fake_bin}:${PATH}" bash bin/agent edit "创建一个默认 vi 测试 skill"
)"
grep -q 'Skill 保存结果: 成功' <<<"${vi_output}"
grep -q 'default vi marker' "${project_vi}/data/skills/custom-generated/scripts/generated.sh"

project_global_warning="${tmp_root}/project-global-warning"
copy_project "${project_global_warning}"
mkdir -p "${project_global_warning}/skills/broken-empty/scripts"
global_warning_output="$(
    linux_agent_test_capture "interactive edit with global warning" 90 \
        "${project_global_warning}" merge env EDITOR="${editor_modify}" \
        bash bin/agent edit "创建一个带历史坏 skill 的测试"
)"
grep -q 'Skill 保存结果: 成功' <<<"${global_warning_output}"
grep -q '全局校验: 通过' <<<"${global_warning_output}"
grep -q 'SKILL_INDEX_ENTRY_MISSING' <<<"${global_warning_output}"
grep -q 'manual edit marker' "${project_global_warning}/data/skills/custom-generated/scripts/generated.sh"

printf 'interactive: ok\n'
