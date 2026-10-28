# The hub as one static binary in an otherwise empty image.
#   docker build -t gitrochi-hub services/hub
# deploy/compose.yaml runs it with a data volume and a health check.
ARG GO_IMAGE=golang:1.27.3-alpine

FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
ARG VERSION=dev
# Standard library only: nothing to download.
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOPROXY=off
RUN go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/gitrochi-hub ./cmd/gitrochi-hub \
 && mkdir /out/data

FROM scratch
# CA roots for outgoing TLS, such as a health probe of a TLS listener.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/gitrochi-hub /gitrochi-hub
# An empty named volume mounted on /data takes this owner.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
ENV GITROCHI_HUB_DATA=/data
VOLUME ["/data"]
EXPOSE 7420
# The exec form needs no shell, so it works in a scratch image; runtimes
# that ignore image health checks get the same probe from compose.yaml.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/gitrochi-hub", "health", "--url", "http://127.0.0.1:7420/healthz"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/gitrochi-hub"]
CMD ["serve", "--listen", ":7420", "--log-format", "json"]
