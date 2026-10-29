ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache bash curl jq

COPY run.sh /app/run.sh
RUN chmod a+x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
