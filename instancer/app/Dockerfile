FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY instancer.py .
# Run as an unprivileged user. The instancer never touches the host socket
# directly; it only speaks TCP to the restricted docker-socket-proxy.
USER 65534:65534
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "-w", "1", "--threads", "8", "--timeout", "120", "instancer:app"]
