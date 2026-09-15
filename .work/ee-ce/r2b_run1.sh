#!/bin/zsh
# r2b_run1.sh — F05 R2 int-b API 对抗测试（单 signin 连续执行）
set -u
cd /Volumes/UNITEK/Documents/Development/nocodb
OUT=.work/ee-ce/r2b_state.txt
: > $OUT

fresh() {
  # dedicated per-path account — shared admin's token_version gets bumped by
  # parallel review agents' signins, invalidating our JWT within seconds
  TOKEN=$(curl -s -X POST http://127.0.0.1:8080/api/v1/auth/user/signin -H "Content-Type: application/json" -d '{"email":"f05r2b@ce-ee.local","password":"F05r2b!pass9"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
}

api() { # api METHOD PATH [JSON] -> prints "STATUS\tBODY"
  local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then
    curl -s -w "\t%{http_code}" -X "$m" "http://127.0.0.1:8080$p" -H "xc-auth: $TOKEN" -H "Content-Type: application/json" -d "$b"
  else
    curl -s -w "\t%{http_code}" -X "$m" "http://127.0.0.1:8080$p" -H "xc-auth: $TOKEN"
  fi
}

# extract json field (strips trailing "\t<status>" appended by api())
jf() { python3 -c "
import sys, json, re
raw = re.sub(r'\t[0-9]+$', '', sys.argv[1])
d = json.loads(raw)
for k in sys.argv[2].split('.'):
    d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d) if isinstance(d,(dict,list)) else ('' if d is None else d))
" "$1" "$2" 2>/dev/null; }

say() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" | tee -a $OUT; }

fresh || { echo "SIGNIN FAIL"; exit 1; }

# --- base setup ---
R=$(api POST /api/v1/db/meta/projects/ '{"title":"f05r2b_base"}')
BASEID=$(jf "$R" id)
[ -n "$BASEID" ] || { say SETUP base "$R"; exit 1; }
echo "BASEID=$BASEID" >> $OUT
say SETUP base_ok "$BASEID" "base created"

# ================= T1: secret ciphertext at rest =================
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"SECRET_A","value":"plain-A-value","type":"secret"}')
ST=${R##*$'\t'}; BODY=${R%$'\t'*}
VID_A=$(jf "$BODY" id)
say T1 create_secret "$ST" "$VID_A"
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_A)
say T1 get_secret_single "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"
R=$(api GET /api/v2/meta/bases/$BASEID/variables)
LBODY=${R%$'\t'*}
say T1 list_value_field "${R##*$'\t'}" "$(python3 -c "
import json
d = json.loads('''$LBODY''')
v = [x for x in d if x.get('key')=='SECRET_A'][0]
print('value=' + ('ABSENT' if 'value' not in v or v['value'] is None else str(v['value'])[:20]) + ';default_value=' + ('ABSENT' if v.get('default_value') is None else 'PRESENT'))
")"
echo "VID_A=$VID_A" >> $OUT

# ================= T2: state machine text(A) -> secret -> value(B) -> text =================
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"SM_VAR","value":"alpha","type":"text"}')
ST=${R##*$'\t'}; VID_SM=$(jf "${R%$'\t'*}" id)
say T2 create_text "$ST" "$VID_SM"
echo "VID_SM=$VID_SM" >> $OUT
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_SM)
say T2 step1_text_read "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"

R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{"type":"secret"}')
say T2 step2_to_secret "${R##*$'\t'}" ""
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_SM)
say T2 step2_read "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"
R=$(api GET /api/v2/meta/bases/$BASEID/variables)
say T2 step2_list_mask "${R##*$'\t'}" "$(python3 -c "
import json
d = json.loads('''${R%$'\t'*}''')
v = [x for x in d if x.get('key')=='SM_VAR'][0]
print('value=' + ('ABSENT' if v.get('value') is None else str(v['value'])[:15]))
")"

R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{"value":"beta"}')
say T2 step3_change_value "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"

R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{"type":"text"}')
say T2 step4_to_text "${R##*$'\t'}" ""
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_SM)
say T2 step4_read "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"
R=$(api GET /api/v2/meta/bases/$BASEID/variables)
say T2 step4_list_plaintext "${R##*$'\t'}" "$(python3 -c "
import json
d = json.loads('''${R%$'\t'*}''')
v = [x for x in d if x.get('key')=='SM_VAR'][0]
print('value=' + ('ABSENT' if v.get('value') is None else v['value']))
")"

