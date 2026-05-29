#!/usr/bin/env bash

set -euo pipefail

readonly RELEASE_DIR="/opt/corplink-release"
readonly RUNTIME_ASSET="corplink-headless-runtime-linux-arm64.tar.gz"
readonly RUNTIME_REPO="${PARAM_RUNTIME_REPO:-moonsphere/corplink-headless}"
readonly RUNTIME_RELEASE="${PARAM_RUNTIME_RELEASE:-latest}"
readonly RUNTIME_SOURCE_REF="${PARAM_RUNTIME_SOURCE_REF:-main}"
readonly GO_DOWNLOAD_BASES="${PARAM_GO_DOWNLOAD_BASES:-https://go.dev/dl https://mirrors.aliyun.com/golang}"
readonly GOPROXY_VALUE="${PARAM_GOPROXY:-}"
readonly CORPLINK_DEB_URL="https://cdn.isealsuite.com/linux/FeiLian_Linux_arm64_v2.1.27_r2711_d2baf1.deb"
readonly CORPLINK_DEB_PATH="${RELEASE_DIR}/$(basename "${CORPLINK_DEB_URL}")"
readonly RUNTIME_TAR_PATH="${RELEASE_DIR}/${RUNTIME_ASSET}"
readonly CHECKSUMS_PATH="${RELEASE_DIR}/corplink-headless-runtime-sha256sum.txt"

if [ "${RUNTIME_RELEASE}" = "latest" ]; then
    readonly RUNTIME_DOWNLOAD_BASE="https://github.com/${RUNTIME_REPO}/releases/latest/download"
else
    readonly RUNTIME_DOWNLOAD_BASE="https://github.com/${RUNTIME_REPO}/releases/download/${RUNTIME_RELEASE}"
fi
readonly RUNTIME_URL="${RUNTIME_DOWNLOAD_BASE}/${RUNTIME_ASSET}"
readonly CHECKSUMS_URL="${RUNTIME_DOWNLOAD_BASE}/corplink-headless-runtime-sha256sum.txt"

download() {
    local url="$1"
    local output="$2"
    curl -fsSL --retry 3 --retry-delay 2 -o "${output}" "${url}"
}

