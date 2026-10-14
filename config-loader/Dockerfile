FROM postgres:16-alpine
# Nur der psql-Client wird gebraucht; der Postgres-Server im Image startet nicht.
COPY apply-config.sh /apply-config.sh
RUN chmod +x /apply-config.sh
USER postgres
ENTRYPOINT ["/apply-config.sh"]
