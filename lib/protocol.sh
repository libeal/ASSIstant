#!/usr/bin/env bash

set -euo pipefail

linux_agent_output_blocks_from_result() {
    local result_json="$1"
    jq -c '
        def present:
            if . == null then false
            elif type == "string" then length > 0
            elif type == "array" then length > 0
            elif type == "object" then length > 0
            else true end;
        def text_block($kind; $title; $text): {
            kind:$kind,
            title:$title,
            text:($text // ""),
            truncated_bytes:0
        };
        def json_block($kind; $title; $json): {
            kind:$kind,
            title:$title,
            json:$json
        };
        def output_payload:
            if (.output? | type) == "object" then .output else null end;
        [
            (if (.stdout? | present) then text_block("stdout"; "标准输出"; .stdout) else empty end),
            (if (.stderr? | present) then text_block("stderr"; "错误输出"; .stderr) else empty end),
            (if ((output_payload // null) | type) == "object" then
                if ((output_payload | has("raw")) and ((output_payload.raw // "") | length > 0)) then
                    text_block("stdout"; "执行输出"; output_payload.raw)
                else
                    json_block("json"; "执行输出"; output_payload)
                end
             else empty end),
            (if (.review? | present) then json_block("review"; "策略审查"; .review) else empty end),
            (if (.observer? | present) then json_block("observer"; "Observer"; .observer) else empty end),
            (if (.execution_proxy? | present) then json_block("meta"; "执行代理"; .execution_proxy) else empty end),
            json_block("meta"; "执行摘要"; {
                ok:(.ok // null),
                status:(.status // null),
                exit_code:(.exit_code // null),
                command:(.command // null),
                auto_approved:(.auto_approved // null)
            } | with_entries(select(.value != null)))
        ] | map(select(
            (.kind != "meta") or
            ((.json // {}) | length > 0)
        ))
    ' <<<"${result_json}"
}

linux_agent_output_blocks_from_review() {
    local review_json="$1"
    jq -c '[{kind:"review", title:"策略审查", json:.}]' <<<"${review_json}"
}

linux_agent_timeline_plan_items() {
    local response_json="$1"
    jq -c '
        if (.response_type // "") == "answer" then
            [{
                id:"answer",
                kind:"answer",
                status:"answered",
                title:"answer_received",
                summary:(.answer // "")
            }]
        else
            [(.steps // [])[] as $step | {
                id:($step.id // ("step-" + (now | tostring))),
                kind:"plan_step",
                status:"planned",
                step_id:($step.id // null),
                title:($step.title // $step.id // "step"),
                summary:([$step.executor_type, ($step.skill_script // $step.command // ""), ($step.expected_effect // "")] | map(select(. != "")) | join(" · ")),
                risk_level:($step.risk_level // "low"),
                step:$step
            }]
        end
    ' <<<"${response_json}"
}

linux_agent_timeline_execution_items() {
    local execution_json="$1"
    jq -c '
        [(.results // []) | to_entries[] | .key as $index | .value | (.iteration // null) as $iteration | {
            id:("execution-" + (if $iteration == null then "" else ("i" + ($iteration | tostring) + "-") end) + (($index + 1) | tostring) + "-" + (.step.id // ("result-" + ((.result.exit_code // 0) | tostring)))),
            kind:"execution",
            status:(.result.status // (if (.result.ok // false) then "executed" else "failed" end)),
            iteration:$iteration,
            step_id:(.step.id // null),
            title:(.step.title // .step.id // "步骤执行"),
            summary:(
                if (.result.output.summary? // "") != "" then .result.output.summary
                elif (.result.output.action? // "") != "" then .result.output.action
                elif (.result.output.raw? // "") != "" then .result.output.raw
                else (.result.status // "")
                end
            ),
            risk_level:(.step.risk_level // null),
            output_blocks:(
                [
                    (if (.result.output? | type) == "object" then
                        if (.result.output | has("raw")) then
                            {kind:"stdout", title:"执行输出", text:(.result.output.raw // ""), truncated_bytes:0}
                        else
                            {kind:"json", title:"执行输出", json:.result.output}
                        end
                     else empty end),
                    (if (.result.review? | type) == "object" then {kind:"review", title:"策略审查", json:.result.review} else empty end),
                    (if (.result.observer? | type) == "object" then {kind:"observer", title:"Observer", json:.result.observer} else empty end),
                    (if (.result.execution_proxy? | type) == "object" then {kind:"meta", title:"执行代理", json:.result.execution_proxy} else empty end),
                    {kind:"meta", title:"执行摘要", json:{
                        ok:(.result.ok // null),
                        status:(.result.status // null),
                        exit_code:(.result.exit_code // null),
                        auto_approved:(.result.auto_approved // null)
                    } | with_entries(select(.value != null))}
                ]
            )
        }]
    ' <<<"${execution_json}"
}

linux_agent_approval_card_for_work() {
    local response_json="$1"
    local execution_json="$2"
    jq -cn --argjson response "${response_json}" --argjson execution "${execution_json}" '
        if ($execution.status // "") != "approval_required" then null
        else
            ($execution.approval_step // null) as $step
            | {
                id:($step.id // "work-approval"),
                type:"work",
                subject:($step.title // $step.id // "待审批步骤"),
                title:($step.title // $step.id // "待审批步骤"),
                risk_level:($execution.review.risk_level // $step.risk_level // "medium"),
                step:$step,
                review:($execution.review // null),
                actions:["approve","reject","skip","terminate"]
            }
        end
    '
}

linux_agent_approval_card_for_terminal() {
    local command_text="$1"
    local review_json="$2"
    jq -cn --arg command "${command_text}" --argjson review "${review_json}" '
        if ($review.approval_required // false) then {
            id:"terminal-approval",
            type:"terminal",
            subject:"终端命令",
            title:"终端命令需要审批",
            command:$command,
            risk_level:($review.risk_level // "medium"),
            review:$review,
            actions:["approve","reject"]
        } else null end
    '
}

linux_agent_protocol_for_work() {
    local status="$1"
    local response_json="$2"
    local execution_json="$3"
    local plan_items execution_items approval_card output_blocks

    plan_items="$(linux_agent_timeline_plan_items "${response_json}")"
    execution_items="$(linux_agent_timeline_execution_items "${execution_json}")"
    approval_card="$(linux_agent_approval_card_for_work "${response_json}" "${execution_json}")"
    output_blocks="$(jq -cn --argjson execution "${execution_json}" '[
        (if (($execution.final_answer // "") | length) > 0 then
            {kind:"markdown", title:"最终回答", text:($execution.final_answer // ""), truncated_bytes:0}
        else empty end),
        {kind:"meta", title:"工作流摘要", json:{
            status:($execution.status // null),
            iterations:($execution.iterations // null),
            auto_executed_count:($execution.auto_executed_count // null),
            stopped_reason:($execution.stopped_reason // null),
            final_answer:($execution.final_answer // null)
        } | with_entries(select(.value != null))}
    ]')"

    jq -cn \
        --arg status "${status}" \
        --argjson timeline_plan "${plan_items}" \
        --argjson timeline_execution "${execution_items}" \
        --argjson approval_card "${approval_card}" \
        --argjson output_blocks "${output_blocks}" \
        '{
            status:$status,
            timeline:($timeline_plan + $timeline_execution),
            approval_card:$approval_card,
            output_blocks:$output_blocks
        }'
}

linux_agent_protocol_for_single_execution() {
    local title="$1"
    local result_json="$2"
    local status blocks
    status="$(jq -r '.status // (if (.ok // false) then "executed" else "failed" end)' <<<"${result_json}")"
    blocks="$(linux_agent_output_blocks_from_result "${result_json}")"
    jq -cn \
        --arg title "${title}" \
        --arg status "${status}" \
        --argjson output_blocks "${blocks}" \
        '{
            timeline:[{
                id:"execution",
                kind:"execution",
                status:$status,
                title:$title,
                summary:$status,
                output_blocks:$output_blocks
            }],
            output_blocks:$output_blocks
        }'
}
