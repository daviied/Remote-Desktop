FROM ghcr.io/juanfont/headscale:0.26.1
COPY config.yaml /etc/headscale/config.yaml
COPY policy.hujson /etc/headscale/policy.hujson
EXPOSE 8080/tcp 3478/udp
CMD ["serve"]
