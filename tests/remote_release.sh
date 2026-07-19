#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/cosign_compat.sh
source "${ROOT_DIR}/tests/cosign_compat.sh"
tmp_root="$(mktemp -d)"

cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

first="${tmp_root}/first"
second="${tmp_root}/second"

SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${first}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${second}"

required_assets=(
    linux-agent-cli.sh
    linux-agent-web.sh
    linux-agent-core.tar.gz
    linux-agent-web.tar.gz
    linux-agent-install.sh
    release-manifest.json
    sbom.spdx.json
    SHA256SUMS
)
for asset in "${required_assets[@]}"; do
    [[ -f "${first}/${asset}" ]]
    cmp "${first}/${asset}" "${second}/${asset}"
done

(cd "${first}" && sha256sum -c SHA256SUMS)
! grep -q 'release-manifest.json' "${first}/SHA256SUMS"

jq -e '
    .schema_version == 1
    and .version == "v0.0.0-test"
    and .repository == "libeal/ASSIstant"
    and (.assets.bootstrap_cli.name == "linux-agent-cli.sh")
    and (.assets.bootstrap_web.name == "linux-agent-web.sh")
    and (.assets.core.name == "linux-agent-core.tar.gz")
    and (.assets.web.name == "linux-agent-web.tar.gz")
    and (.assets.installer.name == "linux-agent-install.sh")
    and (.assets.sbom.name == "sbom.spdx.json")
    and (.assets.checksums.name == "SHA256SUMS")
    and ([.skills | keys[]] | length > 0)
    and ([.skills[] | select((.refs | length) == 0)] | length == 0)
    and ([.skills[] | select((.description | length) == 0 or (.risk | IN("low", "medium", "high", "critical") | not))] | length == 0)
' "${first}/release-manifest.json" >/dev/null

registered_assets="$(jq -r '[.assets[].name, .skills[].asset.name] | sort | .[]' "${first}/release-manifest.json")"
actual_assets="$(find "${first}" -maxdepth 1 -type f ! -name release-manifest.json -printf '%f\n' | LC_ALL=C sort)"
if [[ "${registered_assets}" != "${actual_assets}" ]]; then
    printf 'release contains unregistered or missing assets\n' >&2
    diff -u <(printf '%s\n' "${registered_assets}") <(printf '%s\n' "${actual_assets}") || true
    exit 1
fi

while IFS=$'\t' read -r asset_name expected_sha expected_size; do
    [[ -f "${first}/${asset_name}" ]]
    [[ "$(sha256sum "${first}/${asset_name}" | awk '{print $1}')" == "${expected_sha}" ]]
    [[ "$(stat -c '%s' "${first}/${asset_name}")" -eq "${expected_size}" ]]
done < <(jq -r '[.assets[], .skills[].asset] | .[] | [.name, .sha256, .size_bytes] | @tsv' \
    "${first}/release-manifest.json")

tampered_sbom="${tmp_root}/tampered-sbom.spdx.json"
cp "${first}/sbom.spdx.json" "${tampered_sbom}"
printf ' ' >>"${tampered_sbom}"
[[ "$(sha256sum "${tampered_sbom}" | awk '{print $1}')" != "$(jq -r '.assets.sbom.sha256' "${first}/release-manifest.json")" ]]

jq -e '
    . as $document
    | .spdxVersion == "SPDX-2.3"
    and .SPDXID == "SPDXRef-DOCUMENT"
    and .creationInfo.created == "1970-01-01T00:00:00Z"
    and ([.packages[].name] | sort == ["bash", "curl", "jq", "linux-agent", "python3"])
    and ([.files[].checksums[] | select(.algorithm == "SHA256")] | length == ($document.files | length))
' "${first}/sbom.spdx.json" >/dev/null
sbom_files="$(jq -r '.files[].fileName' "${first}/sbom.spdx.json" | sort)"
sbom_expected="$(find "${first}" -maxdepth 1 -type f \
    ! -name release-manifest.json ! -name SHA256SUMS ! -name sbom.spdx.json -printf '%f\n' | sort)"
[[ "${sbom_files}" == "${sbom_expected}" ]]

core_listing="$(tar -tzf "${first}/linux-agent-core.tar.gz")"
if grep -Eq '^skills/[^/]+/' <<<"${core_listing}"; then
    printf 'core archive unexpectedly contains materialized skill packages\n' >&2
    exit 1
fi
grep -qx 'skills/INDEX.md' <<<"${core_listing}"
grep -qx 'packaging/linux-agent-observer-helper.service' <<<"${core_listing}"
grep -qx 'packaging/linux-agent-observer-helper.socket' <<<"${core_listing}"
grep -qx 'packaging/dropins/10-provider-egress.conf.example' <<<"${core_listing}"
grep -qx 'lib/observer_helper.py' <<<"${core_listing}"

