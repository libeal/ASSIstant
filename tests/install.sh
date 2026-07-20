#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/cosign_compat.sh
source "${ROOT_DIR}/tests/cosign_compat.sh"
tmp_root="$(mktemp -d)"
web_pid=""
notify_pid=""
fake_systemd_pidfile=""
fake_systemd_helper_pidfile=""

cleanup() {
    if [[ -n "${web_pid}" ]] && kill -0 "${web_pid}" >/dev/null 2>&1; then
        kill "${web_pid}" >/dev/null 2>&1 || true
        wait "${web_pid}" 2>/dev/null || true
    fi
    if [[ -n "${notify_pid}" ]] && kill -0 "${notify_pid}" >/dev/null 2>&1; then
        kill "${notify_pid}" >/dev/null 2>&1 || true
        wait "${notify_pid}" 2>/dev/null || true
    fi
    if [[ -n "${fake_systemd_pidfile}" && -f "${fake_systemd_pidfile}" ]]; then
        fake_systemd_pid="$(<"${fake_systemd_pidfile}")"
        kill "${fake_systemd_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${fake_systemd_helper_pidfile}" && -f "${fake_systemd_helper_pidfile}" ]]; then
        fake_systemd_helper_pid="$(<"${fake_systemd_helper_pidfile}")"
        kill "${fake_systemd_helper_pid}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

dist_one="${tmp_root}/dist-one"
dist_two="${tmp_root}/dist-two"
dist_three="${tmp_root}/dist-three"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${dist_one}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.1-test "${dist_two}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.2-test "${dist_three}"

repack_core_for_test() {
    local dist_dir="$1"
    local mutation="$2"
    local stage archive_tmp manifest_tmp core_sha core_size
    local -a entries=()
    stage="$(mktemp -d "${tmp_root}/core-repack.XXXXXX")"
    tar -xzf "${dist_dir}/linux-agent-core.tar.gz" -C "${stage}"
    case "${mutation}" in
        unit-v2)
            sed -i '/^\[Service\]$/a Environment=LINUX_AGENT_UNIT_MARKER=v2' \
                "${stage}/packaging/linux-agent-web.service"
            ;;
        fail-restart)
            : >"${stage}/FAIL_RESTART"
            ;;
        fail-helper)
            : >"${stage}/FAIL_HELPER"
            ;;
        managed-config)
            jq --argjson port "${MANAGED_TEST_PORT:?}" \
                --arg token "${MANAGED_TEST_TOKEN:?}" \
                '.web.port = $port | .web.token = $token' \
                "${stage}/config/config.example.json" >"${stage}/config/config.example.json.tmp"
            mv "${stage}/config/config.example.json.tmp" "${stage}/config/config.example.json"
            ;;
        *)
            printf 'unknown core test mutation: %s\n' "${mutation}" >&2
            exit 1
            ;;
    esac
    archive_tmp="${dist_dir}/linux-agent-core.tar.gz.tmp"
    mapfile -t entries < <(find "${stage}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu \
        -C "${stage}" -cf - "${entries[@]}" | gzip -n >"${archive_tmp}"
    mv "${archive_tmp}" "${dist_dir}/linux-agent-core.tar.gz"
    core_sha="$(sha256sum "${dist_dir}/linux-agent-core.tar.gz" | awk '{print $1}')"
    core_size="$(stat -c '%s' "${dist_dir}/linux-agent-core.tar.gz")"
    manifest_tmp="${dist_dir}/release-manifest.json.tmp"
    jq --arg sha "${core_sha}" --argjson size "${core_size}" '
        .assets.core.sha256 = $sha | .assets.core.size_bytes = $size
    ' "${dist_dir}/release-manifest.json" >"${manifest_tmp}"
    mv "${manifest_tmp}" "${dist_dir}/release-manifest.json"
    rm -rf -- "${stage}"
}

prefix="${tmp_root}/prefix"
bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${dist_one}" --prefix "${prefix}" --no-systemd
[[ "$(readlink "${prefix}/current")" == "releases/v0.0.0-test" ]]
[[ -x "${prefix}/current/bin/agent" && -x "${prefix}/current/bin/agent-web" ]]
grep -q '^Type=notify$' "${prefix}/current/packaging/linux-agent-web.service"
grep -q '^ReadWritePaths=/opt/linux-agent/data$' "${prefix}/current/packaging/linux-agent-web.service"
grep -q '^CapabilityBoundingSet=CAP_AUDIT_CONTROL CAP_AUDIT_READ CAP_DAC_READ_SEARCH$' \
    "${prefix}/current/packaging/linux-agent-observer-helper.service"
grep -q '^SocketMode=0660$' "${prefix}/current/packaging/linux-agent-observer-helper.socket"
grep -q '^DirectoryMode=0755$' "${prefix}/current/packaging/linux-agent-observer-helper.socket"
grep -q '^IPAddressDeny=any$' "${prefix}/current/packaging/dropins/10-provider-egress.conf.example"
[[ "$(readlink "${prefix}/releases/v0.0.0-test/config")" == "../../data/config" ]]
[[ "$(stat -c '%a' "${prefix}/data/config/config.json")" == "600" ]]
expected_runtime_user="$(id -un)"
expected_runtime_uid="$(id -u)"
expected_runtime_gid="$(id -g)"
jq -e --arg user "${expected_runtime_user}" '.service_user == $user' \
    "${prefix}/.install-state.json" >/dev/null
