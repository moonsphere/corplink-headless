DOCKER_IMAGE ?= ghcr.io/moonsphere/corplink-headless:latest

build:
	docker buildx build --platform linux/amd64,linux/arm64 -t "$(DOCKER_IMAGE)" .

LIMA_TEMPLATE := github:moonsphere/corplink-headless/lima/corplink-headless
LIMA_INSTANCE ?= corplink-headless

macos-up:
	@[ -n "$(COMPANY_CODE)" ] || (echo "COMPANY_CODE is required" >&2; exit 1)
	limactl start --name="$(LIMA_INSTANCE)" --set '.param.COMPANY_CODE="$(COMPANY_CODE)"' $(LIMA_TEMPLATE)

macos-logs:
	LIMA_WORKDIR=/ limactl shell "$(LIMA_INSTANCE)" sudo less -rf +F /var/log/corplink-headless/stdout.log

macos-status:
	LIMA_WORKDIR=/ limactl shell "$(LIMA_INSTANCE)" sudo systemctl --no-pager status corplink-headless.service

macos-down:
	limactl stop "$(LIMA_INSTANCE)"

macos-shell:
	LIMA_WORKDIR=/ limactl shell "$(LIMA_INSTANCE)"

macos-destroy:
	limactl delete --force "$(LIMA_INSTANCE)"
