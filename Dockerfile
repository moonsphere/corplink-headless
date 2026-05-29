# syntax=docker/dockerfile:1

# Stage 1: Build linux/$TARGETARCH artifacts on the build platform.
FROM --platform=$BUILDPLATFORM golang:1.24 AS builder

ARG TARGETARCH
ARG CORPLINK_DEB_AMD64_URL="https://oss-s3.ifeilian.com/linux/FeiLian_Linux_v2.0.9_r615_97b98b.deb"
ARG CORPLINK_DEB_ARM64_URL="https://cdn.isealsuite.com/linux/FeiLian_Linux_arm64_v2.1.27_r2711_d2baf1.deb"

# Extract architecture-specific corplink-service from the official package.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) deb_url="${CORPLINK_DEB_AMD64_URL}" ;; \
      arm64) deb_url="${CORPLINK_DEB_ARM64_URL}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q -O corplink.deb "${deb_url}"; \
    dpkg-deb -x ./corplink.deb /

WORKDIR /app

COPY go.mod go.sum ./
ENV GOPROXY=https://goproxy.cn
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -o /out/corplink-headless .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -o /out/socks5 ./cmd/socks5

# Stage 2: Final image
FROM ubuntu:20.04

ENV CONTAINER=1

RUN mkdir -p /opt/Corplink

# Install socks5
COPY --from=builder /out/socks5 /usr/local/bin/socks5
# Install corplink-headless
COPY --from=builder /out/corplink-headless /opt/Corplink/
# Install corplink-service
COPY --from=builder /opt/Corplink/corplink-service /opt/Corplink/
# Install services
COPY ./scripts/install_service.sh /opt/Corplink
RUN bash /opt/Corplink/install_service.sh  && rm /opt/Corplink/install_service.sh
COPY ./scripts/startup.sh /

WORKDIR /opt/Corplink
USER root

ENV COMPANY_CODE=""

ENTRYPOINT ["/startup.sh"]