web_listing="$(tar -tzf "${first}/linux-agent-web.tar.gz")"
grep -qx 'web/package.json' <<<"${web_listing}"
tar -xOzf "${first}/linux-agent-web.tar.gz" web/package.json |
    jq -e '.private == true and .type == "module"' >/dev/null

while IFS= read -r skill_name; do
    asset="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.name' "${first}/release-manifest.json")"
    [[ -f "${first}/${asset}" ]]
    skill_listing="$(tar -tzf "${first}/${asset}")"
    grep -qx "skills/${skill_name}/SKILL.md" <<<"${skill_listing}"
    grep -q "^skills/${skill_name}/scripts/" <<<"${skill_listing}"
    skill_extract="${tmp_root}/extract-${skill_name}"
    mkdir -p "${skill_extract}"
    tar -xzf "${first}/${asset}" -C "${skill_extract}"
    manifest_refs="$(jq -r --arg skill "${skill_name}" '.skills[$skill].refs[].ref' "${first}/release-manifest.json" | sort)"
    package_refs="$(find "${skill_extract}/skills/${skill_name}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' |
        sed 's/\.sh$//' | awk -v prefix="${skill_name}/" '{print prefix $0}' | sort)"
    [[ "${manifest_refs}" == "${package_refs}" ]]
done < <(jq -r '.skills | keys[]' "${first}/release-manifest.json")

grep -q 'LINUX_AGENT_REMOTE_ENTRYPOINT=cli' "${first}/linux-agent-cli.sh"
grep -q 'LINUX_AGENT_REMOTE_ENTRYPOINT=web' "${first}/linux-agent-web.sh"

bash -n "${ROOT_DIR}/scripts/publish-remote-release.sh"
grep -q 'workflow_dispatch' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'publish-remote-release.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'build-install-packages.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'RUNNER_TEMP}/publish-remote-release.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
! grep -q 'Authorization Bearer token:' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'agent/tmp/web/auth-token' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'id-token: write' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'prepare-release-signature.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'cosign sign-blob' "${ROOT_DIR}/scripts/prepare-release-signature.sh"
grep -q 'refs/tags/${RELEASE_TAG}' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'github.event.repository.default_branch' "${ROOT_DIR}/.github/workflows/remote-release.yml"
! grep -q 'ref: \${{ github.ref }}' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'attest-build-provenance@' "${ROOT_DIR}/.github/workflows/remote-release.yml"
python3 - "${ROOT_DIR}/.github/workflows/remote-release.yml" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
quality = workflow.index("  quality:\n")
release = workflow.index("  build-and-release:\n")
assert quality < release
quality_job = workflow[quality:release]
quality_install = quality_job[quality_job.index("      - name: Install quality tooling\n"):quality_job.index("      - name: Install cosign for compatibility regressions\n")]
coverage_step_index = quality_job.index("      - name: Report optional Python coverage\n")
required_regression = quality_job[quality_job.index("      - name: Run regression suite\n"):coverage_step_index]
coverage_step = quality_job[coverage_step_index:]
assert "coverage" not in quality_install
assert "python3 -m coverage" not in required_regression
assert coverage_step.index("        continue-on-error: true\n") < coverage_step.index("python3 -m coverage run")
assert "-p 'test_web_*.py'" in coverage_step
privileged_job = workflow[release:]
assert "    needs: quality\n" in privileged_job
assert "apt-get" not in privileged_job
assert "pip install" not in privileged_job
assert "contents: write" in privileged_job
assert "id-token: write" in privileged_job
assert privileged_job.index("Require the selected tag ref") < privileged_job.index("Prepare release manifest signature")
PY
if GITHUB_ACTIONS=true GITHUB_REF=refs/heads/main \
    bash "${ROOT_DIR}/scripts/prepare-release-signature.sh" v0.0.0-test "${first}" \
    >"${tmp_root}/wrong-ref.stdout" 2>"${tmp_root}/wrong-ref.stderr"; then
    printf 'release signer unexpectedly accepted a branch OIDC identity\n' >&2
    exit 1
fi
grep -q 'must run from refs/tags/v0.0.0-test' "${tmp_root}/wrong-ref.stderr"
grep -q 'assets.installer.sha256' "${ROOT_DIR}/README.md"
grep -q '^name: ci$' "${ROOT_DIR}/.github/workflows/ci.yml"
grep -q 'pull_request:' "${ROOT_DIR}/.github/workflows/ci.yml"
grep -q 'branches: \[main, master\]' "${ROOT_DIR}/.github/workflows/ci.yml"
grep -q 'curl -fsSL.*max-time.*max-filesize' "${ROOT_DIR}/remote/bootstrap.sh"
grep -q 'curl -fsSL.*proto.*max-time.*max-filesize' "${ROOT_DIR}/scripts/install.sh"
if grep -E '^[[:space:]]*uses:[[:space:]]+[^@[:space:]]+@' "${ROOT_DIR}/.github/workflows/remote-release.yml" |
    grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' >/dev/null; then
    printf 'workflow contains an action that is not pinned to a 40-character commit SHA\n' >&2
    exit 1
