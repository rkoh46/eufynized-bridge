# Ubuntu (glibc) rather than the Supervisor's Alpine base: the bridge is a glibc Linux build of Swift.
FROM ubuntu:24.04

# ffmpeg decodes snapshots, remuxes clips and encodes talkback audio; libcurl backs Foundation's networking.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libcurl4t64 ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/*

# go2rtc turns the bridge's transport streams into browser video (MSE / WebRTC / HLS).
ARG GO2RTC_VERSION=1.9.14
RUN curl -fsSL -o /usr/local/bin/go2rtc \
      "https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_linux_arm64" \
 && chmod +x /usr/local/bin/go2rtc

COPY eufynized-bridge /usr/local/bin/eufynized-bridge
COPY www /app/www
COPY run.sh /run.sh
RUN chmod +x /run.sh /usr/local/bin/eufynized-bridge

CMD ["/run.sh"]
