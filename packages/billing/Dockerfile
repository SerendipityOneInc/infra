ARG GOLANG_VERSION=1.26.5
ARG ALPINE_VERSION=3.24

FROM golang:${GOLANG_VERSION}-alpine${ALPINE_VERSION} AS builder
WORKDIR /build/billing
COPY ./billing/go.mod ./billing/go.sum ./
RUN go mod download
COPY ./billing/ ./
RUN CGO_ENABLED=0 go build -o /out/billing .

FROM alpine:${ALPINE_VERSION}
RUN addgroup -S gateway && adduser -S -G gateway gateway
COPY --from=builder /out/billing /usr/local/bin/billing
USER gateway
ENTRYPOINT ["/usr/local/bin/billing"]
