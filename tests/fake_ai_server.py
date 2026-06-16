#!/usr/bin/env python3

import json
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def step(step_id, title, executor_type, reason, expected_effect, risk_level="low", **extra):
    payload = {
        "id": step_id,
        "title": title,
        "executor_type": executor_type,
        "arguments": extra.pop("arguments", {}),
        "reason": reason,
        "expected_effect": expected_effect,
        "risk_level": risk_level,
        "rollback_hint": extra.pop("rollback_hint", "只读操作，无需回滚。"),
    }
    payload.update(extra)
    return payload


def answer(summary, text, reason="该请求不需要执行工具。", thinking_summary=None):
    payload = {
        "response_type": "answer",
        "summary": summary,
        "continue_decision": {"should_continue": False, "reason": reason},
        "answer": text,
        "steps": [],
    }
    if thinking_summary:
        payload["thinking_summary"] = thinking_summary
    return payload


def work_plan(summary, steps, should_continue=False, reason="计划执行后无需再次反思。", thinking_summary=None):
    payload = {
        "response_type": "work_plan",
        "summary": summary,
        "continue_decision": {"should_continue": should_continue, "reason": reason},
        "steps": steps,
    }
    if thinking_summary:
        payload["thinking_summary"] = thinking_summary
    return payload


def edit_package():
    return {
        "response_type": "skill_edit",
        "skill": {
            "name": "custom-generated",
            "description": "根据用户需求生成的本地运维辅助 skill。",
        },
        "scripts": [
            {
                "name": "generated.sh",
                "description": "输出当前请求摘要，作为可审批脚本模板。",
                "content": "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "args=\"${1:-}\"\n"
                "[[ -z \"${args}\" ]] && args='{}'\n"
                "printf '{\"ok\":true,\"tool\":\"custom-generated/generated\",\"args\":%s,\"note\":\"generated skill placeholder\"}\\n' \"${args}\"\n",
            }
        ],
        "notes": "test fixture edit package",
    }


def extract_request(messages):
    purpose = "work_plan"
    request_context = {}
    current_request = ""
    for message in messages:
        content = str(message.get("content", ""))
        if content.startswith("purpose="):
            purpose = content[len("purpose=") :]
        elif content.startswith("request_context="):
            raw = content[len("request_context=") :]
            try:
                request_context = json.loads(raw)
            except json.JSONDecodeError:
                request_context = {"raw": raw}
        elif message.get("role") == "user":
            current_request = content
    if not current_request:
        current_request = str(request_context.get("current_request") or "")
    return purpose, request_context, current_request


def work_plan_response(current_request):
    if "失败" in current_request:
        return work_plan(
            "演示失败中断：先执行一个会失败的命令，随后计划中的步骤应被标记为未执行。",
            [
                step(
                    "step-1",
                    "执行失败演示命令",
                    "shell",
                    "用于验证失败后中断和修复计划请求。",
                    "命令返回非 0，当前计划中断。",
                    command="false",
                    rollback_hint="无需回滚。",
                ),
                step(
                    "step-2",
                    "不应执行的后续步骤",
                    "skill_script",
                    "验证未执行步骤状态。",
                    "该步骤不应展示执行。",
                    skill_script="ops-basic/process-inspect",
                    arguments={"pattern": "systemd"},
                    rollback_hint="无需回滚。",
                ),
            ],
            should_continue=True,
            reason="该演示计划预期失败，执行后需要根据失败结果生成后续判断。",
        )
    if any(token in current_request for token in ("cpu", "CPU", "内存", "memory", "资源", "负载")):
        should_continue = "继续深入" in current_request or "非法继续决策" in current_request
        reason = "资源检查 skill 的预期输出已经满足当前请求，执行成功后无需再次反思。"
        if should_continue:
            reason = "该测试请求明确要求继续深入，执行第一轮资源检查后需要反思下一步。"
        return work_plan(
            "使用受控资源检查 skill 查看 CPU、内存与高占用进程。",
            [
                step(
                    "step-1",
                    "查看 CPU 与内存资源概况",
                    "skill_script",
                    "通过受控只读 skill 采集 CPU 负载、内存使用和高占用进程，避免自由拼接 shell。",
                    "返回 CPU/内存概况和资源占用最高的进程列表。",
                    skill_script="ops-basic/resource-inspect",
                    arguments={"top_n": 10},
                )
            ],
            should_continue=should_continue,
            reason=reason,
        )
    if any(token in current_request for token in ("磁盘", "垃圾", "日志")):
        return work_plan(
            "先只读检查磁盘热点和日志候选，再由用户决定是否继续清理。",
            [
                step(
                    "step-1",
                    "检查磁盘热点",
                    "skill_script",
                    "定位大目录和大文件，避免盲目清理。",
                    "返回 /var 下磁盘占用和日志热点摘要。",
                    skill_script="ops-basic/disk-hotspots",
                    arguments={"path": "/var", "top_n": 10},
                ),
                step(
                    "step-2",
                    "生成日志清理候选",
                    "skill_script",
                    "识别可清理日志并排除关键日志。",
                    "返回候选文件、排除原因和建议清理方式。",
                    risk_level="medium",
                    skill_script="ops-basic/log-cleanup-plan",
                    arguments={"root_path": "/var/log", "min_size_mb": 100, "max_depth": 2, "limit": 20},
                    rollback_hint="只读扫描，无需回滚。",
                ),
            ],
            reason="计划中的磁盘和日志候选检查已覆盖当前请求，执行成功后无需再次反思。",
        )
    return answer("测试服务直接返回问答响应。", "已收到请求：" + current_request)