for owned_path in "${prefix}" "${prefix}/data" "${prefix}/data/config" \
    "${prefix}/data/logs" "${prefix}/data/tmp" "${prefix}/.install-state.json"; do
    [[ "$(stat -c '%u' "${owned_path}")" == "${expected_runtime_uid}" ]]
    [[ "$(stat -c '%g' "${owned_path}")" == "${expected_runtime_gid}" ]]
done
jq -e '.remote.enabled == true and .remote.release_version == "v0.0.0-test"' \
    "${prefix}/data/config/config.json" >/dev/null
health_json="$(bash "${prefix}/current/bin/agent" api health)"
jq -e '.ok == true and .version == "v0.0.0-test"' <<<"${health_json}" >/dev/null
skills_json="$(bash "${prefix}/current/bin/agent" api skills validate '{}')"
jq -e '.ok == true' <<<"${skills_json}" >/dev/null
while IFS= read -r skill_name; do
    [[ -f "${prefix}/current/skills/${skill_name}/SKILL.md" ]]
    [[ -d "${prefix}/current/skills/${skill_name}/scripts" ]]
done < <(jq -r '.skills | keys[]' "${dist_one}/release-manifest.json")

printf 'persistent-marker\n' >"${prefix}/data/logs/marker"
bash "${ROOT_DIR}/scripts/install.sh" upgrade \
    --version v0.0.1-test --from-dist "${dist_two}" --prefix "${prefix}" --no-systemd
[[ "$(readlink "${prefix}/current")" == "releases/v0.0.1-test" ]]
grep -qx 'persistent-marker' "${prefix}/data/logs/marker"
jq -e '.remote.release_version == "v0.0.1-test"' "${prefix}/data/config/config.json" >/dev/null

bash "${ROOT_DIR}/scripts/install.sh" rollback --prefix "${prefix}" --no-systemd
[[ "$(readlink "${prefix}/current")" == "releases/v0.0.0-test" ]]
jq -e '.remote.release_version == "v0.0.0-test"' "${prefix}/data/config/config.json" >/dev/null

bash "${ROOT_DIR}/scripts/install.sh" upgrade \
    --version v0.0.2-test --from-dist "${dist_three}" --prefix "${prefix}" --keep 2 --no-systemd
[[ "$(readlink "${prefix}/current")" == "releases/v0.0.2-test" ]]
[[ "$(find "${prefix}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]]
grep -qx 'persistent-marker' "${prefix}/data/logs/marker"

bad_dist="${tmp_root}/bad-dist"
cp -a "${dist_one}" "${bad_dist}"
printf 'tampered\n' >>"${bad_dist}/linux-agent-core.tar.gz"
bad_prefix="${tmp_root}/bad-prefix"
if bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${bad_dist}" --prefix "${bad_prefix}" --no-systemd \
    >"${tmp_root}/bad.stdout" 2>"${tmp_root}/bad.stderr"; then
    printf 'install unexpectedly accepted a tampered release asset\n' >&2
    exit 1
fi
grep -q '资产大小校验失败\|资产 SHA256 校验失败' "${tmp_root}/bad.stderr"
[[ ! -e "${bad_prefix}/current" ]]
[[ -z "$(find "${bad_prefix}" -maxdepth 1 -name '.install-staging.*' -print -quit 2>/dev/null)" ]]

bomb_dist="${tmp_root}/bomb-dist"
bomb_stage="${tmp_root}/bomb-stage"
bomb_prefix="${tmp_root}/bomb-prefix"
cp -a "${dist_one}" "${bomb_dist}"
mkdir -p "${bomb_stage}"
truncate -s $((65 * 1024 * 1024)) "${bomb_stage}/oversized.bin"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "${bomb_stage}" -czf \
    "${bomb_dist}/linux-agent-core.tar.gz" oversized.bin
bomb_core_sha="$(sha256sum "${bomb_dist}/linux-agent-core.tar.gz" | awk '{print $1}')"
bomb_core_size="$(stat -c '%s' "${bomb_dist}/linux-agent-core.tar.gz")"
jq --arg sha "${bomb_core_sha}" --argjson size "${bomb_core_size}" \
    '.assets.core.sha256 = $sha | .assets.core.size_bytes = $size' \
    "${bomb_dist}/release-manifest.json" >"${bomb_dist}/release-manifest.json.tmp"
mv "${bomb_dist}/release-manifest.json.tmp" "${bomb_dist}/release-manifest.json"
if bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${bomb_dist}" --prefix "${bomb_prefix}" --no-systemd \
    >"${tmp_root}/bomb.stdout" 2>"${tmp_root}/bomb.stderr"; then
    printf 'install unexpectedly accepted an archive expansion bomb\n' >&2
    exit 1
fi
grep -q 'archive member is too large' "${tmp_root}/bomb.stderr"
[[ ! -e "${bomb_prefix}/current" ]]

