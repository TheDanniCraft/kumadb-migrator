#!/bin/bash
set -euo pipefail

# Required env vars
: "${MARIADB_USER:?missing}"
: "${MARIADB_PASSWORD:?missing}"

# Optional env vars with defaults
MARIADB_HOST="${MARIADB_HOST:-localhost}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_DATABASE="${MARIADB_DATABASE:-kumadb}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

export MARIADB_HOST MARIADB_PORT MARIADB_DATABASE

# Check source database exists
if [ ! -f /app/kuma.db ]; then
    echo "ERROR: /app/kuma.db not found. Mount the SQLite database at /app/kuma.db."
    exit 1
fi

# Print destination info (no password)
echo "==> Migration destination"
echo "    Host:     ${MARIADB_HOST}"
echo "    Port:     ${MARIADB_PORT}"
echo "    Database: ${MARIADB_DATABASE}"
echo "    User:     ${MARIADB_USER}"

# Determine mode: remote if host is not localhost / 127.0.0.1
IS_REMOTE=false
if [ "${MARIADB_HOST}" != "localhost" ] && [ "${MARIADB_HOST}" != "127.0.0.1" ] && [ "${MARIADB_HOST}" != "::1" ]; then
    IS_REMOTE=true
fi

if [ "${IS_REMOTE}" = "false" ]; then
    # ---- LOCAL MODE ----
    echo "==> Mode: local (starting MariaDB inside container)"

    echo "==> Initializing MariaDB datadir if needed"
    if [ ! -d /var/lib/mysql/mysql ]; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql
    fi

    echo "==> Starting MariaDB"
    /usr/bin/mariadbd-safe --datadir=/var/lib/mysql --socket=/run/mysqld/mysqld.sock &
    MARIADB_PID=$!

    until mariadb-admin ping --socket=/run/mysqld/mysqld.sock --silent; do
        sleep 1
    done

    echo "==> Creating database and user"
    mariadb --socket=/run/mysqld/mysqld.sock <<EOF
CREATE DATABASE IF NOT EXISTS \`${MARIADB_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MARIADB_USER}'@'%' IDENTIFIED BY '${MARIADB_PASSWORD}';
CREATE USER IF NOT EXISTS '${MARIADB_USER}'@'::1' IDENTIFIED BY '${MARIADB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_USER}'@'::1';
FLUSH PRIVILEGES;
EOF

    # Safety check: refuse non-empty destination database unless FORCE=1
    if [ "${FORCE}" != "1" ]; then
        TABLE_COUNT=$(mariadb --socket=/run/mysqld/mysqld.sock \
            -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" -sN \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MARIADB_DATABASE}';")
        if [ "${TABLE_COUNT}" -gt 0 ]; then
            echo "ERROR: Database '${MARIADB_DATABASE}' already contains ${TABLE_COUNT} table(s). Use FORCE=1 to override."
            mariadb-admin shutdown --socket=/run/mysqld/mysqld.sock
            wait "${MARIADB_PID}"
            exit 1
        fi
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        echo "==> DRY_RUN=1: skipping migration"
        mariadb-admin shutdown --socket=/run/mysqld/mysqld.sock
        wait "${MARIADB_PID}"
        exit 0
    fi

    echo "==> Running migration script"
    python3 /app/migrate.py

    echo "==> Shutting down MariaDB"
    mariadb-admin shutdown --socket=/run/mysqld/mysqld.sock
    wait "${MARIADB_PID}"

else
    # ---- REMOTE MODE ----
    echo "==> Mode: remote (connecting to ${MARIADB_HOST}:${MARIADB_PORT})"

    echo "==> Waiting for remote MariaDB/MySQL to be reachable"
    until mariadb -h"${MARIADB_HOST}" -P"${MARIADB_PORT}" \
            -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" \
            -e "SELECT 1" >/dev/null 2>&1; do
        echo "    Not ready, retrying in 2s..."
        sleep 2
    done
    echo "    Remote database is reachable."

    # Try to create the database; ignore failures (may lack CREATE privilege or already exists)
    mariadb -h"${MARIADB_HOST}" -P"${MARIADB_PORT}" \
        -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${MARIADB_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        2>/dev/null \
        || echo "Note: Could not CREATE DATABASE (may already exist or insufficient privileges — this is OK if the database already exists)."

    # Safety check: refuse non-empty destination database unless FORCE=1
    if [ "${FORCE}" != "1" ]; then
        TABLE_COUNT=$(mariadb -h"${MARIADB_HOST}" -P"${MARIADB_PORT}" \
            -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" -sN \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MARIADB_DATABASE}';")
        if [ "${TABLE_COUNT}" -gt 0 ]; then
            echo "ERROR: Database '${MARIADB_DATABASE}' already contains ${TABLE_COUNT} table(s). Use FORCE=1 to override."
            exit 1
        fi
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        echo "==> DRY_RUN=1: skipping migration"
        exit 0
    fi

    echo "==> Running migration script"
    python3 /app/migrate.py

fi
