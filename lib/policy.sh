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
    case "${subject}" in
        skill:*|script:*|edit:*)
            ast="$(jq -c 'map(select(.code != "AST_FILE_MUTATION_REQUIRES_SKILL"))' <<<"${ast}")"
            ;;
    esac
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

linux_agent_policy_add_validation_finding() {
    local findings="$1"
    local severity="$2"
    local code="$3"
    local path="$4"
    local message="$5"
    local pointer="${6:-}"

    jq -cn \
        --argjson prior "${findings}" \
        --arg severity "${severity}" \
        --arg code "${code}" \
        --arg path "${path}" \
        --arg message "${message}" \
        --arg pointer "${pointer}" \
        '$prior + [{
            severity:$severity,
            code:$code,
            path:$path,
            message:$message
        } + (if $pointer == "" then {} else {pointer:$pointer} end)]'
}

linux_agent_policy_validate_jq_regex() {
    local pattern="$1"
    jq -n --arg pattern "${pattern}" '"" | test($pattern)' >/dev/null 2>&1
}

linux_agent_policy_validate_grep_regex() {
    local pattern="$1"
    printf '\n' | grep -Eq -- "${pattern}" >/dev/null 2>&1
    case "$?" in
        0|1) return 0 ;;
        *) return 1 ;;
    esac
}

linux_agent_policy_regex_matches_empty_with_jq() {
    local pattern="$1"
    jq -n --arg pattern "${pattern}" '"" | test($pattern)' 2>/dev/null | grep -qx 'true'
}

linux_agent_policy_regex_matches_empty_with_grep() {
    local pattern="$1"
    printf '\n' | grep -Eq -- "${pattern}" >/dev/null 2>&1
}

