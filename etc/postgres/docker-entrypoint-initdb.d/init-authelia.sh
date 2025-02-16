#!/bin/bash
set -e
PASSWORD=$(</run/secrets/authelia-postgres-pass)

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER authelia WITH PASSWORD '$PASSWORD';
    CREATE DATABASE authelia WITH OWNER = authelia;
EOSQL