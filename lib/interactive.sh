#!/usr/bin/env bash

linux_agent_slash_command_rows() {
  cat <<'EOF'
/work	切换到工作模式：生成计划、逐步审批并执行
/edit	切换到编辑模式：通过 AI 新建或修改 skill
/script	切换到脚本模式：执行已登记的 skill 脚本
/terminal	切换到终端模式：直接执行本机 shell 命令并记录日志
/mode	打开模式选择菜单
/help	显示帮助
/exit	退出 CLI
EOF
}

linux_agent_slash_menu_rows() {
  local cmd desc
  while IFS=$'\t' read -r cmd desc; do
    [[ "${cmd}" == "/mode" ]] && continue
    printf '%s\t%s\n' "${cmd}" "${desc}"
  done < <(linux_agent_slash_command_rows)
}

linux_agent_mode_rows() {
  cat <<'EOF'
work	工作模式：生成计划、逐步审批并执行
edit	编辑模式：通过 AI 新建或修改 skill
script	脚本模式：执行已登记的 skill 脚本
terminal	终端模式：直接执行本机 shell 命令并记录日志
EOF
}

linux_agent_read_repl_input() {
  local mode="$1"
  local output_var="$2"
  local input=""

  if [[ -t 0 ]]; then
    IFS= read -e -r -p $'\n'"[${mode}]> " input || return 1
  else
    printf '\n[%s]> ' "${mode}"
    IFS= read -r input || return 1
  fi

  printf -v "${output_var}" '%s' "${input}"
}

linux_agent_menu_select() {
  local title="$1"
  local rows="$2"
  local values=()
  local labels=()
  local line value label

  while IFS=$'\t' read -r value label; do
    [[ -z "${value}" ]] && continue
    values+=("$value")
    labels+=("$label")
  done <<<"${rows}"

  [[ "${#values[@]}" -eq 0 ]] && return 1

  local selected=0
  local count="${#values[@]}"
  local key rest menu_fd menu_in menu_out close_menu=0
  local menu_lines

  if { exec {menu_fd}<>/dev/tty; } 2>/dev/null; then
    menu_in="${menu_fd}"
    menu_out="${menu_fd}"
    close_menu=1
  elif [[ -t 0 && -t 2 ]]; then
    menu_in=0
    menu_out=2
  else
    if [[ "${count}" -eq 1 ]]; then
      printf '%s\n' "${values[0]}"
      return 0
    fi
    printf '当前环境不能打开交互菜单，请直接输入完整命令：\n' >&2
    local fallback_i
    for ((fallback_i = 0; fallback_i < count; fallback_i++)); do
      printf '  %s  %s\n' "${values[fallback_i]}" "${labels[fallback_i]}" >&2
    done
    return 1
  fi

  menu_lines=$((count + 1))
  printf '\033[?25l' >&"${menu_out}"
  trap 'printf "\033[?25h" >&2 2>/dev/null || true' RETURN

  while true; do
    printf '\r\033[K%s\n' "${title}" >&"${menu_out}"
    local i
    for ((i = 0; i < count; i++)); do
      if [[ "${i}" -eq "${selected}" ]]; then
        printf '\033[7m  %s  %s\033[0m\n' "${values[i]}" "${labels[i]}" >&"${menu_out}"
      else
        printf '  %s  %s\n' "${values[i]}" "${labels[i]}" >&"${menu_out}"
      fi
    done

    IFS= read -rsn1 key <&"${menu_in}"
    case "${key}" in
      "")
        linux_agent_menu_clear "${menu_out}" "${menu_lines}"
        printf '\033[?25h' >&"${menu_out}"
        trap - RETURN
        [[ "${close_menu}" -eq 1 ]] && exec {menu_fd}>&-
        printf '%s\n' "${values[selected]}"
        return 0
        ;;
      $'\e')
        IFS= read -rsn2 -t 0.05 rest <&"${menu_in}" || rest=""
        case "${rest}" in
          "[A")
            selected=$(((selected - 1 + count) % count))
            ;;
          "[B")
            selected=$(((selected + 1) % count))
            ;;
          *)
            linux_agent_menu_clear "${menu_out}" "${menu_lines}"
            printf '\033[?25h' >&"${menu_out}"
            trap - RETURN
            [[ "${close_menu}" -eq 1 ]] && exec {menu_fd}>&-
            return 1
            ;;
        esac
        ;;
    esac

    printf '\033[%sA' "$((count + 1))" >&"${menu_out}"
  done
}

linux_agent_menu_clear() {
  local out_fd="$1"
  local line_count="$2"
  local i

  printf '\033[%sA' "${line_count}" >&"${out_fd}"
  for ((i = 0; i < line_count; i++)); do
    printf '\r\033[K' >&"${out_fd}"
    if [[ "${i}" -lt $((line_count - 1)) ]]; then
      printf '\033[1B' >&"${out_fd}"
    fi
  done
  if [[ "${line_count}" -gt 1 ]]; then
    printf '\033[%sA' "$((line_count - 1))" >&"${out_fd}"
  fi
}

linux_agent_slash_command_complete() {
  local input="$1"
  [[ "${input}" != /* ]] && {
    printf '%s\n' "${input}"
    return 0
  }

  local matches=""
  local exact_match=""
  local command_rows
  local cmd desc
  if [[ "${input}" == "/" ]]; then
    command_rows="$(linux_agent_slash_menu_rows)"
  else
    command_rows="$(linux_agent_slash_command_rows)"
  fi

  while IFS=$'\t' read -r cmd desc; do
    [[ -z "${cmd}" ]] && continue
    if [[ "${input}" == "${cmd}" ]]; then
      exact_match="${cmd}"
      break
    fi
    if [[ "${cmd}" == "${input}"* ]]; then
      matches+="${cmd}"$'\t'"${desc}"$'\n'
    fi
  done <<<"${command_rows}"

  if [[ -n "${exact_match}" ]]; then
    printf '%s\n' "${exact_match}"
    return 0
  fi

  [[ -z "${matches}" ]] && {
    printf '未知 / 命令: %s。输入 / 或 /help 查看可用命令。\n' "${input}" >&2
    return 1
  }

  linux_agent_menu_select "请选择命令" "${matches%$'\n'}"
}

linux_agent_mode_menu() {
  local current_mode="${1:-work}"
  local rows selected

  rows="$(linux_agent_mode_rows)"
  selected="$(linux_agent_menu_select "请选择模式（当前：${current_mode}）" "${rows}")" || return 1
  printf '%s\n' "${selected}"
}