tampered_installer="${tmp_root}/tampered-installer.sh"
cp "${ROOT_DIR}/scripts/install.sh" "${tampered_installer}"
printf '\n# tampered installer\n' >>"${tampered_installer}"
if bash "${tampered_installer}" install \
    --version v0.0.0-test --from-dist "${dist_one}" --prefix "${tmp_root}/tampered-installer-prefix" --no-systemd \
    >"${tmp_root}/tampered-installer.stdout" 2>"${tmp_root}/tampered-installer.stderr"; then
    printf 'install unexpectedly accepted an installer not registered by the manifest\n' >&2
    exit 1
fi
grep -q '当前安装器与签名 manifest 登记' "${tmp_root}/tampered-installer.stderr"

signature_prefix="${tmp_root}/signature-prefix"
if bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${dist_one}" --prefix "${signature_prefix}" \
    --require-signature --no-systemd >"${tmp_root}/signature.stdout" 2>"${tmp_root}/signature.stderr"; then
    printf 'install unexpectedly accepted a release without a required signature\n' >&2
    exit 1
fi
grep -Eq '未安装 cosign|没有签名 bundle' "${tmp_root}/signature.stderr"

retry_prefix="${tmp_root}/retry-prefix"
mkdir -p "${retry_prefix}/data/config"
printf '{invalid-json\n' >"${retry_prefix}/data/config/config.json"
if bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${dist_one}" --prefix "${retry_prefix}" --no-systemd \
    >"${tmp_root}/retry.stdout" 2>"${tmp_root}/retry.stderr"; then
    printf 'install unexpectedly accepted an invalid persistent config\n' >&2
    exit 1
fi
grep -q '无法更新持久配置中的 release 版本' "${tmp_root}/retry.stderr"
[[ ! -e "${retry_prefix}/current" ]]
[[ ! -e "${retry_prefix}/releases/v0.0.0-test" ]]
grep -qx '{invalid-json' "${retry_prefix}/data/config/config.json"
[[ -z "$(find "${retry_prefix}" -maxdepth 1 \( -name '.install-staging.*' -o -name '.install-rollback.*' \) -print -quit)" ]]
cp "${ROOT_DIR}/config/config.example.json" "${retry_prefix}/data/config/config.json"
bash "${ROOT_DIR}/scripts/install.sh" install \
    --version v0.0.0-test --from-dist "${dist_one}" --prefix "${retry_prefix}" --no-systemd
[[ "$(readlink "${retry_prefix}/current")" == "releases/v0.0.0-test" ]]

protected_prefix="${tmp_root}/protected-systemd-prefix"
if bash "${ROOT_DIR}/scripts/install.sh" status --prefix "${protected_prefix}" \
    >"${tmp_root}/protected-prefix.stdout" 2>"${tmp_root}/protected-prefix.stderr"; then
    printf 'systemd mode unexpectedly accepted a prefix hidden by PrivateTmp\n' >&2
    exit 1
fi
grep -q 'systemd 模式的 --prefix 不能位于' "${tmp_root}/protected-prefix.stderr"
bash "${ROOT_DIR}/scripts/install.sh" status --prefix "${protected_prefix}" --no-systemd >/dev/null
if bash "${ROOT_DIR}/scripts/install.sh" status --prefix "${protected_prefix}" --no-systemd \
    --provider-cidr 203.0.113.7 >"${tmp_root}/egress-no-systemd.stdout" 2>"${tmp_root}/egress-no-systemd.stderr"; then
    printf 'no-systemd mode unexpectedly accepted a Provider CIDR policy\n' >&2
    exit 1
fi
grep -q '仅适用于 systemd 模式' "${tmp_root}/egress-no-systemd.stderr"

if command -v cosign >/dev/null 2>&1; then
    signed_dist="${tmp_root}/signed-dist"
    signed_prefix="${tmp_root}/signed-prefix"
    cosign_dir="${tmp_root}/cosign"
    cp -a "${dist_one}" "${signed_dist}"
    mkdir -p "${cosign_dir}"
    (
        cd "${cosign_dir}"
        COSIGN_PASSWORD=install-test cosign generate-key-pair >/dev/null
        COSIGN_PASSWORD=install-test linux_agent_test_cosign_sign_blob \
            cosign.key "${signed_dist}/release-manifest.json.sigstore.json" \
            "${signed_dist}/release-manifest.json" >/dev/null
    )
    LINUX_AGENT_SIGNATURE_PUBKEY="${cosign_dir}/cosign.pub" \
        bash "${ROOT_DIR}/scripts/install.sh" install \
        --version v0.0.0-test --from-dist "${signed_dist}" --prefix "${signed_prefix}" \
        --require-signature --no-systemd
    [[ "$(readlink "${signed_prefix}/current")" == "releases/v0.0.0-test" ]]
else
    printf 'install: cosign not installed; signed installer scenario skipped\n'
fi

