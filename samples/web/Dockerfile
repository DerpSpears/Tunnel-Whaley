FROM python:3.12-slim
WORKDIR /app
COPY app.py .
RUN chmod 0644 app.py
# non-root; works fine with read-only rootfs (writes nothing to disk)
USER 65534:65534
EXPOSE 8080
ENV INSTANCE_BASE=/
CMD ["python", "app.py"]
