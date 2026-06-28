#!/usr/bin/env bash

set -euo pipefail

linux_agent_risk_rules_path() {
    printf '%s/policies/risk-rules.json\n' "${LINUX_AGENT_ROOT}"
}

linux_agent_policy_add_finding() {
    local findings="$1"
    local severity="$2"
    local code="$3"
    local pattern="$4"
    local message="$5"
    local source="${6:-policy}"
    local category="${7:-custom_rule}"
    local action

    if [[ "${severity}" == "critical" ]]; then
        action="block"
    else
        action="approve"
    fi

    jq -cn \
        --argjson prior "${findings}" \
        --arg severity "${severity}" \
        --arg code "${code}" \
        --arg pattern "${pattern}" \
        --arg message "${message}" \
        --arg source "${source}" \
        --arg category "${category}" \
        --arg action "${action}" \
        '$prior + [{
            severity:$severity,
            code:$code,
            pattern:$pattern,
            message:$message,
            source:$source,
            category:$category,
            action:$action
        }]'
}

linux_agent_policy_match_patterns() {
    local pattern_path="$1"
    local text="$2"
    local severity="$3"
    local code="$4"
    local findings='[]'
    local pattern

    while IFS= read -r pattern; do
        [[ -z "${pattern}" ]] && continue
        if printf '%s\n' "${text}" | grep -Eiq -- "${pattern}"; then
            findings="$(linux_agent_policy_add_finding \
                "${findings}" "${severity}" "${code}" "${pattern}" \
                "命令或脚本文本命中自定义策略规则。" \
                "policy" "custom_rule")"
        fi
    done < <(jq -r "${pattern_path}[]? // empty" "$(linux_agent_risk_rules_path)" 2>/dev/null || true)

    printf '%s\n' "${findings}"
}

linux_agent_policy_ast_findings() {
    local text="$1"
    local mode="${2:-local}"
    local guard="${LINUX_AGENT_ROOT}/lib/command_guard.py"
    local review_text

    if [[ "${text}" == skill_script=* ]]; then
        printf '[]\n'
        return 0
    fi

    if [[ ! -f "${guard}" ]]; then
        local policy_dir
        policy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${policy_dir}/command_guard.py" ]]; then
            guard="${policy_dir}/command_guard.py"
        fi
    fi

    review_text="${text}"
    if [[ ! -f "${guard}" ]] || ! command -v python3 >/dev/null 2>&1; then
        linux_agent_policy_add_finding \
            '[]' "critical" "POLICY_GUARD_UNAVAILABLE" "python3/lib/command_guard.py" \
            "AST 命令守卫不可用，拒绝执行。" \
            "policy" "syntax"
        return 0
    fi

    if ! printf '%s' "${review_text}" | python3 "${guard}" --mode "${mode}" 2>/dev/null; then
        linux_agent_policy_add_finding \
            '[]' "critical" "POLICY_GUARD_FAILED" "lib/command_guard.py" \
            "AST 命令守卫执行失败，拒绝执行。" \
            "policy" "syntax"
        return 0
    fi
}

linux_agent_policy_merge_findings() {
    jq -cn "$@" '
        [$ARGS.named[]] | map(if type == "array" then . else [] end) | add
        | unique_by([.code, .severity, (.command_head // ""), (.text // .pattern // "")])
    '
}

linux_agent_policy_review_text() {
    local subject="$1"
    local text="$2"
    local mode="${3:-local}"
    local ast blocked warn remote protected_paths protected_services findings

    ast="$(linux_agent_policy_ast_findings "${text}" "${mode}")"
    blocked="$(linux_agent_policy_match_patterns '.blocked_patterns' "${text}" "critical" "REGEX_BLOCKED")"
    warn="$(linux_agent_policy_match_patterns '.warn_patterns' "${text}" "high" "REGEX_WARN")"
    protected_paths="$(linux_agent_policy_match_patterns '.protected_paths' "${text}" "critical" "PROTECTED_PATH")"
    protected_services="$(linux_agent_policy_match_patterns '.protected_services' "${text}" "high" "PROTECTED_SERVICE")"
    if [[ "${mode}" == "remote" ]]; then
        remote="$(linux_agent_policy_match_patterns '.remote_script_blocked_patterns' "${text}" "critical" "REMOTE_REGEX_BLOCKED")"
    else
        remote='[]'
    fi

    findings="$(linux_agent_policy_merge_findings \
        --argjson ast "${ast}" \
        --argjson blocked "${blocked}" \
        --argjson warn "${warn}" \
        --argjson remote "${remote}" \
        --argjson protected_paths "${protected_paths}" \
        --argjson protected_services "${protected_services}")"

    jq -cn \
        --arg subject "${subject}" \
        --argjson findings "${findings}" \
        '{
            subject:$subject,
            engine:"ast+rules",
            approved:((($findings | map(.severity == "critical") | any) | not)),
            approval_required:(($findings | length) > 0),
            risk_level:(
                if ($findings | map(.severity == "critical") | any) then "critical"
                elif ($findings | map(.severity == "high") | any) then "high"
                elif ($findings | map(.severity == "medium") | any) then "medium"
                else "low" end
            ),
            findings:$findings
        }'
}

linux_agent_policy_review_step() {
    local step_json="$1"
    local text="$2"
    local mode="${3:-local}"
    local subject review step_risk

    subject="$(jq -r '.id // .title // "step"' <<<"${step_json}")"
    step_risk="$(jq -r '.risk_level // "low"' <<<"${step_json}")"
    review="$(linux_agent_policy_review_text "${subject}" "${text}" "${mode}")"
    jq -c --arg step_risk "${step_risk}" --arg mode "${mode}" '
        .approval_required = (.approval_required or ($step_risk == "medium") or ($step_risk == "high") or ($step_risk == "critical"))
        | .risk_level = (
            if .risk_level == "critical" or $step_risk == "critical" then "critical"
            elif .risk_level == "high" or $step_risk == "high" then "high"
            elif $step_risk == "medium" then "medium"
            else .risk_level end
        )
        | if $mode == "remote" then
            .approval_required = true
            | .risk_level = (if .risk_level == "critical" then "critical" else "high" end)
          else . end
    ' <<<"${review}"
}