fi
if grep -E '^[[:space:]]*uses:[[:space:]]+[^@[:space:]]+@' "${ROOT_DIR}/.github/workflows/ci.yml" |
    grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' >/dev/null; then
    printf 'CI workflow contains an action that is not pinned to a 40-character commit SHA\n' >&2
    exit 1
fi

if command -v cosign >/dev/null 2>&1; then
    cosign_dir="${tmp_root}/cosign"
    mkdir -p "${cosign_dir}"
    (
        cd "${cosign_dir}"
        COSIGN_PASSWORD=remote-release-test cosign generate-key-pair >/dev/null
        COSIGN_PASSWORD=remote-release-test linux_agent_test_cosign_sign_blob \
            cosign.key manifest.sigstore.json "${first}/release-manifest.json" >/dev/null
        linux_agent_test_cosign_verify_blob \
            cosign.pub manifest.sigstore.json "${first}/release-manifest.json" >/dev/null
    )
else
    printf 'remote_release: cosign not installed; signature roundtrip skipped\n'
fi

fake_bin="${tmp_root}/fake-release-bin"
fake_release="${tmp_root}/published-release"
reuse_dist="${tmp_root}/reuse-dist"
new_dist="${tmp_root}/new-signature-dist"
signature_log="${tmp_root}/signature.log"
mkdir -p "${fake_bin}" "${fake_release}" "${reuse_dist}" "${new_dist}"
cp "${first}/release-manifest.json" "${fake_release}/release-manifest.json"
cp "${first}/release-manifest.json" "${reuse_dist}/release-manifest.json"
cp "${first}/release-manifest.json" "${new_dist}/release-manifest.json"
printf 'published-stable-bundle\n' >"${fake_release}/release-manifest.json.sigstore.json"

cat >"${fake_bin}/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "release" ]] || exit 2
case "${2:-}" in
    view)
        [[ "${FAKE_RELEASE_EXISTS:-0}" == "1" ]] || exit 1
        if [[ " $* " == *" --json assets "* ]]; then
            printf '%s\n' release-manifest.json release-manifest.json.sigstore.json
        fi
        ;;
    download)
        pattern=""
        destination=""
        shift 2
        [[ $# -gt 0 ]] && shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pattern)
                    pattern="$2"
                    shift 2
                    ;;
                --dir)
                    destination="$2"
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        cp -- "${FAKE_RELEASE_DIR}/${pattern}" "${destination}/${pattern}"
        ;;
    *) exit 2 ;;
esac
SH
cat >"${fake_bin}/cosign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    verify-blob)
        printf 'verify\n' >>"${FAKE_SIGNATURE_LOG}"
        ;;
    sign-blob)
        printf 'sign\n' >>"${FAKE_SIGNATURE_LOG}"
        bundle=""
        shift
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--bundle" ]]; then
                bundle="$2"
                shift 2
            else
                shift
            fi
        done
        [[ -n "${bundle}" ]]
        printf 'new-bundle\n' >"${bundle}"
        ;;
    *) exit 2 ;;
esac
SH
chmod 0755 "${fake_bin}/gh" "${fake_bin}/cosign"

# The fake release scenarios are local fixtures; do not inherit the workflow's
# real tag guard while exercising signature reuse and creation.
FAKE_RELEASE_EXISTS=1 \
    FAKE_RELEASE_DIR="${fake_release}" \
    FAKE_SIGNATURE_LOG="${signature_log}" \
    GITHUB_ACTIONS=false \
    PATH="${fake_bin}:${PATH}" \
    bash "${ROOT_DIR}/scripts/prepare-release-signature.sh" v0.0.0-test "${reuse_dist}"
cmp "${fake_release}/release-manifest.json.sigstore.json" \
    "${reuse_dist}/release-manifest.json.sigstore.json"
grep -qx 'verify' "${signature_log}"
! grep -q 'sign' "${signature_log}"

: >"${signature_log}"
FAKE_RELEASE_EXISTS=0 \
    FAKE_RELEASE_DIR="${fake_release}" \
    FAKE_SIGNATURE_LOG="${signature_log}" \
    GITHUB_ACTIONS=false \
    PATH="${fake_bin}:${PATH}" \
    bash "${ROOT_DIR}/scripts/prepare-release-signature.sh" v0.0.0-test "${new_dist}"
grep -qx 'new-bundle' "${new_dist}/release-manifest.json.sigstore.json"
grep -qx 'sign' "${signature_log}"

printf 'remote_release: ok\n'
