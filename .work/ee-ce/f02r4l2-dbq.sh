#!/bin/zsh
# DB query helper: f02r4l2-dbq.sh "<sql>"
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-dbenv; set +a
/opt/homebrew/opt/libpq@18/bin/psql "postgresql://$DB_USER:$DB_PASSWORD@qnap.elf-balance.ts.net:5432/nocodb-dev" -tAc "$1"
