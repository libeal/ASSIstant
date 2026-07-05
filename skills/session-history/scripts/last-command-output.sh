#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LOG_DIR="${LINUX_AGENT_LOG_DIR:-${ROOT_DIR}/logs}"

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
if ! jq -e 'type == "object"' <<<"${arguments_json}" >/dev/null 2>&1; then
    jq -cn '{ok:false, tool:"session.history.last-command-output", error:"arguments must be a JSON object"}'
    exit 0
fi

session_id="$(jq -r '.session_id // empty' <<<"${arguments_json}")"
if [[ -z "${session_id}" ]]; then
    session_id="${LINUX_AGENT_SESSION_ID:-}"
fi
if [[ -z "${session_id}" ]]; then
    latest_log="$(find "${LOG_DIR}" -maxdepth 1 -type f -name 'session*.jsonl' -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n 1 | awk '{print $2}')"
    session_id="${latest_log%.jsonl}"
fi

if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    jq -cn --arg session_id "${session_id}" '{ok:false, tool:"session.history.last-command-output", session_id:$session_id, error:"session_id is required and must be a safe file name"}'
    exit 0
fi

log_file="${LOG_DIR}/${session_id}.jsonl"
if [[ ! -f "${log_file}" ]]; then
    jq -cn --arg session_id "${session_id}" '{ok:false, tool:"session.history.last-command-output", session_id:$session_id, error:"audit session not found"}'
    exit 0
fi

if jq -e 'has("turn_offset")' <<<"${arguments_json}" >/dev/null; then
    turn_offset="$(jq -r '.turn_offset' <<<"${arguments_json}")"
elif [[ -n "${LINUX_AGENT_SESSION_ID:-}" && "${session_id}" == "${LINUX_AGENT_SESSION_ID}" ]]; then
    turn_offset=1
else
    turn_offset=0
fi
limit="$(jq -r '.limit // 20' <<<"${arguments_json}")"
[[ "${turn_offset}" =~ ^[0-9]+$ ]] || turn_offset=0
[[ "${limit}" =~ ^[0-9]+$ ]] || limit=20
[[ "${limit}" -gt 0 ]] || limit=20
[[ "${limit}" -le 100 ]] || limit=100

jq -s -c \
    --arg session_id "${session_id}" \
    --argjson turn_offset "${turn_offset}" \
    --argjson limit "${limit}" '
    def stage_of($event):
      ($event.stage // $event.event // $event.type // $event.status // "event") | tostring;
    def payload_of($event):
      if (($event.payload // null) | type) == "object" then $event.payload else {} end;
    def preview($value):
      ($value // "") | tostring | gsub("[\r\n\t ]+"; " ") | .[0:1000];
    def step_command($step):
      ($step.command // $step.command_preview // $step.skill_script // "");
    def turn_input($event):
      payload_of($event) as $p
      | ($p.input_preview // $p.input // $p.command // $p.ref // $p.args_preview // "");
    def turn_mode($event):
      payload_of($event) as $p
      | if (($p.mode // "") != "") then $p.mode
        elif (($p.command // "") != "") then "terminal"
        elif (($p.ref // "") != "") then "script"
        else "work" end;
    def command_from_event($event):
      stage_of($event) as $stage
      | payload_of($event) as $p
      | if $stage == "received" and (($p.command // "") != "") then
          {timestamp:($event.timestamp // ""), stage:$stage, kind:"terminal", command:($p.command // "")}
        elif $stage == "command_started" then
          {timestamp:($event.timestamp // ""), stage:$stage, kind:"entrypoint", command:($p.command // ""), args_preview:($p.args_preview // "")}
        elif $stage == "planned" then
          [($p.steps // [])[]?
            | select((step_command(.) // "") != "")
            | {timestamp:($event.timestamp // ""), stage:$stage, kind:(.executor_type // "step"), step_id:(.id // ""), title:(.title // .id // ""), command:step_command(.), risk_level:(.risk_level // "")}]
        elif ($stage | startswith("step_")) and (($p.step // null) | type) == "object" and ((step_command($p.step) // "") != "") then
          {timestamp:($event.timestamp // ""), stage:$stage, kind:($p.step.executor_type // "step"), step_id:($p.step.id // ""), title:($p.step.title // $p.step.id // ""), command:step_command($p.step), risk_level:($p.step.risk_level // "")}
        else empty end;
    def output_from_event($event):
      stage_of($event) as $stage
      | payload_of($event) as $p
      | (if (($p.detail // null) | type) == "object" then $p.detail else $p end) as $d
      | if (($stage | test("^(terminal_executed|script_executed|executed|step_succeeded|step_failed|step_blocked|step_rejected|step_skipped_user)$"))) then
          {
            timestamp:($event.timestamp // ""),
            stage:$stage,
            status:($p.status // $d.status // ""),
            step_id:($p.step.id // ""),
            title:($p.step.title // $stage),
            exit_code:($d.exit_code // null),
            tool:($d.tool // ""),
            action:($d.action // ""),
            output_preview:preview($d.output_preview // $p.output_preview // ""),
            stderr_preview:preview($d.stderr_preview // $p.stderr_preview // "")
          }
        else empty end;
    reduce .[] as $event ({turns:[], current:null};
      if stage_of($event) == "received" then
        (if .current == null then . else .turns += [.current] end)
        | .current = {
            started_at:($event.timestamp // ""),
            mode:turn_mode($event),
            input:turn_input($event),
            events:[$event]
          }
      elif .current != null then
        .current.events += [$event]
      else
        .
      end
    )
    | (if .current == null then . else .turns += [.current] | .current = null end)
    | .turns as $turns
    | (($turns | length) - 1 - $turn_offset) as $index
    | if ($turns | length) == 0 then
        {ok:false, tool:"session.history.last-command-output", session_id:$session_id, error:"no turns found in audit session", turn_count:0}
      elif $index < 0 then
        {ok:false, tool:"session.history.last-command-output", session_id:$session_id, error:"turn_offset is outside the available turn range", turn_count:($turns | length), turn_offset:$turn_offset}
      else
        ($turns[$index]) as $turn
        | {
            ok:true,
            tool:"session.history.last-command-output",
            session_id:$session_id,
            turn_count:($turns | length),
            turn_index:$index,
            turn_offset:$turn_offset,
            turn:{
              started_at:($turn.started_at // ""),
              mode:($turn.mode // ""),
              input:($turn.input // ""),
              event_count:(($turn.events // []) | length)
            },
            commands:([($turn.events // [])[] | command_from_event(.)] | flatten | .[0:$limit]),
            outputs:([($turn.events // [])[] | output_from_event(.)] | .[0:$limit])
          }
      end
  ' "${log_file}"