if command -v unshare >/dev/null 2>&1 && unshare -Ur true >/dev/null 2>&1; then
    managed_prefix="${tmp_root}/managed-prefix"
    managed_unit_path="${managed_prefix}/systemd/linux-agent-web.service"
    fake_systemd_dir="${tmp_root}/fake-systemd"
    fake_systemd_bin="${tmp_root}/fake-systemd-bin"
    fake_systemd_pidfile="${fake_systemd_dir}/service.pid"
    fake_systemd_helper_pidfile="${fake_systemd_dir}/helper.pid"
    managed_observer_socket="${managed_prefix}/systemd/observer.sock"
    managed_observer_state="${managed_prefix}/systemd/observer-capabilities.json"
    managed_dist_one="${tmp_root}/managed-dist-one"
    managed_dist_two="${tmp_root}/managed-dist-two"
    failing_dist_three="${tmp_root}/failing-dist-three"
    failing_helper_dist_three="${tmp_root}/failing-helper-dist-three"
    mkdir -p "${managed_prefix}/systemd" "${fake_systemd_dir}" "${fake_systemd_bin}"
    cp -a "${dist_one}" "${managed_dist_one}"
    cp -a "${dist_two}" "${managed_dist_two}"
    cp -a "${dist_three}" "${failing_dist_three}"
    cp -a "${dist_three}" "${failing_helper_dist_three}"
    MANAGED_TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
    MANAGED_TEST_TOKEN="install-managed-token"
    export MANAGED_TEST_PORT MANAGED_TEST_TOKEN
    repack_core_for_test "${managed_dist_one}" managed-config
    repack_core_for_test "${managed_dist_two}" unit-v2
    repack_core_for_test "${failing_dist_three}" fail-restart
    repack_core_for_test "${failing_helper_dist_three}" fail-helper
    failing_core_listing="$(tar -tzf "${failing_dist_three}/linux-agent-core.tar.gz")"
    grep -qx 'FAIL_RESTART' <<<"${failing_core_listing}"

    cat >"${fake_systemd_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
printf '%s\n' "${command_name}" >>"${FAKE_SYSTEMD_STATE}/commands"

stop_service() {
    local pid="" helper_pid=""
    if [[ -f "${FAKE_SYSTEMD_STATE}/service.pid" ]]; then
        pid="$(<"${FAKE_SYSTEMD_STATE}/service.pid")"
        kill "${pid}" >/dev/null 2>&1 || true
        for _ in $(seq 1 100); do
            kill -0 "${pid}" >/dev/null 2>&1 || break
            sleep 0.02
        done
        rm -f -- "${FAKE_SYSTEMD_STATE}/service.pid"
    fi
    if [[ -f "${FAKE_SYSTEMD_STATE}/helper.pid" ]]; then
        helper_pid="$(<"${FAKE_SYSTEMD_STATE}/helper.pid")"
        kill "${helper_pid}" >/dev/null 2>&1 || true
        wait "${helper_pid}" 2>/dev/null || true
        rm -f -- "${FAKE_SYSTEMD_STATE}/helper.pid"
    fi
    rm -f -- "${LINUX_AGENT_OBSERVER_HELPER_SOCKET}"
}

start_helper() {
    if [[ -f "${FAKE_SYSTEMD_STATE}/helper.pid" ]] &&
        kill -0 "$(<"${FAKE_SYSTEMD_STATE}/helper.pid")" >/dev/null 2>&1; then
        return 0
    fi
    [[ "${FAKE_HELPER_FAIL:-0}" != "1" ]] || return 0
    [[ ! -f "${FAKE_SYSTEMD_PREFIX}/current/FAIL_HELPER" ]] || return 0
    python3 - "${LINUX_AGENT_OBSERVER_HELPER_SOCKET}" <<'PY' \
        >"${FAKE_SYSTEMD_STATE}/helper.stdout" \
        2>"${FAKE_SYSTEMD_STATE}/helper.stderr" &
import json
import os
import socket
import sys

path = sys.argv[1]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(path)
    os.chmod(path, 0o660)
    server.listen()
    while True:
        connection, _ = server.accept()
        with connection:
            payload = bytearray()
            while b"\n" not in payload:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                payload.extend(chunk)
            request = json.loads(payload.decode("utf-8"))
            operation = request.get("operation")
            operation_ok = operation in ("ping", "status")
            response = {
                "ok": operation_ok,
                "status": "ready" if operation_ok else "invalid_request",
                "exit_code": 0 if operation_ok else 126,
                "stdout": "enabled 1\n" if operation == "status" else "",
                "stderr": "" if operation_ok else "unsupported test operation",
            }
            connection.sendall(json.dumps(response).encode("utf-8") + b"\n")
PY
    printf '%s\n' "$!" >"${FAKE_SYSTEMD_STATE}/helper.pid"
}

start_service() {
    [[ ! -f "${FAKE_SYSTEMD_PREFIX}/current/FAIL_RESTART" ]] || return 1
    stop_service
    start_helper
    (
        unset NOTIFY_SOCKET
        exec bash "${FAKE_SYSTEMD_PREFIX}/current/bin/agent-web"
    ) >"${FAKE_SYSTEMD_STATE}/web.stdout" 2>"${FAKE_SYSTEMD_STATE}/web.stderr" </dev/null &
    printf '%s\n' "$!" >"${FAKE_SYSTEMD_STATE}/service.pid"
}

