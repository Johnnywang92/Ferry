# 2205：真老服务器。ADR-0000 §9 N2 定的"两者都做"里的第二台 ——
# 配置版仿真（2203/2204）能限制算法，但限制不出老服务器**行为**上的差异
# （SFTP 版本、老字段、老 OpenSSH 的握手细节）。这台提供真实的 2014 年基线。
#
# Debian 8 (jessie) / OpenSSH 6.7p1：还带 ssh-dss、dh-group1-sha1、hmac-md5、3des-cbc，
# 也还没有 curve25519 之外的现代默认集。这些都是它自己的默认值，我们不挑。
#
# 注意：官方镜像只有 386/arm/amd64，没有 arm64 → 在 M 系列机器上走转译，
# 延迟类数据（sftp_init、RTT）不能拿这台和原生 arm64 的那几台对比。
FROM debian:jessie

# jessie 已 EOL，主仓库与 security 仓库都已下线，只能指 archive.debian.org。
# 老 apt 会因 Release 过期直接拒绝更新，所以 Check-Valid-Until 必须在命令行关掉；
# archive 的索引没有翻译文件，Acquire::Languages=none 省掉一批必然失败的下载。
RUN printf 'deb [trusted=yes] http://archive.debian.org/debian jessie main\n' > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/* \
 && mkdir -p /run/sshd \
 && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Languages=none update \
 && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Languages=none \
        -y --force-yes --no-install-recommends install openssh-server \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash tester \
 && echo 'tester:testpass' | chpasswd \
 && mkdir -p /home/tester/upload \
 && chown -R tester:tester /home/tester /home/tester/upload \
 && chmod 755 /home /home/tester

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 主机密钥显式生成，四种老类型全给 —— ssh-dss 这一条正是"真老设备"能给、
# 配置版仿真给不出的东西，AlgorithmMatrix 要拿它量客户端的反应。
RUN rm -f /etc/ssh/ssh_host_*_key* \
 && ssh-keygen -q -t rsa     -b 2048 -f /etc/ssh/ssh_host_rsa_key     -N '' \
 && ssh-keygen -q -t dsa               -f /etc/ssh/ssh_host_dsa_key    -N '' \
 && ssh-keygen -q -t ecdsa             -f /etc/ssh/ssh_host_ecdsa_key  -N '' \
 && ssh-keygen -q -t ed25519           -f /etc/ssh/ssh_host_ed25519_key -N ''

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
