#!/bin/sh
# Richtet die lokale Test-n8n-Instanz ein (läuft im n8n-Image, Service n8n-setup):
#   1. Login anlegen (beim ersten Start)
#   2. Credentials importieren (feste IDs = Platzhalter in den Workflow-JSONs)
#   3. Workflows aus n8n/workflows/ importieren, vorhandene mit gleicher Nummer
#      ("01 · …", egal welche Version) ersetzen
# Erneut ausführen nach Änderungen an den Workflows:
#   docker compose -f test/docker-compose.yml run --rm n8n-setup
set -eu
node /setup/setup.mjs owner
n8n import:credentials --input=/setup/credentials.json
node /setup/setup.mjs workflows
