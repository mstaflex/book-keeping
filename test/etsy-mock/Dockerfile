FROM python:3.12-slim
WORKDIR /app
COPY server.py fixtures.py ./
ENV TZ=Europe/Berlin PYTHONUNBUFFERED=1
EXPOSE 443
CMD ["python", "server.py"]
