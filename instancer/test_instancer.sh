#!/usr/bin/env bash
set -u
# Portable smoke test for the instancer control plane.
# Override any of these to match your deployment:
#   PROJECT_DIR  path to your CTFd checkout that holds .env (default: current dir)
#   COMPOSE_NET  the Compose default network name
#   CTFD_HOST    the Host header CTFd expects
#   TRAEFIK_URL  base URL of the Traefik entry point
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
COMPOSE_NET="${COMPOSE_NET:-ctfd_default}"
CTFD_HOST="${CTFD_HOST:-localhost}"
TRAEFIK_URL="${TRAEFIK_URL:-http://localhost:11080}"
cd "$PROJECT_DIR"
TOKEN=$(grep '^INSTANCER_TOKEN=' .env | cut -d= -f2-)
NET="$COMPOSE_NET"
CURL=curlimages/curl:8.10.1
api(){ local m=$1 p=$2 b=${3:-};
  if [ -n "$b" ]; then docker run --rm --network $NET $CURL -s -X "$m" -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' -d "$b" "http://instancer:8080$p";
  else docker run --rm --network $NET $CURL -s -X "$m" -H "X-Auth-Token: $TOKEN" "http://instancer:8080$p"; fi; }

echo "== 1. Traefik / -> CTFd =="
curl -s -o /dev/null -w 'root_status=%{http_code}\n' -H "Host: $CTFD_HOST" "$TRAEFIK_URL/"
echo "== 2. instancer health =="; api GET /healthz; echo

echo "== 3. create WEB instance =="
WEB=$(api POST /instances '{"chal_id":1,"user_id":1,"image":"chal-web-sample:latest","port":8080,"flag":"flag{web_dynamic_1}","kind":"web","ttl":30,"per_user_limit":2}')
echo "$WEB"
WURL=$(echo "$WEB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
WIID=$(echo "$WEB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "web url=$WURL iid=$WIID"; sleep 4
echo "-- reach web via Traefik --"
curl -s -o /dev/null -w 'web_status=%{http_code}\n' "$TRAEFIK_URL$WURL"
echo -n '-- solve via SQLi, flag= '; curl -s "$TRAEFIK_URL$WURL" --data "user=admin&pass=' OR '1'='1" | grep -o 'flag{[^}]*}' | head -1

echo "== 4. create PWN (ttyd) instance =="
PWN=$(api POST /instances '{"chal_id":2,"user_id":1,"image":"chal-pwn-sample:latest","port":8080,"flag":"flag{pwn_dynamic_1}","kind":"tcp","ttl":30,"per_user_limit":2}')
echo "$PWN"
PURL=$(echo "$PWN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
PIID=$(echo "$PWN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
sleep 4
curl -s -o /tmp/ttyd.html -w 'pwn_status=%{http_code}\n' "$TRAEFIK_URL$PURL"
echo -n 'ttyd page marker: '; grep -o -m1 -iE 'ttyd|xterm|terminal' /tmp/ttyd.html || echo MISSING

echo "== 5. per-user cap (limit=2 -> expect 429) =="
api POST /instances '{"chal_id":3,"user_id":1,"image":"chal-web-sample:latest","port":8080,"flag":"x","kind":"web","ttl":30,"per_user_limit":2}'; echo
echo "== 6. idempotency (re-request chal1 -> same url) =="
api POST /instances '{"chal_id":1,"user_id":1,"image":"chal-web-sample:latest","port":8080,"flag":"flag{web_dynamic_1}","kind":"web","ttl":30,"per_user_limit":2}' | python3 -c 'import sys,json;print("same_url="+json.load(sys.stdin)["url"])'

echo "== 7. hardening inspect (web instance) =="
docker inspect inst_$WIID --format 'ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} CapDrop={{.HostConfig.CapDrop}} SecOpt={{.HostConfig.SecurityOpt}} Pids={{.HostConfig.PidsLimit}} Mem={{.HostConfig.Memory}} User={{.Config.User}}'
echo -n 'instance networks: '; docker inspect inst_$WIID --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'; echo
docker network inspect instnet_$WIID --format 'net_internal={{.Internal}}'
echo -n 'egress test (expect blocked): '; docker run --rm --network instnet_$WIID $CURL -s -m 6 -o /dev/null -w 'egress_status=%{http_code}\n' https://1.1.1.1 || echo egress_blocked=yes

echo "== 8. list user 1 instances =="
api GET '/instances?user_id=1' | python3 -c 'import sys,json;d=json.load(sys.stdin);print("count="+str(len(d)));[print("  chal",x["chal_id"],x["kind"],x["url"]) for x in d]'

echo "== 9. destroy both =="
api DELETE /instances/$WIID; echo; api DELETE /instances/$PIID; echo
api GET '/instances?user_id=1' | python3 -c 'import sys,json;print("remaining="+str(len(json.load(sys.stdin))))'
echo TEST_DONE