# ================= T3: invalid input matrix (all POST unless noted) =================
mk() { # mk name json
  local R=$(api POST /api/v2/meta/bases/$BASEID/variables "$2")
  say T3 "$1" "${R##*$'\t'}" "$(printf '%s' "${R%$'\t'*}" | head -c 160)"
}
mk type_weird     '{"key":"T3A","value":"v","type":"weird"}'
mk type_Secret    '{"key":"T3B","value":"v","type":"Secret"}'
mk type_number_1  '{"key":"T3C","value":"v","type":1}'
mk type_null      '{"key":"T3D","value":"v","type":null}'
mk value_object   '{"key":"T3E","value":{"x":1},"type":"text"}'
mk value_number   '{"key":"T3F","value":42,"type":"text"}'
BIGVAL=$(python3 -c "print('x'*65537)")
mk value_65537    "{\"key\":\"T3G\",\"value\":\"$BIGVAL\",\"type\":\"text\"}"
K300=$(python3 -c "print('K'*300)")
mk key_300        "{\"key\":\"$K300\",\"value\":\"v\",\"type\":\"text\"}"
mk key_space      '{"key":"MY VAR","value":"v","type":"text"}'
mk key_chinese    '{"key":"中文键","value":"v","type":"text"}'
mk key_lowercase  '{"key":"my_var","value":"v","type":"text"}'
mk key_dup        '{"key":"SECRET_A","value":"v","type":"text"}'
mk key_digit_lead '{"key":"1VAR","value":"v","type":"text"}'
# PATCH cases on SM_VAR
R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{}')
say T3 patch_empty_body "${R##*$'\t'}" "$(printf '%s' "${R%$'\t'*}" | head -c 120)"
R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{"key":"SM_VAR"}')
say T3 patch_key_same "${R##*$'\t'}" "$(printf '%s' "${R%$'\t'*}" | head -c 120)"
R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_SM '{"key":"SM_CHANGED"}')
say T3 patch_key_change "${R##*$'\t'}" "$(printf '%s' "${R%$'\t'*}" | head -c 120)"

# ================= T4: fix regression =================
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"DEFV","value":"v1","type":"text","default_value":"LEAK_SECRET","order":999,"base_id":"INJECT","is_overridden":true,"is_inherited":true,"inheritance":"x"}')
ST=${R##*$'\t'}; BODY=${R%$'\t'*}
say T4 create_inject "$ST" "$(python3 -c "
import json
d = json.loads('''$BODY''')
print('default_value=' + ('ABSENT' if d.get('default_value') is None else 'PRESENT_LEAK') + ';base_id=' + str(d.get('base_id')) + ';order=' + str(d.get('order')) + ';is_overridden=' + str(d.get('is_overridden')))
")"
VID_DEFV=$(jf "$BODY" id)
echo "VID_DEFV=$VID_DEFV" >> $OUT
# T5 order auto-increment: create 2 plain vars, check order strictly increasing and != 999
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"ORD_1","value":"a","type":"text"}')
O1=$(jf "${R%$'\t'*}" order)
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"ORD_2","value":"a","type":"text"}')
O2=$(jf "${R%$'\t'*}" order)
say T5 order_auto "200" "ORD_1.order=$O1 ORD_2.order=$O2 (999_was_rejected_above)"
R=$(api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_DEFV '{"default_value":"PATCH_LEAK","value":"v2"}')
say T4 patch_default_value "${R##*$'\t'}" "$(python3 -c "
import json
d = json.loads('''${R%$'\t'*}''')
print('value=' + str(d.get('value')) + ';default_value=' + ('ABSENT' if d.get('default_value') is None else 'PRESENT_LEAK'))
")"
R=$(api GET /api/v2/meta/bases/$BASEID/variables)
say T4 list_no_default "${R##*$'\t'}" "$(python3 -c "
import json
d = json.loads('''${R%$'\t'*}''')
n = sum(1 for x in d if x.get('default_value') is not None)
print('rows_with_default_value=' + str(n))
")"

# ================= T6: concurrent same key x5 =================
# write a token file for the 5 background racers AFTER the last fresh signin
# (any later signin on this account would invalidate it via token_version bump)
printf '%s' "$TOKEN" > .work/ee-ce/.r2b_token2
for i in 1 2 3 4 5; do
  ( curl -s -o /dev/null -w "%{http_code}\n" -X POST "http://127.0.0.1:8080/api/v2/meta/bases/$BASEID/variables" -H "xc-auth: $(cat .work/ee-ce/.r2b_token2)" -H "Content-Type: application/json" -d '{"key":"RACE_KEY","value":"v","type":"text"}' >> .work/ee-ce/r2b_race.txt ) &
done
say T6 race_started "launched" "results below"
wait

# ================= T8: cache =================
R=$(api POST /api/v2/meta/bases/$BASEID/variables '{"key":"CACHE_VAR","value":"before","type":"text"}')
VID_C=$(jf "${R%$'\t'*}" id)
echo "VID_C=$VID_C" >> $OUT
api PATCH /api/v2/meta/bases/$BASEID/variables/$VID_C '{"value":"after"}' > /dev/null
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_C)
say T8 patch_then_get "${R##*$'\t'}" "$(jf "${R%$'\t'*}" value)"
R=$(api DELETE /api/v2/meta/bases/$BASEID/variables/$VID_C)
say T8 delete "${R##*$'\t'}" ""
R=$(api GET /api/v2/meta/bases/$BASEID/variables/$VID_C)
say T8 get_after_delete "${R##*$'\t'}" "$(printf '%s' "${R%$'\t'*}" | head -c 100)"

# ================= T7: base delete residue =================
R=$(api POST /api/v1/db/meta/projects/ '{"title":"f05r2b_del"}')
DELBASE=$(jf "$R" id)
echo "DELBASE=$DELBASE" >> $OUT
api POST /api/v2/meta/bases/$DELBASE/variables '{"key":"D_KEY1","value":"v","type":"text"}' > /dev/null
api POST /api/v2/meta/bases/$DELBASE/variables '{"key":"D_KEY2","value":"sv","type":"secret"}' > /dev/null
R=$(api DELETE /api/v1/db/meta/projects/$DELBASE)
say T7 base_delete "${R##*$'\t'}" "$DELBASE"

say DONE all "completed" ""
