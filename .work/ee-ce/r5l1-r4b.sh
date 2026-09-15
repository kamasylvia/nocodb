#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
B=http://localhost:8080
. "$D/r5l1-common.sh"
P="$B/api/v2/meta/bases/$BID/permissions"
J="$D/r5l1-tmp.json"
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
export PGPASSWORD="$DB_PASSWORD"
EUID_=$("$PSQL" -h qnap.elf-balance.ts.net -p 5432 -U postgres -d nocodb-dev -t -A -c "SELECT id FROM nc_users_v2 WHERE email='$E'")
CUID=$("$PSQL" -h qnap.elf-balance.ts.net -p 5432 -U postgres -d nocodb-dev -t -A -c "SELECT id FROM nc_users_v2 WHERE email='$C'")
echo "editor uid=$EUID_ creator uid=$CUID"
PK="RECORD_FIELD_EDIT"

# user grant on Secret col（现 grant 是 nobody → 先切回 user grant with subjects）
GID=$(curl -s "$P" -H "xc-auth: $TO" | jq -r --arg c "$SECRET_ID" '.[] | select(.entity_id==$c) | .id')
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"}]}")
echo "R4b0 switch to user grant -> $C (expect 200)"

# R4②核心：PATCH team subjects 不带 granted_type
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"subjects":[{"type":"team","id":"tm_xxx"}]}')
echo "R4b1 PATCH team subjects (no granted_type) -> $C (expect 400) body: $(head -c 90 "$J")"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"team\",\"id\":\"tm_xxx\"}]}")
echo "R4b2 PATCH team subjects (explicit type) -> $C (expect 400)"

# 混合 user+team subjects
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"},{\"type\":\"team\",\"id\":\"tm_xxx\"}]}")
echo "R4b3 PATCH mixed user+team -> $C (expect 400)"

# 合法 user subjects PATCH 仍 200
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"},{\"type\":\"user\",\"id\":\"$CUID\"}]}")
echo "R4b4 PATCH legit user subjects -> $C (expect 200)"
curl -s "$P" -H "xc-auth: $TO" | jq -r --arg g "$GID" '.[] | select(.id==$g) | "  subjects now: \([.subjects[].id] | join(",")) (expect both uids)"'

# nobody + subjects（POST 与 PATCH）
C=$(curl -s -o "$J" -w "%{http_code}" -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAME_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"}]}")
echo "R3r1 POST nobody+subjects -> $C (expect 400)"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"}]}")
echo "R3r2 PATCH nobody+subjects -> $C (expect 400)"

# role grant 无 granted_role POST
C=$(curl -s -o "$J" -w "%{http_code}" -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAME_ID\",\"permission\":\"$PK\",\"granted_type\":\"role\"}")
echo "R3r3 POST role w/o granted_role -> $C (expect 400)"
