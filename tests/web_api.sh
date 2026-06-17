#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((23000 + RANDOM % 1000))" "${tmp_root}"

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
        "${ROOT_DIR}/web" \
        "${target}/"
    configure_fake_ai "${target}"
}

health="$(bash "${ROOT_DIR}/bin/agent" api health)"
jq -e '.ok == true and .web.host == "127.0.0.1"' <<<"${health}" >/dev/null

tools="$(bash "${ROOT_DIR}/bin/agent" api tools list)"
jq -e '.ok == true and ([.scripts[].ref] | index("ops-basic/resource-inspect"))' <<<"${tools}" >/dev/null

project_work="${tmp_root}/project-work-api"
copy_project "${project_work}"
work_run="$(cd "${project_work}" && bash bin/agent api work run '{"input":"查看cpu占用"}' 2>/dev/null)"
jq -e '.ok == true and .status == "executed" and .execution.auto_executed_count == 1 and .execution.results[0].result.execution_proxy.requested_privilege == "least"' <<<"${work_run}" >/dev/null

approval_first="$(cd "${project_work}" && bash bin/agent api work run '{"input":"帮我检查磁盘空间是否异常"}' 2>/dev/null)"
jq -e '.ok == false and .status == "approval_required" and .response.response_type == "work_plan"' <<<"${approval_first}" >/dev/null
approval_payload="$(
    jq -cn \
        --arg input "帮我检查磁盘空间是否异常" \
        --argjson response "$(jq -c '.response' <<<"${approval_first}")" \
        --argjson context "$(jq -c '.context' <<<"${approval_first}")" \
        '{input:$input, response:$response, context:$context, decisions:["y","y"]}'
)"
approval_second="$(cd "${project_work}" && bash bin/agent api work run "${approval_payload}" 2>/dev/null)"
jq -e '.ok == true and .status == "executed" and .response.response_type == "work_plan"' <<<"${approval_second}" >/dev/null

project_missing="${tmp_root}/project-missing-ai"
copy_project "${project_missing}"
tmp_config="$(mktemp)"
jq '.api_key = "please-set-your-api-key"' "${project_missing}/config/config.json" > "${tmp_config}"
mv "${tmp_config}" "${project_missing}/config/config.json"
missing_ai="$(cd "${project_missing}" && bash bin/agent api work run '{"input":"查看cpu占用"}' 2>/dev/null)"
jq -e '.ok == false and .status == "ai_config_missing"' <<<"${missing_ai}" >/dev/null

script_review="$(bash "${ROOT_DIR}/bin/agent" api script review '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1}}')"
jq -e '.ok == true and .review.risk_level == "low"' <<<"${script_review}" >/dev/null

script_run="$(bash "${ROOT_DIR}/bin/agent" api script run '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1},"approve":true}' 2>/dev/null)"
jq -e '.ok == true and .status == "executed" and .result.output.tool == "system.resource.inspect" and .result.execution_proxy.requested_privilege == "least"' <<<"${script_run}" >/dev/null

terminal_run="$(bash "${ROOT_DIR}/bin/agent" api terminal run '{"command":"printf api-ok"}' 2>/dev/null)"
jq -e '.ok == true and .result.stdout_preview == "api-ok" and .result.execution_proxy.requested_privilege == "least"' <<<"${terminal_run}" >/dev/null

terminal_review="$(bash "${ROOT_DIR}/bin/agent" api terminal review '{"command":"sudo systemctl restart nginx"}')"
jq -e '.ok == true and .status == "approval_required" and .review.risk_level == "high"' <<<"${terminal_review}" >/dev/null

terminal_approval_required="$(bash "${ROOT_DIR}/bin/agent" api terminal run '{"command":"sudo systemctl restart nginx"}' 2>/dev/null)"
jq -e '.ok == false and .status == "approval_required"' <<<"${terminal_approval_required}" >/dev/null

project_edit="${tmp_root}/project-edit-api"
copy_project "${project_edit}"
edit_plan="$(cd "${project_edit}" && bash bin/agent api edit plan '{"input":"创建一个 API 测试 skill"}' 2>/dev/null)"
edit_json="$(jq -c '.edit' <<<"${edit_plan}")"
review_payload="$(jq -cn --argjson edit "${edit_json}" '{edit:$edit}')"
edit_review="$(cd "${project_edit}" && bash bin/agent api edit review "${review_payload}")"
jq -e '.ok == true and .status == "approved"' <<<"${edit_review}" >/dev/null

apply_payload="$(jq -cn --argjson edit "${edit_json}" '{edit:$edit, approve:true}')"
edit_apply="$(cd "${project_edit}" && bash bin/agent api edit apply "${apply_payload}" 2>/dev/null)"
jq -e '.ok == true and .status == "edited"' <<<"${edit_apply}" >/dev/null
grep -q 'generated skill placeholder' "${project_edit}/skills/custom-generated/scripts/generated.sh"

invalid_edit="$(cd "${project_edit}" && bash bin/agent api edit plan '{"input":"无效响应"}' 2>/dev/null)"
jq -e '.ok == false and .status == "ai_invalid_response"' <<<"${invalid_edit}" >/dev/null

audit_list="$(bash "${ROOT_DIR}/bin/agent" api audit list '{"limit":5}')"
jq -e '.ok == true and (.sessions | type == "array")' <<<"${audit_list}" >/dev/null

printf 'web_api: ok\n'
