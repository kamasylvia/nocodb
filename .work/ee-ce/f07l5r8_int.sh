#!/bin/zsh
# f07l5r8_int.sh — F07 R8 lane5 交叉抽验：secret 变量源 base → 快照 → restore → 删除全链路
# 每步 DB 核验（pg8000 直查 nocodb-dev）。凭证运行时 Infisical 拉取，不落盘。
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMAIL="f07l5r8_${TS}@ce-ee.local"
PASS="F07l5r8!pass1"
LOG="$REPO/.work/ee-ce/f07l5r8_out.txt"
: > "$LOG"
say() { printf '\n== %s ==\n' "$1" | tee -a "$LOG"; }
ok()  { printf '  ok: %s\n' "$1" | tee -a "$LOG"; }
fail(){ printf 'FAIL: %s\n' "$1" | tee -a "$LOG"; exit 1; }

# --- Infisical → DB 凭证 ---
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SEC=$(infisical secrets --token "$TK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""; DB_PORT="5432"
while IFS='=' read -r k v; do case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; DB_PORT) DB_PORT="$v";; esac; done <<< "$SEC"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || fail "DB 凭证未取到"

dbq() { uv run --with pg8000 python3 "$REPO/.work/ee-ce/f07l5r8_db.py" qnap.elf-balance.ts.net "$DB_PORT" "$DB_USER" "$DB_PASSWORD" "$@"; }

J() { python3 -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d.get('$1') if '$1' in d else d,ensure_ascii=False))"; }

say "P0. signup + promote creator"
TOK=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
[ -n "$TOK" ] || fail "signup 无 token"
dbq promote "$EMAIL" | grep -q creator || fail "promote creator"
AUTH=(-H "xc-auth: $TOK" -H 'Content-Type: application/json')
ok "user=$EMAIL token+len=${#TOK}"

say "P1. create base + table + rows"
SRC=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f07l5r8_src_$TS\"}")
SRC_ID=$(echo "$SRC" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
TBL=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/tables" "${AUTH[@]}" -d "{\"table_name\":\"t1\",\"columns\":[{\"column_name\":\"Name\",\"uidt\":\"SingleLineText\"},{\"column_name\":\"Qty\",\"uidt\":\"Number\"}]}")
TBL_ID=$(echo "$TBL" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
for i in 1 2 3; do curl -sS -o /dev/null -X POST "$BASE_URL/api/v2/tables/$TBL_ID/records" "${AUTH[@]}" -d "{\"Name\":\"row$i\",\"Qty\":$i}"; done
CNT=$(curl -sS "$BASE_URL/api/v2/tables/$TBL_ID/records" "${AUTH[@]}" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['list']))")
[ "$CNT" = "3" ] || fail "行数 $CNT != 3"
ok "base=$SRC_ID table=$TBL_ID rows=3"

say "P2. F05 secret variable 写入 + DB 加密核验"
VAR=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/variables" "${AUTH[@]}" -d "{\"key\":\"API_TOKEN\",\"value\":\"s3cr3t-plain-${TS}\",\"type\":\"secret\",\"description\":\"lane5 r8\"}")
echo "$VAR" | head -c 300 >> "$LOG"; echo >> "$LOG"
VAR_ID=$(echo "$VAR" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ -n "$VAR_ID" ] || fail "secret variable 创建失败: $(echo "$VAR" | head -c 200)"
RAWV=$(dbq vars "$SRC_ID")
echo "$RAWV" | grep -q "s3cr3t-plain-${TS}" && fail "DB 明文存储 secret！" || ok "DB 无明文（加密落库）"
LISTMASK=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_ID/variables" "${AUTH[@]}" | python3 -c "import sys,json;d=json.load(sys.stdin);v=d['list'][0] if isinstance(d,dict) and 'list' in d else d[0];print(v.get('value','MISSING'))")
[ "$LISTMASK" != "s3cr3t-plain-${TS}" ] || fail "list 响应未掩码"
ok "list 掩码: value=$LISTMASK"

say "P3. create snapshot → completed（轮询）"
SNAP=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH[@]}" -d '{}')
SNAP_ID=$(echo "$SNAP" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
COPY_ID=$(echo "$SNAP" | python3 -c "import sys,json;print(json.load(sys.stdin)['snapshot_base_id'])")
ST=""
for i in $(seq 1 40); do sleep 3; ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])"); [ "$ST" = "completed" ] && break; done
[ "$ST" = "completed" ] || fail "快照未 completed: $ST"
SNAPROW=$(dbq snaps "$SRC_ID")
echo "$SNAPROW" | grep -q "$COPY_ID" || fail "nc_snapshots 无副本行"
ok "snapshot=$SNAP_ID copy=$COPY_ID（DB 核验注册行存在）"
COPYCHK=$(dbq base "$COPY_ID")
COPYDEL=$(echo "$COPYCHK" | python3 -c "import sys,json;print(json.load(sys.stdin)[0][3])")
[ "$COPYDEL" = "False" ] || [ "$COPYDEL" = "false" ] || fail "副本 base 不在/已删: $COPYCHK"
ok "副本 base DB 存在且未删"
COPYVARS=$(dbq vars "$COPY_ID")
echo "$COPYVARS" | grep -qv '"count.*, ' || true
COPYVCNT=$(echo "$COPYVARS" | python3 -c "import sys,json;print(json.load(sys.stdin)[0][0])")
[ "$COPYVCNT" = "0" ] || fail "快照副本带了 variables（count=$COPYVCNT）——secret 物料通道泄露"
ok "副本 base variables count=0（无 secret 物料通道）"

