# macOS Runtime Design (Apple Silicon)

This project supports macOS by publishing a Lima template that provisions an arm64 Ubuntu Minimal VM through Apple's Virtualization framework.

Primary entrypoint:

```bash
limactl start \
  --set '.param.COMPANY_CODE="your_company"' \
  github:moonsphere/corplink-headless/lima/corplink-headless
```

For guest shell commands, use `LIMA_WORKDIR=/` so Lima does not try to `cd` into an unmapped host path.

## Why this design

- Users no longer need to clone the repository or run a repo-local VM wrapper script.
- Lima owns instance lifecycle directly, which keeps the user-facing flow to a single `limactl start`.
- Tagged releases publish a stable arm64 runtime tarball, so the guest can bootstrap from release artifacts instead of host mounts. If release assets are missing, the guest builds the runtime from this fork's source ref.
- The guest stack still mirrors the Docker runtime: Feilian service, `corplink-headless`, `socks5`, `privoxy`, supervisor-managed helpers, and the same NAT behavior.

## Release flow

On every pushed Git tag, or when the release workflow is run manually with a tag name, GitHub Actions now:

- Builds and pushes a multi-arch GHCR image for `linux/amd64` and `linux/arm64`.
- Builds `corplink-headless` and `socks5` for `linux/amd64` and `linux/arm64`.
- Packages each architecture into a release tarball together with `install_service.sh` and `startup.sh`.
- Publishes the tarballs plus a checksum file as GitHub Release assets.

The Lima template first tries to download:

- `https://github.com/moonsphere/corplink-headless/releases/latest/download/corplink-headless-runtime-linux-arm64.tar.gz`
- `https://github.com/moonsphere/corplink-headless/releases/latest/download/corplink-headless-runtime-sha256sum.txt`
- `https://cdn.isealsuite.com/linux/FeiLian_Linux_arm64_v2.1.27_r2711_d2baf1.deb`

When the runtime release assets are unavailable, the provisioner downloads `https://github.com/moonsphere/corplink-headless/archive/main.tar.gz`, installs the Go toolchain version from `go.mod`, builds `corplink-headless` and `socks5`, and then installs the same service stack. The Go toolchain download bases default to `https://go.dev/dl https://mirrors.aliyun.com/golang` and can be overridden with the `GO_DOWNLOAD_BASES` Lima param.

## Runtime parity with Docker

Inside the guest, the provision step installs and runs:

- `/opt/Corplink/corplink-service` from the official arm64 `.deb`
- `/opt/Corplink/corplink-headless` from the release tarball or source build
- `/usr/local/bin/socks5` from the release tarball or source build
- `privoxy` on guest `8118`, forwarded to host `8888`
- `socks5` on guest `1080`, forwarded to host `1088`
- `systemd` for the top-level `/startup.sh` lifecycle
- `supervisord` for `corplink-service`, `corplink-headless`, `privoxy`, `socks5`, `fixdns`, and `fixsshmtu`

`privoxy.service` and `supervisor.service` are masked in the guest so only `startup.sh` and supervisor own those processes.

## Key files

- `lima/corplink-headless.yaml`
  - Public Lima template consumed via the `github:` source.
- `lima/provision-system.sh`
  - Guest provisioning script that downloads the latest runtime bundle or builds it from source, downloads the official Feilian package, then calls `install_service.sh`.
- `scripts/install_service.sh`
  - Shared installer used by both Docker builds and the Lima/macOS guest runtime.
- `scripts/package_runtime.sh`
  - Builds and packages release tarballs for `linux/amd64` and `linux/arm64`.
- `.github/workflows/release.yml`
  - Tag/manual workflow for GHCR images, runtime bundles, and GitHub Release assets.
