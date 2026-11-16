FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.buildVersion=${VERSION}" -o /out/app .

FROM alpine:3.21
RUN adduser -D -u 10001 app
COPY --from=build /out/app /usr/local/bin/app
USER app
EXPOSE 8080
# Exec form: the app is PID 1 and receives SIGTERM directly. A shell-form
# ENTRYPOINT would put `sh` in between, and the signal would never arrive.
ENTRYPOINT ["app"]
CMD ["http"]
