#!/usr/bin/env bash

set -euo pipefail

linux_agent_risk_rules_path() {
    printf '%s/policies/risk-rules.json\n' "${LINUX_AGENT_ROOT}"
}

linux_agent_policy_match_patterns() {
    local pattern_path="$1"
    local text="$2"
    local severity="$3"
    local code="$4"
    local findings='[]'

    while IFS= read -r pattern; do
        [[ -z "${pattern}" ]] && continue
        if printf '%s\n' "${text}" | grep -Eiq -- "${pattern}"; then
            findings="$(jq -cn \
                --argjson prior "${findings}" \
                --arg severity "${severity}" \
                --arg code "${code}" \
                --arg pattern "${pattern}" \
                '$prior + [{severity:$severity, code:$code, pattern:$pattern, message:"命令或脚本文本命中正则审查规则。"}]')"
        fi
    done < <(jq -r "${pattern_path}[]? // empty" "$(linux_agent_risk_rules_path)" 2>/dev/null || true)

    printf '%s\n' "${findings}"
}

linux_agent_policy_review_text() {
    local subject="$1"
    local text="$2"
    local mode="${3:-local}"
    local findings blocked warn remote protected_paths protected_services

    blocked="$(linux_agent_policy_match_patterns '.blocked_patterns' "${text}" "critical" "REGEX_BLOCKED")"
    warn="$(linux_agent_policy_match_patterns '.warn_patterns' "${text}" "high" "REGEX_WARN")"
    protected_paths="$(linux_agent_policy_match_patterns '.protected_paths' "${text}" "critical" "PROTECTED_PATH")"
    protected_services="$(linux_agent_policy_match_patterns '.protected_services' "${text}" "high" "PROTECTED_SERVICE")"
    if [[ "${mode}" == "remote" ]]; then
        remote="$(linux_agent_policy_match_patterns '.remote_script_blocked_patterns' "${text}" "critical" "REMOTE_REGEX_BLOCKED")"
    else
        remote='[]'
    fi

    findings="$(jq -cn \
        --argjson blocked "${blocked}" \
        --argjson warn "${warn}" \
        --argjson remote "${remote}" \
        --argjson protected_paths "${protected_paths}" \
        --argjson protected_services "${protected_services}" \
        '$blocked + $warn + $remote + $protected_paths + $protected_services')"

    jq -cn \
        --arg subject "${subject}" \
        --argjson findings "${findings}" \
        '{
            subject:$subject,
            approved:((($findings | map(.severity == "critical") | any) | not)),
            approval_required:(($findings | length) > 0),
            risk_level:(
                if ($findings | map(.severity == "critical") | any) then "critical"
                elif ($findings | map(.severity == "high") | any) then "high"
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
