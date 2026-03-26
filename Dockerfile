FROM alpine:3.21

RUN apk add --no-cache \
    curl \
    jq

COPY docker-to-corefile.sh /docker-to-corefile.sh
RUN chmod +x /docker-to-corefile.sh

ENTRYPOINT ["/docker-to-corefile.sh"]
