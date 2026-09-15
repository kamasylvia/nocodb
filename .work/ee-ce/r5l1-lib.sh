# 无管道 helper：req <outfile> <curl args...>；reqc <outfile> <codefile> <curl args...>
req() { local out="$1"; shift; curl -s -o "$out" "$@"; }
reqc() { local out="$1" code="$2"; shift 2; local c; c=$(curl -s -o "$out" -w "%{http_code}" "$@"); printf '%s' "$c" > "$code"; }
