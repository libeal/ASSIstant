#!/usr/bin/env bash

set -euo pipefail

linux_agent_protocol_metadata() {
    local schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    if [[ -f "${schema_file}" ]]; then
        jq -c '{
            schema_version:(.schema_version // 1),
            protocol_version:(.protocol_version // "1.2.0")
        }' "${schema_file}"
        return 0
    fi
    printf '%s\n' '{"schema_version":1,"protocol_version":"1.2.0"}'
}

linux_agent_protocol_step_statuses() {
    local schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    if [[ -f "${schema_file}" ]] && jq -e '.step_status | type == "array" and length > 0' "${schema_file}" >/dev/null 2>&1; then
        jq -c '.step_status' "${schema_file}"
        return 0
    fi
    # Schema-unavailable fallback: only lifecycle states required to render a
    # safe, minimal protocol envelope.
    printf '%s\n' '["pending","running","succeeded","failed","blocked","approval_required","awaiting_mcp_input","skipped_unexecuted","terminated"]'
}

linux_agent_protocol_error_codes() {
    local schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    if [[ -f "${schema_file}" ]] && jq -e '.error_codes | type == "object"' "${schema_file}" >/dev/null 2>&1; then
        jq -c '.error_codes' "${schema_file}"
        return 0
    fi
    # Keep the fallback deliberately small. Unknown explicit error codes are
    # normalized to this schema-level boundary code by the protocol adapter.
    printf '%s\n' '{"internal_error":{"retryable":true,"http":500}}'
}

linux_agent_protocol_normalize_timeline_items() {
    jq -c --argjson allowed "$(linux_agent_protocol_step_statuses)" '
        def normalized($status; $successful):
            if $status == "planned" then "pending"
            elif (["executed", "answered", "completed", "ok", "success"] | index($status)) != null then "succeeded"
            elif (["cancelled", "timed_out"] | index($status)) != null then "terminated"
            elif $status == "skipped" then "skipped_user"
            elif ($allowed | index($status)) != null then $status
            elif $successful then "succeeded"
            else "failed" end;
        map(
            .status = normalized((.status // ""); (._successful // false))
            | del(._successful)
        )
    '
}

linux_agent_protocol_normalize_step_status() {
    local raw_status="$1"
    local ok="${2:-false}"
    jq -cn --arg raw "${raw_status}" --argjson ok "${ok}" \
        '[{status:$raw, _successful:$ok}]' |
        linux_agent_protocol_normalize_timeline_items |
        jq -r '.[0].status'
}

linux_agent_output_blocks_jq() {
    printf '%s\n' '
        def linux_agent_output_blocks:
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
          # An MCP tool result is projected into its own block so the frontend
          # never has to guess a type from an arbitrary JSON shape. Media and
          # resources are reduced to MIME + size here: the console must not be
          # handed anything it could turn into an outbound fetch.
          def is_mcp_result:
            ((.mcp? | type) == "object")
            and ((output_payload | type) == "object")
            and (
                (output_payload | has("content"))
                or (output_payload | has("structuredContent"))
                or (output_payload | has("isError"))
            );
          def b64_pad($s):
            if ($s | endswith("==")) then 2 elif ($s | endswith("=")) then 1 else 0 end;
          def b64_bytes($s):
            if (($s | type) == "string") and (($s | length) > 0)
            then ((($s | length) / 4 | floor) * 3) - b64_pad($s)
            else 0 end;
          def mcp_content_item:
            if type != "object" then
                {type:"unknown"}
            else
              (if (.type | type) == "string" then .type else "" end) as $type
              | if $type == "text" then
                (if (.text | type) == "string" then .text else "" end) as $text
                | {type:"text", text:$text, size_bytes:($text | utf8bytelength)}
              elif ($type == "image") or ($type == "audio") then
                {
                    type:$type,
                    mime_type:(if (.mimeType | type) == "string" then .mimeType elif (.mime_type | type) == "string" then .mime_type else "" end),
                    size_bytes:b64_bytes(.data // "")
                }
              elif $type == "resource_link" then
                {
                    type:"resource_link",
                    uri:(if (.uri | type) == "string" then .uri else "" end),
                    name:(if (.name | type) == "string" then .name else "" end),
                    mime_type:(if (.mimeType | type) == "string" then .mimeType elif (.mime_type | type) == "string" then .mime_type else "" end)
                }
              elif $type == "resource" then
                (if (.resource | type) == "object" then .resource else {} end) as $resource
                | {
                    type:"resource",
                    uri:($resource.uri // ""),
                    mime_type:($resource.mimeType // $resource.mime_type // ""),
                    text:(if ($resource.text | type) == "string" then $resource.text else null end),
                    size_bytes:(
                        if ($resource.text | type) == "string" then ($resource.text | utf8bytelength)
                        else b64_bytes($resource.blob // "") end
                    )
                  }
              else
                {type:(if $type == "" then "unknown" else $type end)}
              end
            end;
          [
            (if (.stdout? | present) then text_block("stdout"; "标准输出"; .stdout) else empty end),
            (if (.stderr? | present) then text_block("stderr"; "错误输出"; .stderr) else empty end),
            (if is_mcp_result then
                {
                    kind:"mcp_result",
                    title:"MCP 调用结果",
                    mcp:{
                        server_id:(.mcp.server_id // ""),
                        tool:(.mcp.tool // ""),
                        transport:(.mcp.transport // null),
                        protocol_version:(.mcp.protocol_version // null),
                        fallback_used:(.mcp.fallback_used == true),
                        fallback_reason:(.mcp.fallback_reason // ""),
                        is_error:((output_payload.isError // false) == true),
                        content:[(
                            if (output_payload.content | type) == "array" then output_payload.content else [] end
                            | .[]
                            | mcp_content_item
                        )],
                        structured_content:(output_payload.structuredContent // null)
                    }
                }
             else empty end),
            (if ((output_payload // null) | type) == "object" and (is_mcp_result | not) then
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
        ;'
}

linux_agent_output_blocks_from_result() {
    local result_json="$1"
    local output_blocks_filter
    output_blocks_filter="$(linux_agent_output_blocks_jq)"
    jq -c "${output_blocks_filter}
        linux_agent_output_blocks" <<<"${result_json}"
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
                _successful:true,
                title:"answer_received",
                summary:(.answer // "")
            }]
        else
            [(.steps // [])[] as $step | {
                id:($step.id // ("step-" + (now | tostring))),
                kind:"plan_step",
                status:"planned",
                _successful:false,
                step_id:($step.id // null),
                title:($step.title // $step.id // "step"),
                summary:([
                    $step.executor_type,
                    ($step.skill_script // (if (($step.skill // "") != "") then ($step.skill + (if (($step.path // "") != "") then (":" + $step.path) else ":SKILL.md" end)) else null end) // $step.command // (if (($step.mcp_server // "") != "" and ($step.mcp_tool // "") != "") then ($step.mcp_server + "/" + $step.mcp_tool) else "" end) // ""),
                    ($step.expected_effect // "")
                ] | map(select(. != "")) | join(" · ")),
                risk_level:($step.risk_level // "low"),
                step:$step
            }]
        end
    ' <<<"${response_json}" | linux_agent_protocol_normalize_timeline_items
}

linux_agent_timeline_execution_items() {
    local execution_json="$1"
    local output_blocks_filter
    output_blocks_filter="$(linux_agent_output_blocks_jq)"
    jq -c "${output_blocks_filter}"'
        [(.results // []) | to_entries[] | .key as $index | .value | (.iteration // null) as $iteration | {
            id:("execution-" + (if $iteration == null then "" else ("i" + ($iteration | tostring) + "-") end) + (($index + 1) | tostring) + "-" + (.step.id // ("result-" + ((.result.exit_code // 0) | tostring)))),
            kind:"execution",
            status:(
                if (.result.output.action // "") == "skipped_by_user" then "skipped_user"
                else (.result.status // "") end
            ),
            _successful:(.result.ok // false),
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
            step:(.step // {}),
            output_blocks:((.result // {}) | linux_agent_output_blocks)
        }]
    ' <<<"${execution_json}" | linux_agent_protocol_normalize_timeline_items
}

linux_agent_timeline_step_state_items() {
    local execution_json="$1"
    local output_blocks_filter
    output_blocks_filter="$(linux_agent_output_blocks_jq)"
    jq -c "${output_blocks_filter}"'
        (.results // []) as $results
        | [(.step_states // [])[] | . as $state
            | ([$results[] | select(
                    (.step_key // "") != ""
                    and .step_key == ($state.key // "")
                )] | last) as $keyed_result
            | ([$results[] | select(
                    (.step_key // "") == ""
                    and (.iteration // null) == ($state.iteration // null)
                    and (.step.id // "") == ($state.step_id // $state.step.id // "")
                )] | last) as $legacy_result
            | (($keyed_result // $legacy_result // {}).result // $state.result // null) as $result
            | {
                id:("step-state-" + ($state.key // (($state.step_index // 0) | tostring))),
                kind:(if ($state.status // "pending") == "pending" then "plan_step" else "execution" end),
                status:($state.status // "pending"),
                _successful:($result.ok // false),
                step_key:($state.key // null),
                step_id:($state.key // $state.step_id // null),
                original_step_id:($state.step_id // $state.step.id // null),
                step_index:($state.step_index // null),
                iteration:($state.iteration // null),
                scope:($state.scope // null),
                title:($state.step.title // $state.step_id // "步骤"),
                summary:(
                    if ($result.output.summary? // "") != "" then $result.output.summary
                    elif ($result.output.action? // "") != "" then $result.output.action
                    elif ($result.output.raw? // "") != "" then $result.output.raw
                    else ($state.status // "pending") end
                ),
                risk_level:($state.step.risk_level // null),
                step:($state.step // {}),
                output_blocks:($result | linux_agent_output_blocks)
            }
        ]
    ' <<<"${execution_json}" | linux_agent_protocol_normalize_timeline_items
}

linux_agent_timeline_step_projection() {
    local plan_items="$1"
    local execution_items="$2"
    local approval_card="${3:-null}"
    printf '%s\n%s\n%s\n' "${plan_items}" "${execution_items}" "${approval_card}" |
        jq -cs '
        .[0] as $plan
        | .[1] as $execution
        | .[2] as $approval
        |
        def item_key: (.step_id // .id // "");
        ($plan | map(item_key)) as $plan_keys
        | (
            [
                $plan[] as $planned
                | ($execution | map(select(item_key == ($planned | item_key))) | last) as $observed
                | if $observed == null then $planned else $observed end
            ]
            + [
                $execution[]
                | select((item_key as $key | ($plan_keys | index($key))) == null)
            ]
        )
        | if $approval == null then . else
            map(
                if item_key == ($approval.step.id // $approval.id // "") then
                    .status = ($approval.status // "approval_required")
                    | .approval = $approval
                else . end
            )
          end
    '
}

linux_agent_approval_card_for_work() {
    local response_json="$1"
    local execution_json="$2"
    printf '%s\n%s\n' "${response_json}" "${execution_json}" |
        jq -cs '
        .[0] as $response
        | .[1] as $execution
        |
        if ($execution.status // "") == "awaiting_mcp_input" then
            ($execution.mcp_input // $execution.resume_state.mcp_input // null) as $mcp_input
            | ($execution.current_plan.steps[$mcp_input.step_index] // null) as $step
            | {
                id:("mcp-input-" + ($mcp_input.step_key // ($mcp_input.step_index | tostring))),
                step_key:($mcp_input.step_key // null),
                type:"mcp_input",
                status:"awaiting_mcp_input",
                subject:($step.title // $mcp_input.tool // "MCP input"),
                title:($step.title // "MCP input required"),
                risk_level:"medium",
                step:$step,
                server_id:($mcp_input.server_id // null),
                tool:($mcp_input.tool // null),
                protocol_version:($mcp_input.protocol_version // null),
                transport:($mcp_input.transport // null),
                round:($mcp_input.round // 1),
                expires_at:($mcp_input.expires_at // null),
                input_requests:($mcp_input.input_requests // {}),
                actions:["submit","cancel"]
            }
        elif ($execution.status // "") == "approval_required" then
            ($execution.approval_step // null) as $step
            | {
                id:($step.id // "work-approval"),
                step_key:($execution.approval_step_key // null),
                type:"work",
                subject:($step.title // $step.id // "待审批步骤"),
                title:($step.title // $step.id // "待审批步骤"),
                risk_level:($execution.review.risk_level // $step.risk_level // "medium"),
                step:$step,
                review:($execution.review // null),
                mcp_metadata:($execution.mcp_metadata // null),
                actions:["approve","reject","skip","terminate"]
            }
        else null
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
    local plan_items execution_items timeline approval_card output_blocks metadata

    approval_card="$(linux_agent_approval_card_for_work "${response_json}" "${execution_json}")"
    if jq -e '.step_states | type == "array" and length > 0' >/dev/null 2>&1 <<<"${execution_json}"; then
        timeline="$(linux_agent_timeline_step_state_items "${execution_json}")"
        if [[ "${approval_card}" != "null" ]]; then
            timeline="$(printf '%s\n%s\n' "${timeline}" "${approval_card}" |
                jq -cs '
                .[0] as $timeline
                | .[1] as $approval
                |
                $timeline
                | map(
                    if (
                        (($approval.step_key // "") != "" and .step_key == $approval.step_key)
                        or (
                            ($approval.step_key // "") == ""
                            and .status == "approval_required"
                            and .original_step_id == ($approval.step.id // "")
                        )
                    ) then . + {approval:$approval}
                    else . end
                )
            ')"
        fi
    else
        plan_items="$(linux_agent_timeline_plan_items "${response_json}")"
        execution_items="$(linux_agent_timeline_execution_items "${execution_json}")"
        timeline="$(linux_agent_timeline_step_projection "${plan_items}" "${execution_items}" "${approval_card}")"
    fi
    metadata="$(linux_agent_protocol_metadata)"
    output_blocks="$(jq -c '[
        (if ((.final_answer // "") | length) > 0 then
            {kind:"markdown", title:"最终回答", text:(.final_answer // ""), truncated_bytes:0}
        else empty end),
        {kind:"meta", title:"工作流摘要", json:{
            status:(.status // null),
            iterations:(.iterations // null),
            auto_executed_count:(.auto_executed_count // null),
            stopped_reason:(.stopped_reason // null),
            final_answer:(.final_answer // null)
        } | with_entries(select(.value != null))}
    ]' <<<"${execution_json}")"

    printf '%s\n%s\n%s\n%s\n' \
        "${metadata}" \
        "${timeline}" \
        "${approval_card}" \
        "${output_blocks}" |
        jq -cs \
            --arg status "${status}" \
            '.[0] as $metadata
        | .[1] as $timeline
        | .[2] as $approval_card
        | .[3] as $output_blocks
        | $metadata + {
            status:$status,
            timeline:$timeline,
            timeline_semantics:"step_projection",
            approval_card:$approval_card,
            output_blocks:$output_blocks
        }'
}

linux_agent_protocol_for_single_execution() {
    local title="$1"
    local result_json="$2"
    local status blocks metadata
    status="$(linux_agent_protocol_normalize_step_status \
        "$(jq -r '.status // empty' <<<"${result_json}")" \
        "$(jq -r '.ok // false' <<<"${result_json}")")"
    blocks="$(linux_agent_output_blocks_from_result "${result_json}")"
    metadata="$(linux_agent_protocol_metadata)"
    printf '%s\n%s\n' "${metadata}" "${blocks}" |
        jq -cs \
            --arg title "${title}" \
            --arg status "${status}" \
            '.[0] as $metadata
        | .[1] as $output_blocks
        | $metadata + {
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

linux_agent_protocol_envelope_for_single_execution() {
    local title="$1"
    local result_json="$2"
    local approval_card="${3:-null}"
    local protocol error_codes
    protocol="$(linux_agent_protocol_for_single_execution "${title}" "${result_json}")"
    error_codes="$(linux_agent_protocol_error_codes)"
    printf '%s\n%s\n%s\n' "${result_json}" "${protocol}" "${approval_card}" |
        jq -cs --argjson error_codes "${error_codes}" '
        .[0] as $result
        | .[1] as $protocol
        | .[2] as $approval_card
        |
        ($result.status // "") as $raw_status
        | ($result.code // $result.error_code // null) as $raw_error_code
        | (
            if $raw_error_code == null then null
            elif (($error_codes[$raw_error_code] // null) | type) == "object" then $raw_error_code
            else "internal_error" end
          ) as $error_code
        | ({
            schema_version:$protocol.schema_version,
            protocol_version:$protocol.protocol_version,
            ok:($result.ok // false),
            status:(
                if ($result.ok // false) then "executed"
                elif (["succeeded", "success", "completed", "ok"] | index($raw_status)) != null then "executed"
                elif $raw_status != "" then $raw_status
                else "failed" end
            ),
            timeline:$protocol.timeline,
            timeline_semantics:"step_projection",
            approval_card:$approval_card,
            output_blocks:$protocol.output_blocks
        } + (
            if $error_code == null then {}
            else {
                code:$error_code,
                error_code:$error_code,
                error:($result.error // $result.message // $result.output.raw // $error_code),
                message:($result.message // $result.error // $result.output.raw // $error_code),
                retryable:(
                    if (($result | has("retryable")) and ($result.retryable | type) == "boolean") then
                        $result.retryable
                    else ($error_codes[$error_code].retryable // false) end
                ),
                request_id:($result.request_id // null),
                details:(
                    (if ($result.details | type) == "object" then $result.details else {} end)
                    + (if $raw_error_code != $error_code then {original_code:$raw_error_code} else {} end)
                )
            } | with_entries(select(.value != null))
            end
        ))
    '
}