install_bootstrap_dependencies() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    apt-get update
    apt-get install -y --no-install-recommends curl ca-certificates
    rm -rf /var/lib/apt/lists/*
}

fetch_release_runtime() {
    local expected_checksum local_checksum

    echo "Downloading runtime bundle from ${RUNTIME_REPO} release ${RUNTIME_RELEASE}"
    if ! download "${CHECKSUMS_URL}" "${CHECKSUMS_PATH}"; then
        echo "Runtime checksum asset is unavailable; falling back to source build" >&2
        return 1
    fi

    expected_checksum="$(awk -v asset="${RUNTIME_ASSET}" '{ entry = $2; sub(/^.*\//, "", entry); if (entry == asset) { print $1; exit } }' "${CHECKSUMS_PATH}")"
    if [ -z "${expected_checksum}" ]; then
        echo "Checksum file does not contain ${RUNTIME_ASSET}; falling back to source build" >&2
        return 1
    fi

    if [ -f "${RUNTIME_TAR_PATH}" ]; then
        local_checksum="$(sha256sum "${RUNTIME_TAR_PATH}" | awk '{ print $1 }')"
    else
        local_checksum=""
    fi

    if [ "${local_checksum}" != "${expected_checksum}" ]; then
        if ! download "${RUNTIME_URL}" "${RUNTIME_TAR_PATH}"; then
            echo "Runtime tarball asset is unavailable; falling back to source build" >&2
            return 1
        fi
    fi

    if ! (cd "${RELEASE_DIR}" && printf '%s  %s\n' "${expected_checksum}" "${RUNTIME_ASSET}" | sha256sum -c -); then
        echo "Runtime checksum verification failed" >&2
        exit 1
    fi
    tar -xzf "${RUNTIME_TAR_PATH}" -C "${RELEASE_DIR}"
}

build_runtime_from_source() {
    local safe_ref source_dir source_tar source_url go_version go_root go_tar go_path go_mod_cache go_build_cache

    safe_ref="${RUNTIME_SOURCE_REF//\//-}"
    source_dir="${RELEASE_DIR}/source"
    source_tar="${RELEASE_DIR}/source-${safe_ref}.tar.gz"
    source_url="https://github.com/${RUNTIME_REPO}/archive/${RUNTIME_SOURCE_REF}.tar.gz"

    echo "Building runtime from ${RUNTIME_REPO}@${RUNTIME_SOURCE_REF}"
    rm -rf "${source_dir}"
    mkdir -p "${source_dir}"
    download "${source_url}" "${source_tar}"
    tar -xzf "${source_tar}" -C "${source_dir}" --strip-components=1

    go_version="$(awk '/^go / { print $2; exit }' "${source_dir}/go.mod")"
    [ -n "${go_version}" ] || {
        echo "Failed to determine Go version from ${source_dir}/go.mod" >&2
        exit 1
    }

    go_root="${RELEASE_DIR}/go"
    go_tar="${RELEASE_DIR}/go${go_version}.linux-arm64.tar.gz"
    go_path="${RELEASE_DIR}/gopath"
    go_mod_cache="${go_path}/pkg/mod"
    go_build_cache="${RELEASE_DIR}/go-build-cache"
    rm -rf "${go_root}"
    download_go_toolchain "${go_version}" "${go_tar}"
    tar -xzf "${go_tar}" -C "${RELEASE_DIR}"
    mkdir -p "${go_mod_cache}" "${go_build_cache}"

    (
        cd "${source_dir}"
        export HOME="/root"
        export PATH="${go_root}/bin:${PATH}"
        export GOROOT="${go_root}"
        export GOPATH="${go_path}"
        export GOMODCACHE="${go_mod_cache}"
        export GOCACHE="${go_build_cache}"
        if [ -n "${GOPROXY_VALUE}" ]; then
            export GOPROXY="${GOPROXY_VALUE}"
        fi
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local go build -o "${RELEASE_DIR}/corplink-headless" .
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local go build -o "${RELEASE_DIR}/socks5" ./cmd/socks5
    )

    install -m 0755 "${source_dir}/scripts/install_service.sh" "${RELEASE_DIR}/install_service.sh"
    install -m 0755 "${source_dir}/scripts/startup.sh" "${RELEASE_DIR}/startup.sh"
    printf '%s\n' "${RUNTIME_SOURCE_REF}" >"${RELEASE_DIR}/VERSION"

    rm -rf "${source_dir}" "${go_root}" "${go_tar}" "${source_tar}" "${go_path}" "${go_build_cache}" /root/.cache/go-build /root/go/pkg/mod
}

download_go_toolchain() {
    local go_version="$1"
    local output="$2"
    local filename base

    filename="go${go_version}.linux-arm64.tar.gz"
    for base in ${GO_DOWNLOAD_BASES}; do
        if download "${base%/}/${filename}" "${output}"; then
            return 0
        fi
        echo "Failed to download ${filename} from ${base}" >&2
    done

    echo "Failed to download ${filename} from all configured Go download bases" >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
install_bootstrap_dependencies
mkdir -p "${RELEASE_DIR}"

if ! fetch_release_runtime; then
    build_runtime_from_source
fi

if [ ! -f "${CORPLINK_DEB_PATH}" ]; then
    download "${CORPLINK_DEB_URL}" "${CORPLINK_DEB_PATH}"
fi

CORPLINK_RUNTIME=vm \
COMPANY_CODE="${PARAM_COMPANY_CODE:-}" \
CORPLINK_HEADLESS_BIN="${RELEASE_DIR}/corplink-headless" \
CORPLINK_SOCKS5_BIN="${RELEASE_DIR}/socks5" \
CORPLINK_STARTUP_SCRIPT="${RELEASE_DIR}/startup.sh" \
CORPLINK_PACKAGE_DEB="${CORPLINK_DEB_PATH}" \
bash "${RELEASE_DIR}/install_service.sh"
