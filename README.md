# corplink-headless

corplink-headless is a headless client for Corplink VPN.

Supported runtimes:

- Docker on Linux hosts
- macOS (Apple Silicon) via Apple Virtualization framework + arm64 Linux guest

## Usage on Docker (Linux host)

1. Run the container as a daemon.

```bash
docker run -d \
  --name=corplink \
  --hostname=ubuntu \
  --device=/dev/net/tun \
  --cap-add=NET_ADMIN \
  --shm-size=512m \
  -p 8888:8118 \
  -p 1088:1080 \
  -e COMPANY_CODE="your_company" \
  ghcr.io/moonsphere/corplink-headless:latest
```

2. Configure corplink.

```bash
# Scan QR code using Feilian App
docker exec -it corplink less -rf +F /var/log/corplink-headless/stdout.log
# Quit less if it prints "login success, company code: xxx"
```

3. Access corplink network via http proxy: localhost:8888 or socks5 proxy: localhost:1088.
  You can also route traffic to the container. The container will do SNAT for all traffic sent to it.

## Usage on macOS (Apple Silicon)

### Prerequisites

1. Install Lima (`limactl`):

```bash
brew install lima
```

2. Start Corplink in one command without cloning this repo:

```bash
limactl start \
  --set '.param.COMPANY_CODE="your_company"' \
  github:moonsphere/corplink-headless/lima/corplink-headless
```

This command will:

- Start an Ubuntu Minimal arm64 VM with Apple Virtualization (`vmType: vz`)
- Download the latest arm64 runtime bundle published from Git tags, or build it from this fork if release assets are unavailable
- Download the official arm64 Corplink package
- Install the same runtime stack as the Docker image inside the guest
- Expose host proxies on `127.0.0.1:8888` and `127.0.0.1:1088`

Notes:

- The `github:` template scheme requires Lima 2.x.
- If GitHub API rate limits affect template resolution, set `GH_TOKEN` or `GITHUB_TOKEN` before running `limactl`.
- The template downloads the latest release by default. For reproducible VM setup, pin a known-good runtime release with `--set '.param.RUNTIME_RELEASE="v0.1.0-moonsphere.3"'`.
- Source-build fallback uses `RUNTIME_REPO=moonsphere/corplink-headless` and `RUNTIME_SOURCE_REF=main` by default. Override them with `--set` if you want to test another fork, branch, tag, or commit.
- If the source-build fallback cannot reach Go's default download or module endpoints, set `GO_DOWNLOAD_BASES` or `GOPROXY` with `--set`.

### Login and daily operations

```bash
# Watch QR code + login progress
LIMA_WORKDIR=/ limactl shell corplink-headless sudo less -rf +F /var/log/corplink-headless/stdout.log

# Runtime status
LIMA_WORKDIR=/ limactl shell corplink-headless sudo systemctl --no-pager status corplink-headless.service

# Open shell inside VM
LIMA_WORKDIR=/ limactl shell corplink-headless

# Stop VM
limactl stop corplink-headless
```

To remove the VM entirely:

```bash
limactl delete --force corplink-headless
```

After startup, proxies are exposed on host:

- HTTP: `127.0.0.1:8888`
- SOCKS5: `127.0.0.1:1088`

See [`docs/macos-runtime.md`](docs/macos-runtime.md) for design and maintenance details.

## Acknowledgments

* corplink-headless is inspired by [sleepymole/docker-corplink](https://github.com/sleepymole/docker-corplink).
  The Dockerfile and relevant scripts are modified from the project.
