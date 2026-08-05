FROM golang:1.25-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth=1 --branch add-server-srtp-layer https://github.com/anton48/vk-turn-proxy.git .
RUN go build -o /out/vk-turn-proxy ./server

FROM alpine:3.22
RUN apk add --no-cache ca-certificates iproute2 iptables wireguard-tools
COPY --from=build /out/vk-turn-proxy /usr/local/bin/vk-turn-proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
