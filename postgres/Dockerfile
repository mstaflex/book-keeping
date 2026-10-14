FROM postgres:16-alpine
COPY 01_schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY 02_worker_user.sh /docker-entrypoint-initdb.d/02_worker_user.sh
COPY 03_migrations.sh /docker-entrypoint-initdb.d/03_migrations.sh
# Migrationen außerhalb von initdb.d: dort würden Unterordner ignoriert
COPY migrations/ /opt/migrations/
RUN chmod +x /docker-entrypoint-initdb.d/02_worker_user.sh /docker-entrypoint-initdb.d/03_migrations.sh
