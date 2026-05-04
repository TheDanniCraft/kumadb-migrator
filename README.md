# Uptimekuma Migration SQLite to MariaDB

[![Pylint](https://github.com/cmauf/kumadb-migrator/actions/workflows/pylint.yml/badge.svg)](https://github.com/cmauf/kumadb-migrator/actions/workflows/pylint.yml)
[![CodeQL](https://github.com/cmauf/kumadb-migrator/actions/workflows/github-code-scanning/codeql/badge.svg?branch=main)](https://github.com/cmauf/kumadb-migrator/actions/workflows/github-code-scanning/codeql)
[![Build & publish Docker image to GHCR](https://github.com/cmauf/kumadb-migrator/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/cmauf/kumadb-migrator/actions/workflows/docker-publish.yml)

This project is aimed to provide a seamless migration of an Uptime Kuma database from SQLite to MariaDB.

## Preface

With V2, Uptime Kuma introduced support for MariaDB. It can run within the Docker Container, but also external.
This project aims to provide a one-shot migration of an existing Uptime Kuma DB from SQLite to MariaDB. The resulting
MariaDB database can then be used from within Uptime Kuma or a dedicated container.

## Prerequisites

- have Docker installed
- have an Uptime Kuma instance
- have the DB already upgraded to V2

## Modes

The migrator supports two modes, selected automatically based on `MARIADB_HOST`:

### Local datadir mode (default)

When `MARIADB_HOST` is unset, `localhost`, or `127.0.0.1`, the container starts its own MariaDB instance,
imports the SQLite database, and then shuts MariaDB down. The resulting `/var/lib/mysql` directory can be
mounted directly into a MariaDB container.

```bash
docker build -t uptimekuma-db-migrator .

docker run --rm \
  -e MARIADB_USER=kuma \
  -e MARIADB_PASSWORD='change-me' \
  -v /path/to/kuma.db:/app/kuma.db:ro \
  -v /path/to/mariadb/data:/var/lib/mysql \
  uptimekuma-db-migrator
```

If run successfully, the container leaves a directory at `/path/to/mariadb/data` that you can mount into a
MariaDB container serving as your Uptime Kuma database.

### Remote / cloud DB mode

When `MARIADB_HOST` is set to a hostname other than `localhost` / `127.0.0.1`, the container does **not**
start a local MariaDB instance. Instead it connects directly to the remote server and migrates the data there.

The target database must be reachable and the supplied user must have `CREATE`, `INSERT`, `DROP`, and `ALTER`
privileges on the target database. If the database does not yet exist the migrator will attempt to create it;
if the user lacks `CREATE DATABASE` privileges, create the database manually beforehand.

```bash
docker run --rm \
  -e MARIADB_HOST=my-cloud-db.example.com \
  -e MARIADB_PORT=3306 \
  -e MARIADB_DATABASE=kumadb \
  -e MARIADB_USER=kuma \
  -e MARIADB_PASSWORD='change-me' \
  -v /path/to/kuma.db:/app/kuma.db:ro \
  uptimekuma-db-migrator
```

## Environment variables

| Variable               | Required | Default     | Description                                                                 |
|------------------------|----------|-------------|-----------------------------------------------------------------------------|
| `MARIADB_USER`         | yes      | —           | MariaDB user name                                                           |
| `MARIADB_PASSWORD`     | yes      | —           | MariaDB password                                                            |
| `MARIADB_HOST`         | no       | `localhost` | Target host. Set to a remote hostname to enable remote mode.                |
| `MARIADB_PORT`         | no       | `3306`      | Target port                                                                 |
| `MARIADB_DATABASE`     | no       | `kumadb`    | Target database name                                                        |
| `FORCE`                | no       | `0`         | Set to `1` to migrate into a non-empty destination database                 |
| `DRY_RUN`              | no       | `0`         | Set to `1` to check connectivity and list source tables without migrating   |
| `IGNORE_INSERT_ERRORS` | no       | `0`         | Set to `1` to skip rows that fail to insert (default is to abort on error)  |

## Acknowledgements

The central `migrate.py` is taken from [harshavmb's Project](https://github.com/harshavmb/sqlite3tomysql/). There were
modifications made by splitting the script in functions of smaller scope and removing fallbacks for old MySQL versions.

## Notes

- Stop your Kuma instance before making a copy of `kuma.db`.
- The migrator prints the destination host, port, and database name before migrating, but **never** the password.
- By default the migrator refuses to run against a non-empty destination database. Use `FORCE=1` to override.
- Row counts are verified after migration and a summary table is printed.