linux_agent_policy_validate_pattern_array() {
    local findings="$1"
    local path="$2"
    local policy_path="$3"
    local json="$4"
    local regex_engine="$5"
    local pattern pointer

    while IFS= read -r pointer; do
        [[ -n "${pointer}" ]] || continue
        pattern="$(jq -r "${pointer}" <<<"${json}")"
        if [[ -z "${pattern}" ]]; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_EMPTY_PATTERN" "${path}" "策略正则不能为空。" "${pointer}")"
            continue
        fi
        if [[ "${regex_engine}" == "jq" ]]; then
            if ! linux_agent_policy_validate_jq_regex "${pattern}"; then
                findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_INVALID" "${path}" "正则无法被 jq/test 编译。" "${pointer}")"
                continue
            fi
            if linux_agent_policy_regex_matches_empty_with_jq "${pattern}"; then
                findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_ZERO_WIDTH" "${path}" "正则会匹配空字符串，可能导致全量替换或误判。" "${pointer}")"
            fi
        else
            if ! linux_agent_policy_validate_grep_regex "${pattern}"; then
                findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_INVALID" "${path}" "正则无法被 grep -E 编译。" "${pointer}")"
                continue
            fi
            if linux_agent_policy_regex_matches_empty_with_grep "${pattern}"; then
                findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_ZERO_WIDTH" "${path}" "正则会匹配空字符串，可能导致全量误判。" "${pointer}")"
            fi
        fi
    done < <(jq -r --arg policy_path "${policy_path}" '
        getpath($policy_path | split("."))
        | if type == "array" then to_entries[] | ".\($policy_path)[\(.key)]" else empty end
    ' <<<"${json}" 2>/dev/null || true)

    printf '%s\n' "${findings}"
}

linux_agent_policy_validate_risk_rules() {
    local path="$1"
    local json="$2"
    local findings='[]'
    local array_path

    for array_path in blocked_patterns warn_patterns remote_script_blocked_patterns protected_paths protected_services; do
        if ! jq -e --arg path "${array_path}" 'getpath($path | split(".")) | type == "array"' <<<"${json}" >/dev/null 2>&1; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REQUIRED_ARRAY_MISSING" "${path}" "${array_path} 必须是数组。" "${array_path}")"
            continue
        fi
        findings="$(linux_agent_policy_validate_pattern_array "${findings}" "${path}" "${array_path}" "${json}" "grep")"
    done

    printf '%s\n' "${findings}"
}

linux_agent_policy_validate_redaction_rules() {
    local path="$1"
    local json="$2"
    local findings='[]'
    local pointer rule_id pattern

    if ! jq -e '.rules | type == "array"' <<<"${json}" >/dev/null 2>&1; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REQUIRED_ARRAY_MISSING" "${path}" "rules 必须是数组。" "rules")"
    fi
    if ! jq -e '.sensitive_key_pattern | type == "string" and length > 0' <<<"${json}" >/dev/null 2>&1; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REQUIRED_STRING_MISSING" "${path}" "sensitive_key_pattern 必须是非空字符串。" "sensitive_key_pattern")"
    else
        pattern="$(jq -r '.sensitive_key_pattern' <<<"${json}")"
        if ! linux_agent_policy_validate_jq_regex "${pattern}"; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_INVALID" "${path}" "sensitive_key_pattern 无法被 jq/test 编译。" "sensitive_key_pattern")"
        elif linux_agent_policy_regex_matches_empty_with_jq "${pattern}"; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_ZERO_WIDTH" "${path}" "sensitive_key_pattern 会匹配空字符串。" "sensitive_key_pattern")"
        fi
    fi

    while IFS= read -r pointer; do
        [[ -n "${pointer}" ]] || continue
        rule_id="$(jq -r "${pointer}.id // empty" <<<"${json}")"
        pattern="$(jq -r "${pointer}.pattern // empty" <<<"${json}")"
        if [[ -z "${rule_id}" ]]; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_RULE_ID_MISSING" "${path}" "脱敏规则缺少 id。" "${pointer}.id")"
        fi
        if [[ -z "${pattern}" ]]; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_EMPTY_PATTERN" "${path}" "脱敏规则正则不能为空。" "${pointer}.pattern")"
            continue
        fi
        if ! linux_agent_policy_validate_jq_regex "${pattern}"; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_INVALID" "${path}" "脱敏规则正则无法被 jq/test 编译。" "${pointer}.pattern")"
            continue
        fi
        if linux_agent_policy_regex_matches_empty_with_jq "${pattern}"; then
            findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REGEX_ZERO_WIDTH" "${path}" "脱敏规则正则会匹配空字符串，可能擦除全部输出。" "${pointer}.pattern")"
        fi
    done < <(jq -r '.rules | if type == "array" then to_entries[] | ".rules[\(.key)]" else empty end' <<<"${json}" 2>/dev/null || true)

    printf '%s\n' "${findings}"
}

linux_agent_policy_validate_audit_boundaries() {
    local path="$1"
    local json="$2"
    local findings='[]'

    if ! jq -e '.observing | type == "object"' <<<"${json}" >/dev/null 2>&1; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REQUIRED_OBJECT_MISSING" "${path}" "observing 必须是对象。" "observing")"
    fi
    if ! jq -e '.allowed_to_observe | type == "object"' <<<"${json}" >/dev/null 2>&1; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_REQUIRED_OBJECT_MISSING" "${path}" "allowed_to_observe 必须是对象。" "allowed_to_observe")"
    fi
    if ! jq -e '. as $root | (.observing.audit_payload_mode | type == "string") and ([($root.allowed_to_observe.audit_payload_modes // [])[]] | index($root.observing.audit_payload_mode))' <<<"${json}" >/dev/null 2>&1; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_AUDIT_MODE_NOT_ALLOWED" "${path}" "observing.audit_payload_mode 必须存在于 allowed_to_observe.audit_payload_modes。" "observing.audit_payload_mode")"
    fi

    printf '%s\n' "${findings}"
}

linux_agent_validate_policy_content() {
    local path="$1"
    local content="$2"
    local json findings
    findings='[]'

    if [[ -z "${path}" || "${path}" == /* || "${path}" == *".."* || "${path}" != *.json ]]; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_PATH_INVALID" "${path}" "策略路径必须是 policies/ 下的 JSON 相对路径。")"
        jq -cn --arg path "${path}" --argjson findings "${findings}" '{ok:false, status:"invalid", path:$path, findings:$findings}'
        return 0
    fi

    if ! json="$(jq -c . <<<"${content}" 2>/dev/null)"; then
        findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_JSON_INVALID" "${path}" "策略文件不是合法 JSON。")"
        jq -cn --arg path "${path}" --argjson findings "${findings}" '{ok:false, status:"invalid", path:$path, findings:$findings}'
        return 0
    fi

    case "${path}" in
        risk-rules.json)
            findings="$(linux_agent_policy_validate_risk_rules "${path}" "${json}")"
            ;;
        redaction-rules.json)
            findings="$(linux_agent_policy_validate_redaction_rules "${path}" "${json}")"
            ;;
        audit-boundaries.json)
            findings="$(linux_agent_policy_validate_audit_boundaries "${path}" "${json}")"
            ;;
        *)
            if ! jq -e 'type == "object"' <<<"${json}" >/dev/null 2>&1; then
                findings="$(linux_agent_policy_add_validation_finding "${findings}" "critical" "POLICY_TOP_LEVEL_NOT_OBJECT" "${path}" "未知策略文件的顶层必须是对象。")"
            fi
            ;;
    esac

    jq -cn --arg path "${path}" --argjson findings "${findings}" \
        '{ok:(([$findings[]? | select(.severity == "critical")] | length) == 0), status:(if (([$findings[]? | select(.severity == "critical")] | length) == 0) then "valid" else "invalid" end), path:$path, findings:$findings}'
}

linux_agent_validate_policy_file() {
    local path="$1"
    local full_path

    if [[ -z "${path}" ]]; then
        linux_agent_validate_policies
        return 0
    fi
    if [[ "${path}" == /* || "${path}" == *".."* || "${path}" != *.json ]]; then
        linux_agent_validate_policy_content "${path}" ""
        return 0
    fi
    full_path="${LINUX_AGENT_ROOT}/policies/${path}"
    if [[ ! -f "${full_path}" ]]; then
        jq -cn --arg path "${path}" '{ok:false, status:"not_found", path:$path, findings:[{severity:"critical", code:"POLICY_FILE_MISSING", path:$path, message:"策略文件不存在。"}]}'
        return 0
    fi
    linux_agent_validate_policy_content "${path}" "$(cat "${full_path}")"
}

linux_agent_validate_policies() {
    local policies_dir="${LINUX_AGENT_ROOT}/policies"
    local findings='[]'
    local files='[]'
    local file rel result

    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        rel="${file#${policies_dir}/}"
        result="$(linux_agent_validate_policy_file "${rel}")"
        files="$(jq -cn --argjson prior "${files}" --argjson result "${result}" '$prior + [$result]')"
        findings="$(jq -cn --argjson prior "${findings}" --argjson next "$(jq '.findings // []' <<<"${result}")" '$prior + $next')"
    done < <(find "${policies_dir}" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)

    jq -cn --argjson files "${files}" --argjson findings "${findings}" \
        '{ok:(([$findings[]? | select(.severity == "critical")] | length) == 0), status:(if (([$findings[]? | select(.severity == "critical")] | length) == 0) then "valid" else "invalid" end), files:$files, findings:$findings}'
}
