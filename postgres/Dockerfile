FROM postgres:16-alpine
COPY 01_schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY 02_worker_user.sh /docker-entrypoint-initdb.d/02_worker_user.sh
RUN chmod +x /docker-entrypoint-initdb.d/02_worker_user.sh