case "${command_name}" in
    daemon-reload) ;;
    cat) ;;
    is-enabled)
        [[ -f "${FAKE_SYSTEMD_STATE}/enabled" ]]
        ;;
    is-active)
        active=0
        if [[ " $* " == *" linux-agent-web.service "* &&
            -f "${FAKE_SYSTEMD_STATE}/service.pid" ]] &&
            kill -0 "$(<"${FAKE_SYSTEMD_STATE}/service.pid")" >/dev/null 2>&1; then
            active=1
        elif [[ " $* " == *" linux-agent-observer-helper.socket "* &&
            -S "${LINUX_AGENT_OBSERVER_HELPER_SOCKET}" ]]; then
            active=1
        elif [[ " $* " == *" linux-agent-observer-helper.service "* &&
            -f "${FAKE_SYSTEMD_STATE}/helper.pid" ]] &&
            kill -0 "$(<"${FAKE_SYSTEMD_STATE}/helper.pid")" >/dev/null 2>&1; then
            active=1
        fi
        if [[ "${active}" -eq 1 ]]; then
            [[ " $* " == *" --quiet "* ]] || printf 'active\n'
        else
            [[ " $* " == *" --quiet "* ]] || printf 'inactive\n'
            exit 3
        fi
        ;;
    enable)
        : >"${FAKE_SYSTEMD_STATE}/enabled"
        if [[ " $* " == *" --now "* ]]; then
            start_service
        fi
        ;;
    disable)
        rm -f -- "${FAKE_SYSTEMD_STATE}/enabled"
        if [[ " $* " == *" --now "* ]]; then
            stop_service
        fi
        ;;
    restart) start_service ;;
    start)
        if [[ " $* " == *" linux-agent-observer-helper.socket "* &&
            " $* " != *" linux-agent-web.service "* ]]; then
            start_helper
        elif [[ " $* " == *" linux-agent-observer-helper.service "* &&
            " $* " != *" linux-agent-web.service "* ]]; then
            start_helper
        elif [[ ! -f "${FAKE_SYSTEMD_STATE}/service.pid" ]] ||
            ! kill -0 "$(<"${FAKE_SYSTEMD_STATE}/service.pid")" >/dev/null 2>&1; then
            start_service
        fi
        ;;
    stop) stop_service ;;
    *)
        printf 'unsupported fake systemctl command: %s\n' "${command_name}" >&2
        exit 2
        ;;
esac
SH
    cat >"${fake_systemd_bin}/systemd-analyze" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "verify" ]]
printf 'verify\n' >>"${FAKE_SYSTEMD_STATE}/commands"
if [[ "${FAKE_SYSTEMD_ANALYZE_FAIL:-0}" == "1" ]]; then
    printf 'Unknown lvalue ProtectSystem\n' >&2
    exit 1
fi
SH
    cat >"${fake_systemd_bin}/getenforce" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SELINUX_STATUS:-Disabled}"
SH
    cat >"${fake_systemd_bin}/restorecon" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'restorecon %s\n' "$*" >>"${FAKE_SYSTEMD_STATE}/commands"
