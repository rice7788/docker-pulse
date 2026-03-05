# syntax=docker/dockerfile:1.7-labs
ARG BUILD_AGENT=1
ARG PULSE_LICENSE_PUBLIC_KEY

# Build stage for frontend (must be built first for embedding)
# Force amd64 platform to avoid slow QEMU emulation during multi-arch builds
FROM --platform=linux/amd64 node:20-alpine AS frontend-builder

WORKDIR /app/frontend-modern

# Copy package files
COPY frontend-modern/package*.json ./
RUN --mount=type=cache,id=pulse-npm-cache,target=/root/.npm \
    npm ci

# Copy frontend source
COPY frontend-modern/ ./

# Build frontend
RUN --mount=type=cache,id=pulse-npm-cache,target=/root/.npm \
    npm run build

# Build stage for Go backend
# Force amd64 platform - Go cross-compiles for all targets anyway,
# and this avoids slow QEMU emulation during multi-arch builds
FROM --platform=linux/amd64 golang:1.24-alpine AS backend-builder

ARG BUILD_AGENT
ARG PULSE_LICENSE_PUBLIC_KEY
ARG VERSION
WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Copy go mod files for better layer caching
COPY go.mod go.sum ./
RUN --mount=type=cache,id=pulse-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=pulse-go-build,target=/root/.cache/go-build \
    go mod download

# Copy only necessary source code
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY pkg/ ./pkg/
COPY VERSION ./

# Copy built frontend from frontend-builder stage for embedding
# Must be at internal/api/frontend-modern for Go embed
COPY --from=frontend-builder /app/frontend-modern/dist ./internal/api/frontend-modern/dist

# Build the main pulse binary for all target architectures
RUN --mount=type=cache,id=pulse-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=pulse-go-build,target=/root/.cache/go-build \
    VERSION="${VERSION:-v$(cat VERSION | tr -d '\n')}" && \
    BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") && \
    GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown") && \
    LICENSE_LDFLAGS="" && \
    if [ -n "${PULSE_LICENSE_PUBLIC_KEY}" ]; then \
      LICENSE_LDFLAGS="-X github.com/rcourtman/pulse-go-rewrite/internal/license.EmbeddedPublicKey=${PULSE_LICENSE_PUBLIC_KEY}"; \
    fi && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -ldflags="-s -w -X main.Version=${VERSION} -X main.BuildTime=${BUILD_TIME} -X main.GitCommit=${GIT_COMMIT} -X github.com/rcourtman/pulse-go-rewrite/internal/dockeragent.Version=${VERSION} ${LICENSE_LDFLAGS}" \
      -trimpath \
      -o pulse-linux-amd64 ./cmd/pulse

# Runtime image for the Docker agent (offered via --target agent_runtime)
FROM alpine:3.20 AS agent_runtime

# Use TARGETARCH to select the correct binary for the build platform
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

# Copy all unified agent binaries first
COPY --from=backend-builder /app/pulse-agent-linux-* /tmp/

# Select the appropriate architecture binary
# Docker buildx automatically sets TARGETARCH (amd64, arm64, arm) and TARGETVARIANT (v7)
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        cp /tmp/pulse-agent-linux-arm64 /usr/local/bin/pulse-agent; \
    elif [ "$TARGETARCH" = "arm" ]; then \
        cp /tmp/pulse-agent-linux-armv7 /usr/local/bin/pulse-agent; \
    else \
        cp /tmp/pulse-agent-linux-amd64 /usr/local/bin/pulse-agent; \
    fi && \
    chmod +x /usr/local/bin/pulse-agent && \
    rm -rf /tmp/pulse-agent-*

# Create shim for pulse-docker-agent to maintain backward compatibility
RUN echo '#!/bin/sh' > /usr/local/bin/pulse-docker-agent && \
    echo 'exec /usr/local/bin/pulse-agent --enable-docker "$@"' >> /usr/local/bin/pulse-docker-agent && \
    chmod +x /usr/local/bin/pulse-docker-agent

COPY --from=backend-builder /app/VERSION /VERSION

ENV PULSE_NO_AUTO_UPDATE=true

ENTRYPOINT ["/usr/local/bin/pulse-docker-agent"]

# Final stage (Pulse server runtime)
FROM alpine:3.20 AS runtime
ARG TARGETARCH

WORKDIR /app
COPY --from=backend-builder /app/pulse-linux-${TARGETARCH:-amd64} /app/pulse
#COPY --from=backend-builder /app/pulse-linux-amd64 /app/pulse-linux-amd64
COPY --from=backend-builder /app/VERSION .
COPY docker-entrypoint.sh /docker-entrypoint.sh

EXPOSE 7655
ENV PULSE_DATA_DIR=/data
ENV PULSE_DOCKER=true

RUN apk add --no-cache ca-certificates tzdata su-exec openssh-client && \
    adduser -D -u 1000 -g 1000 pulse && \
    mkdir -p /data /etc/pulse /opt/pulse && \
    chown -R pulse:pulse /app /data /etc/pulse /opt/pulse && \
    chmod +x /app/pulse /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh", "/app/pulse"]