say "P4. restore → 新 base"
REST=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID/restore" "${AUTH[@]}" -d '{}')
REST_ID=$(echo "$REST" | python3 -c "import sys,json;print(json.load(sys.stdin).get('base_id',''))")
[ -n "$REST_ID" ] || fail "restore 失败: $(echo "$REST" | head -c 200)"
RCHK=$(dbq base "$REST_ID")
echo "$RCHK" | grep -qi "restored" || fail "restore 产物 title 不含 (restored): $RCHK"
ok "restored base=$REST_ID DB 核验存在: $RCHK"
ok "restored base=$REST_ID DB 核验存在"
RT=$(curl -sS "$BASE_URL/api/v2/meta/bases/$REST_ID/tables" "${AUTH[@]}" | python3 -c "import sys,json;d=json.load(sys.stdin);l=d['list'] if isinstance(d,dict) and 'list' in d else d;print(len(l))")
[ "$RT" -ge 1 ] || fail "restored base 无表"
ok "restored base 表数=$RT"

say "P5. deleteSnapshot → 副本 softDelete + 注册行删除"
curl -sS -o /dev/null -w '' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}"
sleep 2
SNAPROW2=$(dbq snaps "$SRC_ID")
echo "$SNAPROW2" | grep -q "$SNAP_ID" && fail "注册行未删: $SNAPROW2" || ok "注册行已删"
CCHK=$(dbq base "$COPY_ID")
CDEL=$(echo "$CCHK" | python3 -c "import sys,json;print(json.load(sys.stdin)[0][3])")
[ "$CDEL" = "True" ] || [ "$CDEL" = "true" ] || fail "副本未 softDelete: $CCHK"
ok "副本 DB deleted=true"
ST2=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}")
[ "$ST2" = "404" ] || fail "已删快照 GET 应 404, got $ST2"
ok "已删快照 GET=404"

say "P6. delete restore 产物 + 源 base → 无孤儿"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$REST_ID" "${AUTH[@]}"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID" "${AUTH[@]}"
sleep 3
ORPH=$(dbq orphans "$SRC_ID")
echo "$ORPH" | grep -q '"snaps": 0' || fail "孤儿快照行: $ORPH"
ok "nc_snapshots 源 base 无残留: $ORPH"

say "P7. 权限抽查（独立 probe base，404 vs 401 区分）"
PROBE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f07l5r8_probe_$TS\"}")
PROBE_ID=$(echo "$PROBE" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
C1=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$PROBE_ID/snapshots")
[ "$C1" = "401" ] || fail "无 token 应 401, got $C1"
ok "无 token list=401"
C2=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$PROBE_ID/snapshots" -H 'Content-Type: application/json' -d '{}')
[ "$C2" = "401" ] || fail "无 token create 应 401, got $C2"
ok "无 token create=401"
BADTOK=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$PROBE_ID/snapshots" -H 'xc-auth: bogus.token.here')
[ "$BADTOK" = "401" ] || fail "坏 token 应 401, got $BADTOK"
ok "坏 token=401"
C3=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$PROBE_ID/snapshots/nonexistent_id" "${AUTH[@]}")
[ "$C3" = "404" ] || fail "伪 snapshotId 应 404, got $C3"
ok "伪 snapshotId=404"
C4=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/nobase123/snapshots" "${AUTH[@]}")
[ "$C4" = "404" ] || [ "$C4" = "403" ] || fail "伪 baseId 应 404/403, got $C4"
ok "伪 baseId=$C4"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$PROBE_ID" "${AUTH[@]}"

say "ALL PASS"
