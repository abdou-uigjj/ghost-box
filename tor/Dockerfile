# ghost-box tor onion service
# alpine + tor from the alpine package repo; trivy gates the version in CI
FROM alpine:3.22

# deterministic uid/gid so the k8s securityContext matches exactly
RUN apk upgrade --no-cache \
    && apk add --no-cache tor curl \
    && addgroup -g 10002 gbtor \
    && adduser -S -G gbtor -u 10002 -h /var/lib/tor gbtor \
    && mkdir -p /var/lib/tor/hs /etc/tor \
    && chown -R gbtor:gbtor /var/lib/tor

COPY --chown=10002:10002 torrc /etc/tor/torrc
RUN chmod 0444 /etc/tor/torrc

USER 10002:10002
EXPOSE 8080

CMD ["tor", "-f", "/etc/tor/torrc"]
