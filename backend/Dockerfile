FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o vibra-listen-together .

FROM alpine:3.21
WORKDIR /app
RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/vibra-listen-together .
EXPOSE 8080
ENV PORT=8080
USER nobody
ENTRYPOINT ["./vibra-listen-together"]
