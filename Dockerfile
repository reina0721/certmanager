# syntax=docker/dockerfile:1.7
# 预构建产物专用 Dockerfile（无需 Node.js 与 Go 工具链，秒级组装运行时镜像）
FROM alpine:3.23 AS runtime

RUN apk add --no-cache ca-certificates openssl tzdata curl socat \
    && addgroup -S -g 10001 certmate \
    && adduser -S -D -H -u 10001 -G certmate certmate \
    && mkdir -p /app /data/acme /data/challenges /data/logs /data/temp /data/backups /certs \
    && chown -R certmate:certmate /app /data /certs

COPY --chown=certmate:certmate bin/certmate /app/certmate
COPY --chown=certmate:certmate opt/acme.sh /opt/acme.sh
COPY --chown=certmate:certmate LICENSE THIRD_PARTY_NOTICES.md /licenses/

ENV PATH="/opt/acme.sh:${PATH}"
USER certmate:certmate
EXPOSE 8080
VOLUME ["/data", "/certs"]
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["/app/certmate", "healthcheck"]
ENTRYPOINT ["/app/certmate"]
