export const CONFIG_GROUPS = [
  {
    title: "模型与 API",
    note: "控制 LLM 供应商、接口、密钥来源、模型和请求超时。优先使用环境变量或本机 secret 文件。",
    fields: [
      { key: "provider", label: "provider", type: "text", comment: "供应商名称，用于提示当前适配的 OpenAI-compatible 后端。" },
      { key: "api_url", label: "api_url", type: "text", comment: "模型接口地址，通常是 chat/completions 兼容端点。" },
      { key: "api_key", label: "api_key", type: "secret", writeOnly: true, placeholder: "留空保持当前密钥", comment: "写入后保存到本机 secret 文件，不写入 config.json 明文字段。" },
      { key: "model", label: "model", type: "text", comment: "work/edit 等请求调用的模型名。" },
      { key: "request_timeout_sec", label: "request_timeout_sec", type: "number", min: 1, comment: "单次模型请求最长等待秒数。" },
      { key: "context_turns", label: "context_turns", type: "number", min: 1, comment: "保留的上下文轮数，过大可能增加 token 消耗。" },
    ],
  },
  {
    title: "工作流",
    note: "控制自然语言 work、低风险自动执行和模型思考摘要。",
    fields: [
      { key: "agent_loop.enabled_for_work", label: "work_agent_loop", type: "boolean", comment: "执行后带 observation 继续反思，适合多步排障。" },
      { key: "agent_loop.auto_execute_low_risk", label: "auto_execute_low_risk_skill", type: "boolean", comment: "低风险且策略干净的 skill 步骤可自动执行。" },
      { key: "agent_loop.auto_execute_shell_low_risk", label: "auto_execute_low_risk_shell", type: "boolean", comment: "shell 命令即使低风险也建议保持谨慎。" },
      { key: "agent_loop.observation_text_limit", label: "observation_text_limit", type: "number", min: 200, comment: "回传给模型的命令输出摘要上限。" },
      { key: "agent_loop.checkpoint_turns", label: "checkpoint_turns", type: "number", min: 0, comment: "每隔多少轮强制 checkpoint；0 表示使用 context_turns。" },
      { key: "agent_loop.thinking_trace_enabled", label: "thinking_summary", type: "boolean", comment: "开启后会话摘要栏展示模型返回的简短 thinking_summary。" },
    ],
  },
  {
    title: "审计与 Observer",
    note: "控制审计脱敏、observer 后端和事件数量。",
    fields: [
      { key: "audit_mode", label: "audit_mode", type: "select", options: ["safe_summary", "redacted_verbose"], comment: "safe_summary 更克制；redacted_verbose 保留更多脱敏上下文。" },
      { key: "audit_text_limit", label: "audit_text_limit", type: "number", min: 40, comment: "写入审计报告的文本截断长度。" },
      { key: "observer.enabled", label: "observer_backend", type: "select", options: ["auto", "auditd", "disabled"], comment: "auto 会优先尝试 auditd，失败时降级记录诊断。" },
      { key: "observer.privilege", label: "observer_privilege", type: "text", comment: "observer 提权策略，例如 sudo_interactive。" },
      { key: "observer.max_events", label: "observer_max_events", type: "number", min: 0, comment: "单会话 observer 事件上限，避免报告过大。" },
    ],
  },
  {
    title: "执行策略与 Skill",
    note: "控制最小权限代理、远程脚本策略和 skill 根目录。",
    fields: [
      { key: "execution.min_privilege_proxy", label: "min_privilege_proxy", type: "boolean", comment: "尽量使用低权限用户执行命令，降低误操作影响面。" },
      { key: "execution.least_privilege_user", label: "least_privilege_user", type: "text", comment: "低权限代理使用的系统用户。" },
      { key: "remote_script_policy", label: "remote_script_policy", type: "select", options: ["download_review", "disabled"], comment: "远程脚本默认先下载审查；disabled 直接禁用。" },
      { key: "skills_dir", label: "skills_dir", type: "text", comment: "自定义 skill 根目录；空值表示使用项目默认 skills。" },
    ],
  },
];

export const CONFIG_READONLY_FIELDS = [
  { key: "api_key_configured", label: "api_key_configured", comment: "只显示是否已配置，避免在浏览器中暴露已有密钥。" },
  { key: "api_key_source", label: "api_key_source", comment: "env、file、config_legacy 或 missing。" },
  { key: "api_key_file_configured", label: "api_key_file", comment: "只显示 secret 文件是否已配置，不回显路径内容。" },
  { key: "api_key_migration_recommended", label: "api_key_migration", comment: "旧版 config.api_key 仍兼容，但建议迁移。" },
  { key: "web.enabled", label: "web.enabled", comment: "web 服务开关，当前进程已启动时仅作状态展示。" },
  { key: "web.host", label: "web.host", comment: "当前配置文件中的监听地址，改动需重启生效。" },
  { key: "web.port", label: "web.port", comment: "当前配置文件中的监听端口，改动需重启生效。" },
  { key: "web.token_configured", label: "web.token", comment: "只显示 token 是否已配置，不回显 token 明文。" },
  { key: "web.job_retention_hours", label: "web.job_retention_hours", comment: "后端保留 job 文件的小时数，当前进程可能需重启才完全生效。" },
];
