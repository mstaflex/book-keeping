FROM python:3.12-slim

# System-Deps + Fonts (Liberation = Arial-kompatibel, saubere Sans-Serif)
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils \
        fonts-liberation \
        fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*

# Typst Binary (pinned)
ARG TYPST_VERSION=0.13.1
RUN curl -fsSL \
    "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-x86_64-unknown-linux-musl.tar.xz" \
    | tar -xJ --strip-components=1 -C /usr/local/bin/ \
      "typst-x86_64-unknown-linux-musl/typst" \
    && typst --version

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
