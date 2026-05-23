FROM ghcr.io/hassio-addons/base:14.0.2

RUN apk add --no-cache bash mosquitto-clients gammu jq

COPY run.sh /run.sh
COPY lib.sh /lib.sh

RUN chmod +x /run.sh

CMD ["/run.sh"]