SH
    chmod 0755 "${fake_systemd_bin}/systemctl" "${fake_systemd_bin}/systemd-analyze" \
        "${fake_systemd_bin}/getenforce" "${fake_systemd_bin}/restorecon"

    run_managed_installer() {
        unshare -Ur env \
            PATH="${fake_systemd_bin}:${PATH}" \
            FAKE_SYSTEMD_PREFIX="${managed_prefix}" \
            FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
            LINUX_AGENT_SYSTEMD_UNIT_PATH="${managed_unit_path}" \
            LINUX_AGENT_OBSERVER_HELPER_SOCKET="${managed_observer_socket}" \
            LINUX_AGENT_OBSERVER_HELPER_STATE="${managed_observer_state}" \
            LINUX_AGENT_INSTALL_HEALTH_ATTEMPTS=6 \
            LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX=1 \
            LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS=1 \
            bash "${ROOT_DIR}/scripts/install.sh" "$@" \
            --prefix "${managed_prefix}" --service-user root
    }

    if run_managed_installer install --version v0.0.0-test --from-dist "${managed_dist_one}" \
        >"${tmp_root}/missing-egress.stdout" 2>"${tmp_root}/missing-egress.stderr"; then
        printf 'managed install unexpectedly accepted an implicit egress policy\n' >&2
        exit 1
    fi
    grep -q '首次安装必须提供 --provider-cidr' "${tmp_root}/missing-egress.stderr"
    sleep 300 &
    printf '%s\n' "$!" >"${fake_systemd_dir}/service.pid"
    : >"${fake_systemd_dir}/enabled"
    if ! run_managed_installer install --version v0.0.0-test --from-dist "${managed_dist_one}" \
        --provider-cidr 127.0.0.1; then
        printf 'managed install failed; fake systemd commands:\n' >&2
        sed -n '1,160p' "${fake_systemd_dir}/commands" >&2 2>/dev/null || true
        printf 'managed Web stderr:\n' >&2
        sed -n '1,200p' "${fake_systemd_dir}/web.stderr" >&2 2>/dev/null || true
        exit 1
    fi
    [[ -f "${fake_systemd_dir}/enabled" ]]
    [[ ! -f "${fake_systemd_dir}/service.pid" ]]
    grep -q '^start$' "${fake_systemd_dir}/commands"
    grep -q '^stop$' "${fake_systemd_dir}/commands"
    if grep -q '^disable$' "${fake_systemd_dir}/commands"; then
        printf 'managed install unexpectedly changed the existing enabled state\n' >&2
        exit 1
    fi
    if grep -q '^enable$' "${fake_systemd_dir}/commands"; then
        printf 'managed install unexpectedly enabled systemd units\n' >&2
        exit 1
    fi
    managed_egress_path="${managed_prefix}/systemd/linux-agent-web.service.d/10-provider-egress.conf"
    grep -q '^IPAddressDeny=any$' "${managed_egress_path}"
    grep -q '^IPAddressAllow=localhost$' "${managed_egress_path}"
    grep -q '^IPAddressAllow=127.0.0.1/32$' "${managed_egress_path}"
    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${managed_observer_socket}" \
        "${fake_systemd_bin}/systemctl" enable --now \
        linux-agent-observer-helper.socket linux-agent-web.service
    run_managed_installer upgrade --version v0.0.1-test --from-dist "${managed_dist_two}"
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    grep -q "^ExecStart=/usr/bin/python3 ${managed_prefix}/current/lib/observer_helper.py serve$" \
        "${managed_prefix}/systemd/linux-agent-observer-helper.service"
    grep -q '^Restart=on-failure$' \
        "${managed_prefix}/systemd/linux-agent-observer-helper.service"
    grep -q '^SocketGroup=root$' "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    grep -q '^DirectoryMode=0755$' "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    grep -q '^verify$' "${fake_systemd_dir}/commands"
    if FAKE_SYSTEMD_ANALYZE_FAIL=1 run_managed_installer repair-observer \
        >"${tmp_root}/systemd-verify.stdout" 2>"${tmp_root}/systemd-verify.stderr"; then
        printf 'managed repair unexpectedly accepted incompatible systemd units\n' >&2
        exit 1
    fi
    grep -q '当前 systemd 不支持' "${tmp_root}/systemd-verify.stderr"
    FAKE_SELINUX_STATUS=Enforcing run_managed_installer repair-observer
    grep -q '^restorecon ' "${fake_systemd_dir}/commands"
    sed -i 's/^SocketGroup=root$/SocketGroup=stale-group/' \
        "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    run_managed_installer repair-observer
    grep -q '^SocketGroup=root$' "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    rm -f -- "${managed_observer_socket}"
    if run_managed_installer repair-observer \
        >"${tmp_root}/managed-inconsistent-state.stdout" \
        2>"${tmp_root}/managed-inconsistent-state.stderr"; then
        printf 'managed observer repair unexpectedly changed an inconsistent active state\n' >&2
        exit 1
    fi
    grep -q 'Web 正在运行但其必需的 observer helper socket 已停止' \
        "${tmp_root}/managed-inconsistent-state.stderr"
    [[ -f "${fake_systemd_dir}/service.pid" ]]
    [[ ! -S "${managed_observer_socket}" ]]
    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${managed_observer_socket}" \
        "${fake_systemd_bin}/systemctl" restart linux-agent-web.service
    for _ in $(seq 1 100); do
        [[ -S "${managed_observer_socket}" ]] && break
        sleep 0.02
    done
    [[ -S "${managed_observer_socket}" ]]
    sed -i 's/^SocketGroup=root$/SocketGroup=rollback-group/' \
        "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    printf 'managed-state-marker\n' >"${managed_observer_state}"
    chmod 0600 "${managed_observer_state}"
    : >"${managed_prefix}/current/FAIL_HELPER"
    if run_managed_installer repair-observer \
        >"${tmp_root}/managed-repair-failure.stdout" \
        2>"${tmp_root}/managed-repair-failure.stderr"; then
        printf 'managed observer repair unexpectedly accepted a failed helper health check\n' >&2
        exit 1
    fi
    rm -f -- "${managed_prefix}/current/FAIL_HELPER"
    grep -q '^SocketGroup=rollback-group$' \
        "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    grep -qx 'managed-state-marker' "${managed_observer_state}"
    [[ -f "${fake_systemd_dir}/service.pid" ]]
    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${managed_observer_socket}" \
        "${fake_systemd_bin}/systemctl" restart linux-agent-web.service
    for _ in $(seq 1 100); do
        [[ -S "${managed_observer_socket}" ]] && break
        sleep 0.02
    done
    [[ -S "${managed_observer_socket}" ]]
    run_managed_installer repair-observer
    grep -q '^SocketGroup=root$' "${managed_prefix}/systemd/linux-agent-observer-helper.socket"
    managed_egress_sha="$(sha256sum "${managed_egress_path}" | awk '{print $1}')"
    if run_managed_installer upgrade --version v0.0.2-test --from-dist "${failing_dist_three}" \
        >"${tmp_root}/managed-failure.stdout" 2>"${tmp_root}/managed-failure.stderr"; then
        printf 'managed upgrade unexpectedly accepted an unhealthy release\n' >&2
        exit 1
    fi
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.1-test" ]]
    [[ ! -e "${managed_prefix}/releases/v0.0.2-test" ]]
    jq -e '.remote.release_version == "v0.0.1-test"' "${managed_prefix}/data/config/config.json" >/dev/null
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    [[ "$(sha256sum "${managed_egress_path}" | awk '{print $1}')" == "${managed_egress_sha}" ]]
    if run_managed_installer upgrade --version v0.0.2-test --from-dist "${failing_helper_dist_three}" \
        >"${tmp_root}/managed-helper-failure.stdout" 2>"${tmp_root}/managed-helper-failure.stderr"; then
        printf 'managed upgrade unexpectedly accepted an unreachable observer helper\n' >&2
        exit 1
    fi
    grep -q 'observer helper request failed' "${tmp_root}/managed-helper-failure.stderr"
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.1-test" ]]
    [[ ! -e "${managed_prefix}/releases/v0.0.2-test" ]]
    run_managed_installer upgrade --version v0.0.2-test --from-dist "${dist_three}"
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.2-test" ]]
    ! grep -q 'LINUX_AGENT_UNIT_MARKER' "${managed_unit_path}"
    run_managed_installer rollback
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.1-test" ]]
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    [[ -z "$(find "${managed_prefix}" -maxdepth 1 -name '.linux-agent-web.service.*' -print -quit)" ]]
    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${managed_observer_socket}" \
        "${fake_systemd_bin}/systemctl" stop linux-agent-web.service
    run_managed_installer repair-observer
    [[ ! -f "${fake_systemd_dir}/service.pid" ]]
    [[ ! -f "${fake_systemd_dir}/helper.pid" ]]
    [[ ! -S "${managed_observer_socket}" ]]

    source_prefix="${tmp_root}/source-prefix"
    source_unit_path="${source_prefix}/systemd/linux-agent-web.service"
    source_helper_service_path="${source_prefix}/systemd/linux-agent-observer-helper.service"
    source_helper_socket_path="${source_prefix}/systemd/linux-agent-observer-helper.socket"
    source_observer_socket="${source_prefix}/systemd/source-observer.sock"
    source_observer_state="${source_prefix}/systemd/observer-capabilities.json"
    source_runtime_root="${source_prefix}/systemd/libexec"
    mkdir -p "${source_prefix}/bin" "${source_prefix}/lib" \
        "${source_prefix}/packaging" "${source_prefix}/systemd"
    cp "${ROOT_DIR}/bin/agent-web" "${source_prefix}/bin/agent-web"
    cp "${ROOT_DIR}/lib/observer_helper.py" "${source_prefix}/lib/observer_helper.py"
    cp "${ROOT_DIR}/lib/subprocess_env.py" "${source_prefix}/lib/subprocess_env.py"
    cp "${ROOT_DIR}/packaging/linux-agent-observer-helper.service" \
        "${source_prefix}/packaging/linux-agent-observer-helper.service"
    cp "${ROOT_DIR}/packaging/linux-agent-observer-helper.socket" \
        "${source_prefix}/packaging/linux-agent-observer-helper.socket"
    printf '%s\n%s\n' '[Service]' 'User=root' >"${source_unit_path}"
    cp "${ROOT_DIR}/packaging/linux-agent-observer-helper.service" \
        "${source_helper_service_path}"
    cp "${ROOT_DIR}/packaging/linux-agent-observer-helper.socket" "${source_helper_socket_path}"

    run_source_observer_repair() {
        unshare -Ur env \
            PATH="${fake_systemd_bin}:${PATH}" \
            FAKE_SYSTEMD_PREFIX="${source_prefix}" \
            FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
            LINUX_AGENT_SYSTEMD_UNIT_PATH="${source_unit_path}" \
            LINUX_AGENT_SYSTEMD_HELPER_SERVICE_PATH="${source_helper_service_path}" \
            LINUX_AGENT_SYSTEMD_HELPER_SOCKET_PATH="${source_helper_socket_path}" \
            LINUX_AGENT_OBSERVER_HELPER_SOCKET="${source_observer_socket}" \
            LINUX_AGENT_OBSERVER_HELPER_STATE="${source_observer_state}" \
            LINUX_AGENT_SOURCE_HELPER_INSTALL_ROOT="${source_runtime_root}" \
            LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX=1 \
            LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS=1 \
            "$@" bash "${ROOT_DIR}/scripts/install.sh" repair-observer \
            --prefix "${source_prefix}" --service-user root
    }

    if unshare -Ur env \
        PATH="${fake_systemd_bin}:${PATH}" \
        LINUX_AGENT_SYSTEMD_UNIT_PATH="${source_unit_path}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${tmp_root}/foreign.sock" \
        LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX=1 \
        LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS=1 \
        bash "${ROOT_DIR}/scripts/install.sh" repair-observer \
        --prefix "${source_prefix}" --service-user root \
        >"${tmp_root}/unsafe-observer-repair.stdout" \
        2>"${tmp_root}/unsafe-observer-repair.stderr"; then
        printf 'source repair unexpectedly accepted an unrelated socket path\n' >&2
        exit 1
    fi
    grep -q '仅允许重建 /run/linux-agent' "${tmp_root}/unsafe-observer-repair.stderr"
    run_source_observer_repair
    grep -q '^SocketGroup=root$' \
        "${source_helper_socket_path}.d/10-socket-group.conf"
    source_runtime_helper="$(sed -n \
        's#^ExecStart=/usr/bin/python3 \(.*\) serve$#\1#p' \
        "${source_helper_service_path}.d/10-source-runtime.conf")"
    [[ "${source_runtime_helper}" == "${source_runtime_root}/"*/observer_helper.py ]]
    [[ -x "${source_runtime_helper}" ]]
    [[ -f "$(dirname -- "${source_runtime_helper}")/subprocess_env.py" ]]
    [[ "$(stat -c '%u:%g' "${source_runtime_helper}")" == "$(id -u):$(id -g)" ]]
    [[ ! -f "${fake_systemd_dir}/helper.pid" ]]
    [[ ! -S "${source_observer_socket}" ]]

    printf 'source-state-marker\n' >"${source_observer_state}"
    chmod 0600 "${source_observer_state}"
    if run_source_observer_repair FAKE_HELPER_FAIL=1 \
        >"${tmp_root}/source-observer-failure.stdout" \
        2>"${tmp_root}/source-observer-failure.stderr"; then
        printf 'source repair unexpectedly accepted a failed helper health check\n' >&2
        exit 1
    fi
    grep -q '^SocketGroup=root$' \
        "${source_helper_socket_path}.d/10-socket-group.conf"
    grep -qx 'source-state-marker' "${source_observer_state}"
    [[ ! -f "${fake_systemd_dir}/helper.pid" ]]
    [[ ! -S "${source_observer_socket}" ]]

    unshare -Ur env \
        PATH="${fake_systemd_bin}:${PATH}" \
        FAKE_SYSTEMD_PREFIX="${source_prefix}" \
        FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${source_observer_socket}" \
        "${fake_systemd_bin}/systemctl" start linux-agent-observer-helper.socket
    for _ in $(seq 1 100); do
        [[ -S "${source_observer_socket}" ]] && break
        sleep 0.02
    done
    [[ -S "${source_observer_socket}" ]]
    [[ -f "${fake_systemd_dir}/helper.pid" ]]
    run_source_observer_repair
    [[ -S "${source_observer_socket}" ]]
    [[ -f "${fake_systemd_dir}/helper.pid" ]]

    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        LINUX_AGENT_OBSERVER_HELPER_SOCKET="${source_observer_socket}" \
        "${fake_systemd_bin}/systemctl" stop linux-agent-web.service
    fake_systemd_pidfile=""
    fake_systemd_helper_pidfile=""
