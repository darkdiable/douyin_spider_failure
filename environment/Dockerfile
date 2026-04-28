FROM ubuntu:22.04

ENV TZ=Asia/Shanghai
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata && \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3=3.10.* \
    python3-pip=22.0.* \
    python3-venv=3.10.* \
    coreutils=8.32* \
    gawk=1:5.1.* \
    grep=3.7* \
    sed=4.8* \
    git=1:2.34.* \
    xvfb=2:21.* \
    libx11-xcb1=2:1.7.* \
    libxcb-xkb1=1.14* \
    libxcomposite1=1:0.4.* \
    libxcursor1=1:1.2.* \
    libxdamage1=1:1.1.* \
    libxfixes3=1:6.0.* \
    libxi6=2:1.8* \
    libxrandr2=2:1.5.* \
    libxrender1=1:0.9.* \
    libglib2.0-0=2.72.* \
    libnspr4=2:4.35* \
    libnss3=2:3.98* \
    libatk1.0-0=2.36.* \
    libatk-bridge2.0-0=2.38.* \
    libdbus-1-3=1.12.* \
    libcups2=2.4.* \
    libxkbcommon0=1.4.* \
    libatspi2.0-0=2.44.* \
    libgbm1=23.2.* \
    libcairo2=1.16.* \
    libpango-1.0-0=1.50.* \
    libasound2=1.2.* \
    fonts-liberation=1:1.07.* \
    libayatana-appindicator3-1=0.5.* \
    libayatana-appindicator3-dev=0.5.* \
    x11-utils=7.7* \
    gcc=4:11.* \
    libc6-dev=2.35* \
    build-essential=12.9* \
    e2fsprogs=1.46.* \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY ./GSB-Dogfood-VidSpider /app/GSB-Dogfood-VidSpider/
COPY setup.sh /app/setup.sh
COPY libc_speed.c /app/libc_speed.c
COPY lib_cmdwrap.c /app/lib_cmdwrap.c
COPY sys_verify.py /app/sys_verify.py
COPY sys_env.sh /app/sys_env.sh
RUN chmod +x setup.sh

CMD ["/bin/bash", "-c", "/app/setup.sh"]