def reflection_response(request_context):
    observation = request_context.get("environment_context", {}).get("agent_observation", {})
    original_request = str(observation.get("original_request") or request_context.get("current_request") or "")
    status = str(observation.get("execution", {}).get("status") or "executed")
    iteration = int(observation.get("iteration") or 1)
    serialized = json.dumps(request_context, ensure_ascii=False)

    if "继续深入" in original_request and iteration == 1:
        return work_plan(
            "继续深入：补充查看 CPU 与内存资源概况。",
            [
                step(
                    "reflect-1",
                    "补充查看 CPU 与内存资源概况",
                    "skill_script",
                    "补充系统资源观察，帮助判断当前异常是否与负载有关。",
                    "返回 CPU、内存与高占用进程摘要。",
                    skill_script="ops-basic/resource-inspect",
                    arguments={"top_n": 5},
                )
            ],
            reason="补充资源检查的预期输出已经满足继续深入请求，执行成功后无需再次反思。",
            thinking_summary="第一轮结果不足以完成测试场景，因此继续采集资源概况。",
        )
    if "非法继续决策" in original_request:
        return {"response_type": "answer", "summary": "缺少 continue_decision 的非法测试响应。", "answer": "invalid"}
    if status == "failed":
        return answer(
            "执行失败后停止自动深入。",
            "当前计划执行失败，已保留失败输出和修复建议；请根据输出确认下一步。",
            reason="当前计划已有失败步骤，需要人工查看失败输出后再决定。",
            thinking_summary="失败结果显示当前流程不适合自动继续。",
        )
    if "ops-basic/resource-inspect" in serialized:
        return answer(
            "资源检查已完成。",
            "资源检查已完成，已根据 skill 返回的 CPU、内存和进程摘要结束本轮诊断。",
            reason="资源检查结果已经足够回答当前请求。",
            thinking_summary="已获得资源 skill 返回的信息，可以结束本轮。",
        )
    if "ops-basic/disk-hotspots" in serialized:
        return answer(
            "磁盘检查已完成。",
            "磁盘检查已完成，已根据 skill 返回的磁盘热点摘要结束本轮；如需清理，应先人工确认候选项。",
            reason="磁盘热点信息已经采集完成；清理类动作需要用户明确批准。",
            thinking_summary="已获得磁盘 skill 返回的信息，后续清理不应自动继续。",
        )
    return answer(
        "观察已完成。",
        "当前执行状态为 " + status + "，本轮已停止自动深入。",
        reason="当前观察结果不足以支持安全的自动下一步，停止深入。",
        thinking_summary="没有发现需要继续自动执行的低风险步骤。",
    )


def repair_response(request_context):
    return work_plan(
        "当前计划执行失败。建议先保留现场日志，检查失败输出，再重新生成更保守的诊断步骤；该修复计划不会自动执行。",
        [
            step(
                "repair-1",
                "检查失败输出",
                "shell",
                "让用户根据失败上下文做人工判断。",
                "展示失败上下文摘要。",
                command="printf %s \"$FAILURE_CONTEXT\"",
                rollback_hint="无需回滚。",
            )
        ],
        reason="修复建议只用于人工参考，不自动继续执行。",
    ) | {"failure_context": json.dumps(request_context, ensure_ascii=False)}


def response_for(messages):
    purpose, request_context, current_request = extract_request(messages)
    if "返回无效JSON" in current_request:
        return "not-json"
    if purpose == "edit":
        if "无效响应" in current_request:
            return answer("非法编辑响应", "invalid edit response")
        return edit_package()
    if purpose == "repair":
        return repair_response(request_context)
    if purpose == "work_reflect":
        return reflection_response(request_context)
    return work_plan_response(current_request)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/health":
            self.send_json({"ok": True})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return

        content = response_for(payload.get("messages", []))
        if not isinstance(content, str):
            content = json.dumps(content, ensure_ascii=False, separators=(",", ":"))
        self.send_json({"choices": [{"message": {"content": content}}]})

    def send_json(self, payload):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