else
    printf 'install: user namespaces unavailable; managed systemd transaction scenario skipped\n'
fi

port="$((24000 + RANDOM % 1000))"
config_tmp="${tmp_root}/config.json"
jq --argjson port "${port}" '.web.port = $port | .web.token = "install-health-token"' \
    "${prefix}/data/config/config.json" >"${config_tmp}"
mv "${config_tmp}" "${prefix}/data/config/config.json"
chmod 0600 "${prefix}/data/config/config.json"
notify_socket="${tmp_root}/notify.sock"
notify_output="${tmp_root}/notify.message"
python3 - "${notify_socket}" "${notify_output}" <<'PY' &
import socket
import sys

address, output = sys.argv[1:]
with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as server:
    server.bind(address)
    server.settimeout(15)
    message = server.recv(4096)
with open(output, "wb") as handle:
    handle.write(message)
PY
notify_pid="$!"
for _ in $(seq 1 50); do
    [[ -S "${notify_socket}" ]] && break
    sleep 0.02
done
[[ -S "${notify_socket}" ]]
NOTIFY_SOCKET="${notify_socket}" bash "${prefix}/current/bin/agent-web" \
    >"${tmp_root}/web.stdout" 2>"${tmp_root}/web.stderr" &
web_pid="$!"
for _ in $(seq 1 80); do
    if curl --noproxy '*' -fsS -H 'Authorization: Bearer install-health-token' \
        "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if ! kill -0 "${web_pid}" >/dev/null 2>&1; then
    printf 'installed Web process exited before becoming healthy\n' >&2
    sed -n '1,160p' "${tmp_root}/web.stderr" >&2
    exit 1
fi
installer_health="$(bash "${ROOT_DIR}/scripts/install.sh" health --prefix "${prefix}")"
jq -e '.ok == true and .status == "ok"' <<<"${installer_health}" >/dev/null
find "${prefix}/data/logs" -maxdepth 1 -type f -name 'web_*.jsonl' -print -quit | grep -q .
wait "${notify_pid}"
notify_pid=""
grep -q '^READY=1' "${notify_output}"

status_json="$(bash "${ROOT_DIR}/scripts/install.sh" status --prefix "${prefix}")"
jq -e '.ok == true and .current_version == "v0.0.2-test" and .service_status == "not-managed"' \
    <<<"${status_json}" >/dev/null

printf 'install: ok\n'
