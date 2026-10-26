# nc-style challenge exposed as a browser terminal via ttyd (WebSocket over the
# same /i/<token> path, so it works behind a Cloudflare tunnel with no raw TCP).
FROM debian:stable-slim
# ttyd is not in Debian repos; use the official static (musl) release binary.
# Build with --build-arg TTYD_ARCH=aarch64 on ARM hosts (setup.sh does this).
ARG TTYD_ARCH=x86_64
ADD https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH} /usr/local/bin/ttyd
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/* \
 && chmod +x /usr/local/bin/ttyd \
 && useradd -m -s /usr/sbin/nologin player
COPY vuln.py /challenge/vuln.py
RUN chmod 0644 /challenge/vuln.py
USER player
ENV INSTANCE_BASE=/
# ttyd serves the terminal under the reverse-proxy base path (-b) so asset and
# websocket URLs line up with /i/<token>. -W allows keyboard input; each
# connection runs the fixed challenge program (no shell is exposed).
CMD ["sh", "-c", "exec ttyd -W -p 8080 -b \"$INSTANCE_BASE\" -t disableLeaveAlert=true python3 /challenge/vuln.py"]
