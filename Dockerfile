ARG BUILD_AGENT=1
ARG PULSE_LICENSE_PUBLIC_KEY


FROM --platform=linux/amd64 node:20-alpine AS frontend-builder
WORKDIR /app/frontend-modern

COPY frontend-modern/package*.json ./
RUN --mount=type=cache,id=pulse-npm-cache,target=/root/.npm \
    npm ci

COPY frontend-modern/ ./
RUN --mount=type=cache,id=pulse-npm-cache,target=/root/.npm \
    npm run build


FROM --platform=linux/amd64 golang:1.24-alpine AS backend-builder
ARG BUILD_AGENT
ARG PULSE_LICENSE_PUBLIC_KEY
ARG VERSION
WORKDIR /app

RUN apk add --no-cache git
COPY go.mod go.sum ./
RUN --mount=type=cache,id=pulse-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=pulse-go-build,target=/root/.cache/go-build \
    go mod download

COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY pkg/ ./pkg/
COPY VERSION ./
COPY --from=frontend-builder /app/frontend-modern/dist ./internal/api/frontend-modern/dist

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


FROM alpine 3.20 AS prepare
COPY --from=backend-builder /app/pulse-linux-amd64 /rootfs/app/pulse
COPY --from=backend-builder /app/VERSION /rootfs/app/VERSION
COPY docker-entrypoint.sh /rootfs/docker-entrypoint.sh
RUN chmod +x /app/pulse /docker-entrypoint.sh
RUN mkdir -p /rootfs/data /rootfs/etc/pulse /rootfs/opt/pulse


FROM alpine:3.20 AS runtime
ENV PULSE_DATA_DIR=/data
ENV PULSE_DOCKER=true
ENV PULSE_LICENSE_DEV_MODE=true

RUN apk add --no-cache ca-certificates tzdata su-exec && \
    adduser -H -D -u 1000 -g 1000 pulse && \
    chown -R pulse:pulse /app /data /etc/pulse /opt/pulse
COPY --from=prepare /rootfs /

EXPOSE 7655
#WORKDIR /app
USER 1000:1000
ENTRYPOINT ["/docker-entrypoint.sh", "/app/pulse"]
