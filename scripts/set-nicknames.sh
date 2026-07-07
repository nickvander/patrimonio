#!/usr/bin/env bash
# One-shot: set friendly nicknames on the five long-named accounts via the
# app's own rename API (PATCH /api/accounts/{id}/nickname), using a 5-minute
# owner session minted directly in the prod DB and deleted afterwards.
# Run FROM the dev VM:  bash scripts/set-nicknames.sh
# Edit the rename lines below first if you want different names.

set -euo pipefail

ssh nickvander@thelab bash -s <<'EOF'
set -e
RAW=$(head -c 32 /dev/urandom | sha256sum | cut -c1-48)
HASH=$(printf '%s' "$RAW" | sha256sum | cut -d' ' -f1)
SESS=$(docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio -tAq -c \
  "insert into user_sessions (user_id, token_hash, expires_at)
   select id, decode('$HASH','hex'), now() + interval '5 minutes'
   from users where username='nickvda' returning id")

rename() {
  curl -s -o /dev/null -w "%{http_code}  $2\n" -X PATCH \
    "http://127.0.0.1:8085/api/accounts/$1/nickname" \
    -H "Cookie: patrimonio_session=$RAW" \
    -H "Content-Type: application/json" \
    -H "X-Requested-With: XMLHttpRequest" \
    -d "{\"nickname\":\"$2\"}"
}

rename ee8b6cbd-c4d5-4cd2-9db5-c5cee461a5f6 "Roth IRA"            # Vanguard Roth ****9215
rename 45e3bd06-2a9d-4508-bb58-c28bcc20e286 "Traditional IRA"     # Vanguard Trad ****2262
rename 20713e41-9f3a-41f1-adf4-8aac32106848 "Google 401(k)"       # GOOGLE LLC 401(K) SAVINGS PLAN
rename 7bbdc895-4dd5-4463-8fa9-dab55ec3fbe3 "Alphabet GSUs"       # Morgan Stanley StockPlan "Alphabet, Inc."
rename e4484630-119a-477e-a0a8-8ad4ebe1d700 "Fidelity Individual" # Fidelity "Individual"

docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio -tAq -c \
  "delete from user_sessions where id='$SESS'"
echo "temp session deleted"
docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio -c \
  "select nickname, name from accounts where coalesce(nickname,'') != ''"
EOF
