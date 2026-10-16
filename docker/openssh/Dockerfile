FROM alpine:3.20

RUN apk add --no-cache openssh bash iproute2 \
 && adduser -D -h /home/tester -s /bin/sh tester \
 && echo 'tester:testpass' | chpasswd \
 && mkdir -p /home/tester/upload /etc/ssh/sshd_config.d \
 && chown -R tester:tester /home/tester \
 && chmod 755 /home /home/tester

COPY sshd/sshd_modern.conf /etc/ssh/sshd_config.d/modern.conf
COPY sshd/sshd_legacy.conf /etc/ssh/sshd_config.d/legacy.conf
COPY sshd/sshd_oldalgo.conf /etc/ssh/sshd_config.d/oldalgo.conf
COPY sshd/entrypoint.sh /entrypoint.sh
COPY seed-corpus.sh /seed-corpus.sh
RUN chmod +x /entrypoint.sh /seed-corpus.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
