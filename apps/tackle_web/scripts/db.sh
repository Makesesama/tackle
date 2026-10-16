#!/usr/bin/env bash
# A PostgreSQL cluster for development and tests, under apps/tackle_web/.postgres,
# for when no server runs on localhost:5432 (the default in config/config.exs).
#
#   scripts/db.sh start    initialise (first time) and start the cluster
#   scripts/db.sh stop     stop it
#   scripts/db.sh status   report whether it runs
#
# The cluster listens only on a Unix socket in that directory (no TCP port)
# and trusts local connections as the `postgres` user. Point the app at it
# with `export TACKLE_WEB_PGHOST=<that directory>`, as `start` prints; the
# script uses the same variable to choose another directory. Needs `initdb`
# and `pg_ctl` on PATH, as the Nix development shell provides.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${TACKLE_WEB_PGHOST:-$root/.postgres}
data=$dir/data

for tool in initdb pg_ctl; do
  if ! command -v "$tool" > /dev/null; then
    echo "db.sh: $tool not found; run this inside 'nix develop'" >&2
    exit 1
  fi
done

case ${1:-} in
  start)
    if [[ ! -f "$data/PG_VERSION" ]]; then
      mkdir -p "$dir"
      initdb --pgdata="$data" --username=postgres --auth=trust \
        --encoding=UTF8 --locale=C.UTF-8 > "$dir/initdb.log"
    fi
    if pg_ctl status --pgdata="$data" > /dev/null; then
      echo "db.sh: already running ($dir)"
    else
      pg_ctl start --pgdata="$data" --log="$dir/postgres.log" --wait \
        --options="-c listen_addresses='' -k '$dir'"
    fi
    echo "db.sh: use it with: export TACKLE_WEB_PGHOST=$dir"
    ;;
  stop)
    if pg_ctl status --pgdata="$data" > /dev/null 2>&1; then
      pg_ctl stop --pgdata="$data" --mode=fast --wait
    else
      echo "db.sh: not running"
    fi
    ;;
  status)
    pg_ctl status --pgdata="$data"
    ;;
  *)
    echo "usage: $0 start|stop|status" >&2
    exit 2
    ;;
esac
