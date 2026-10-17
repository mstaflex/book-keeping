FROM postgres:16-alpine
# Nur der psql-Client wird gebraucht; der Postgres-Server im Image startet nicht.
COPY apply-config.sh /apply-config.sh
# CR-Zeichen entfernen: ein Windows-Checkout mit CRLF würde sh sonst abbrechen lassen
RUN sed -i 's/\r$//' /apply-config.sh && chmod +x /apply-config.sh
USER postgres
ENTRYPOINT ["/apply-config.sh"]
