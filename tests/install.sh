#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
web_pid=""
notify_pid=""
fake_systemd_pidfile=""

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
[[ "$(readlink "${prefix}/releases/v0.0.0-test/config")" == "../../data/config" ]]
[[ "$(stat -c '%a' "${prefix}/data/config/config.json")" == "600" ]]
jq -e '.remote.enabled == true and .remote.release_version == "v0.0.0-test"' \
    "${prefix}/data/config/config.json" >/dev/null
health_json="$(bash "${prefix}/current/bin/agent" api health)"
jq -e '.ok == true and .version == "v0.0.0-test"' <<<"${health_json}" >/dev/null

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

if command -v cosign >/dev/null 2>&1; then
    signed_dist="${tmp_root}/signed-dist"
    signed_prefix="${tmp_root}/signed-prefix"
    cosign_dir="${tmp_root}/cosign"
    cp -a "${dist_one}" "${signed_dist}"
    mkdir -p "${cosign_dir}"
    (
        cd "${cosign_dir}"
        COSIGN_PASSWORD=install-test cosign generate-key-pair >/dev/null
        COSIGN_PASSWORD=install-test cosign sign-blob --yes --tlog-upload=false --key cosign.key \
            --bundle "${signed_dist}/release-manifest.json.sigstore.json" \
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
    managed_dist_one="${tmp_root}/managed-dist-one"
    managed_dist_two="${tmp_root}/managed-dist-two"
    failing_dist_three="${tmp_root}/failing-dist-three"
    mkdir -p "${managed_prefix}/systemd" "${fake_systemd_dir}" "${fake_systemd_bin}"
    cp -a "${dist_one}" "${managed_dist_one}"
    cp -a "${dist_two}" "${managed_dist_two}"
    cp -a "${dist_three}" "${failing_dist_three}"
    MANAGED_TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
    MANAGED_TEST_TOKEN="install-managed-token"
    export MANAGED_TEST_PORT MANAGED_TEST_TOKEN
    repack_core_for_test "${managed_dist_one}" managed-config
    repack_core_for_test "${managed_dist_two}" unit-v2
    repack_core_for_test "${failing_dist_three}" fail-restart
    failing_core_listing="$(tar -tzf "${failing_dist_three}/linux-agent-core.tar.gz")"
    grep -qx 'FAIL_RESTART' <<<"${failing_core_listing}"

    cat >"${fake_systemd_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
printf '%s\n' "${command_name}" >>"${FAKE_SYSTEMD_STATE}/commands"

stop_service() {
    local pid=""
    if [[ -f "${FAKE_SYSTEMD_STATE}/service.pid" ]]; then
        pid="$(<"${FAKE_SYSTEMD_STATE}/service.pid")"
        kill "${pid}" >/dev/null 2>&1 || true
        for _ in $(seq 1 100); do
            kill -0 "${pid}" >/dev/null 2>&1 || break
            sleep 0.02
        done
        rm -f -- "${FAKE_SYSTEMD_STATE}/service.pid"
    fi
}

start_service() {
    [[ ! -f "${FAKE_SYSTEMD_PREFIX}/current/FAIL_RESTART" ]] || return 1
    stop_service
    (
        unset NOTIFY_SOCKET
        exec bash "${FAKE_SYSTEMD_PREFIX}/current/bin/agent-web"
    ) >"${FAKE_SYSTEMD_STATE}/web.stdout" 2>"${FAKE_SYSTEMD_STATE}/web.stderr" </dev/null &
    printf '%s\n' "$!" >"${FAKE_SYSTEMD_STATE}/service.pid"
}

case "${command_name}" in
    daemon-reload) ;;
    is-enabled)
        [[ -f "${FAKE_SYSTEMD_STATE}/enabled" ]]
        ;;
    is-active)
        if [[ -f "${FAKE_SYSTEMD_STATE}/service.pid" ]] &&
            kill -0 "$(<"${FAKE_SYSTEMD_STATE}/service.pid")" >/dev/null 2>&1; then
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
    restart | start) start_service ;;
    stop) stop_service ;;
    *)
        printf 'unsupported fake systemctl command: %s\n' "${command_name}" >&2
        exit 2
        ;;
esac
SH
    chmod 0755 "${fake_systemd_bin}/systemctl"

    run_managed_installer() {
        unshare -Ur env \
            PATH="${fake_systemd_bin}:${PATH}" \
            FAKE_SYSTEMD_PREFIX="${managed_prefix}" \
            FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
            LINUX_AGENT_SYSTEMD_UNIT_PATH="${managed_unit_path}" \
            LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX=1 \
            bash "${ROOT_DIR}/scripts/install.sh" "$@" \
            --prefix "${managed_prefix}" --service-user root
    }

    if ! run_managed_installer install --version v0.0.0-test --from-dist "${managed_dist_one}"; then
        printf 'managed install failed; fake systemd commands:\n' >&2
        sed -n '1,160p' "${fake_systemd_dir}/commands" >&2 2>/dev/null || true
        printf 'managed Web stderr:\n' >&2
        sed -n '1,200p' "${fake_systemd_dir}/web.stderr" >&2 2>/dev/null || true
        exit 1
    fi
    run_managed_installer upgrade --version v0.0.1-test --from-dist "${managed_dist_two}"
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    if run_managed_installer upgrade --version v0.0.2-test --from-dist "${failing_dist_three}" \
        >"${tmp_root}/managed-failure.stdout" 2>"${tmp_root}/managed-failure.stderr"; then
        printf 'managed upgrade unexpectedly accepted an unhealthy release\n' >&2
        exit 1
    fi
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.1-test" ]]
    [[ ! -e "${managed_prefix}/releases/v0.0.2-test" ]]
    jq -e '.remote.release_version == "v0.0.1-test"' "${managed_prefix}/data/config/config.json" >/dev/null
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    run_managed_installer upgrade --version v0.0.2-test --from-dist "${dist_three}"
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.2-test" ]]
    ! grep -q 'LINUX_AGENT_UNIT_MARKER' "${managed_unit_path}"
    run_managed_installer rollback
    [[ "$(readlink "${managed_prefix}/current")" == "releases/v0.0.1-test" ]]
    grep -q '^Environment=LINUX_AGENT_UNIT_MARKER=v2$' "${managed_unit_path}"
    [[ -z "$(find "${managed_prefix}" -maxdepth 1 -name '.linux-agent-web.service.*' -print -quit)" ]]
    FAKE_SYSTEMD_PREFIX="${managed_prefix}" FAKE_SYSTEMD_STATE="${fake_systemd_dir}" \
        "${fake_systemd_bin}/systemctl" stop linux-agent-web.service
    fake_systemd_pidfile=""
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
installer_health="$(bash "${ROOT_DIR}/scripts/install.sh" health --prefix "${prefix}" --no-systemd)"
jq -e '.ok == true and .status == "ok"' <<<"${installer_health}" >/dev/null
find "${prefix}/data/logs" -maxdepth 1 -type f -name 'web_*.jsonl' -print -quit | grep -q .
wait "${notify_pid}"
notify_pid=""
grep -q '^READY=1' "${notify_output}"

status_json="$(bash "${ROOT_DIR}/scripts/install.sh" status --prefix "${prefix}" --no-systemd)"
jq -e '.ok == true and .current_version == "v0.0.2-test" and .service_status == "not-managed"' \
    <<<"${status_json}" >/dev/null

printf 'install: ok\n'
