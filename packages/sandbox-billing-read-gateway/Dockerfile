ARG GOLANG_VERSION=1.26.5
ARG ALPINE_VERSION=3.24

FROM golang:${GOLANG_VERSION}-alpine${ALPINE_VERSION} AS builder
WORKDIR /build/sandbox-billing-read-gateway
COPY ./sandbox-billing-read-gateway/go.mod ./sandbox-billing-read-gateway/go.sum ./
RUN go mod download
COPY ./sandbox-billing-read-gateway/ ./
RUN CGO_ENABLED=0 go build -o /out/sandbox-billing-read-gateway .

FROM alpine:${ALPINE_VERSION}
RUN addgroup -S gateway && adduser -S -G gateway gateway
COPY --from=builder /out/sandbox-billing-read-gateway /usr/local/bin/sandbox-billing-read-gateway
USER gateway
ENTRYPOINT ["/usr/local/bin/sandbox-billing-read-gateway"]
