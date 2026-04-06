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

# Pre-cache Typst Universe packages (invoice-pro + transitive deps).
# Compilation may fail, but packages are downloaded during the import phase.
RUN printf '#import "@preview/invoice-pro:0.1.1": invoice, item, invoice-line-items\n#set text(lang: "de")\n#show: invoice.with(sender:(name:"x",address:"x",city:"x"),recipient:(name:"x",address:"x",city:"x"),invoice-nr:"1",date:datetime.today())[]\n#invoice-line-items(item([Test],price:1.0,vat:0.0))' \
      > /tmp/prefetch.typ && \
    typst compile --font-path /usr/share/fonts /tmp/prefetch.typ /tmp/prefetch.pdf || true

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
