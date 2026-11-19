#!/usr/bin/env bash
# Regression test: SeAT must import CCP's current EVE static data (SDE),
# start again on a recreated container, and keep the previous static data
# when an import is interrupted.
#
# Usage (on the builder host, needs docker and internet):
#   release/sde-import-test.sh <image>
#
# 1. Fresh install: the entrypoint copies SeAT, migrates the database and
#    imports CCP's current SDE build. SeAT must end up serving, and invTypes
#    must hold exactly the number of types in CCP's source. (On 5.0.1-5 and
#    earlier the import of build 3720952 fails on a 161-character type name
#    and the entrypoint exits.)
# 2. Recreate: a new container on the same volumes, as an Appbox update
#    creates it, must find the static data current and serve.
# 3. Interrupted import: the stored build is cleared so the next start
#    imports again, and the test kills the import while it seeds. The next
#    container must restore the previous tables, log the warning and serve,
#    with the static-data row counts unchanged and no copies left behind.
#
# Exit 0: all three steps pass.
# Exit 1: the defect: the import fails or SeAT does not start because of it.
# Exit 2: the test could not run.
set -euo pipefail
LC_ALL=C
export LC_ALL

setup_fail() {
    echo "SETUP FAIL: $*" >&2
    exit 2
}

[ "$#" -eq 1 ] || setup_fail "usage: $0 <image>"
image=$1
case "$image" in ''|*[!A-Za-z0-9._/:@-]*) setup_fail "bad image reference" ;; esac
for tool in docker od date grep sed awk; do
    command -v "$tool" >/dev/null 2>&1 || setup_fail "missing tool: $tool"
done

run_id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
prefix=seat-sdetest-$run_id
cleanup() {
    docker rm -f "$prefix-app" >/dev/null 2>&1 || true
    for volume in public_html mysql config logs; do
        docker volume rm "$prefix-$volume" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT
trap 'exit 2' INT TERM

log() {
    printf '[%s %s] %s\n' "$(date -u +%H:%M:%S)" "$prefix" "$*"
}

docker image inspect "$image" >/dev/null 2>&1 || setup_fail "$image is not a local image"
log "image $image"

# Production bind-mounts these four directories; volume-nocopy keeps the
# image's own content out of them in the same way.
mounts=()
for volume in public_html mysql config logs; do
    docker volume create "$prefix-$volume" >/dev/null
    mounts+=(--mount "type=volume,src=$prefix-$volume,dst=/home/appbox/$volume,volume-nocopy")
done
app_env=(-e WEB_URL=http://seat.sdetest.invalid -e EVE_CLIENT_ID=sdetest-client
    -e EVE_CLIENT_SECRET=sdetest-secret -e ADMIN_PASS=sdetest-admin-password
    -e SKIP_APPBOX_CALLBACK=1)

start_app() {
    docker rm -f "$prefix-app" >/dev/null 2>&1 || true
    docker run -d --name "$prefix-app" "${mounts[@]}" "${app_env[@]}" "$image" >/dev/null
}

app_logs() {
    docker logs "$prefix-app" 2>&1 | grep -av '[▓░]' | grep -aE \
        '\[eveseat\]|static data|EVE static-data|Importing CCP|Seeding SDE|Restored the previous' \
        | cut -c1-240 || true
}

app_serves() {
    local headers code location path login_code
    headers=$(docker exec "$prefix-app" curl -s -o /dev/null -D - --max-time 20 http://127.0.0.1/ | tr -d '\r') \
        || return 1
    code=$(printf '%s\n' "$headers" | awk 'NR == 1 {print $2}')
    location=$(printf '%s\n' "$headers" | sed -n 's/^[Ll]ocation: //p' | head -n 1)
    [ "$code" = 302 ] && [ -n "$location" ] || return 1
    path=/${location#*://*/}
    login_code=$(docker exec "$prefix-app" curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "http://127.0.0.1$path") || return 1
    echo "GET / -> 302 $path, GET $path -> $login_code"
    [ "$login_code" = 200 ]
}

# Wait until the app serves after the entrypoint handed over to the
# supervised services. Returns 1 when the container exits first.
wait_serving() {
    local deadline=$(( $(date +%s) + $1 )) state
    while :; do
        state=$(docker inspect -f '{{.State.Status}}' "$prefix-app" 2>/dev/null || echo missing)
        [ "$state" = running ] || return 1
        if docker logs "$prefix-app" 2>&1 | grep -q '\[eveseat\] Starting supervised services' \
            && app_serves >/dev/null 2>&1; then
            return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || setup_fail "the app did not serve within $1 seconds"
        sleep 10
    done
}

db() {
    docker exec "$prefix-app" sh -c \
        'mysql -u"${DB_USER:-seat}" -p"${DB_PASS:-seat}" -S /run/mysqld/mysqld.sock "${DB_NAME:-seat}" -N -B -e "$1"' \
        sh "$1"
}

sde_counts() {
    db "SELECT CONCAT_WS(' ',
        (SELECT COUNT(*) FROM invTypes), (SELECT COUNT(*) FROM dgmTypeAttributes),
        (SELECT COUNT(*) FROM dgmTypeEffects), (SELECT COUNT(*) FROM chrFactions),
        (SELECT COUNT(*) FROM invCategories), (SELECT COUNT(*) FROM invContrabandTypes),
        (SELECT COUNT(*) FROM invControlTowerResources), (SELECT COUNT(*) FROM invGroups),
        (SELECT COUNT(*) FROM invMarketGroups), (SELECT COUNT(*) FROM invMetaGroups))"
}

defect() {
    echo "--- entrypoint log"
    app_logs | tail -n 40
    echo "RESULT: FAIL ($*)"
    exit 1
}

log "step 1: fresh install with CCP's current static data (downloads the SDE)"
start_app
if ! wait_serving 2700; then
    app_logs | grep -q 'EVE SDE update failed\|EVE static-data update failed' \
        && defect "the fresh install's static-data import failed and the container exited"
    app_logs | tail -n 30 >&2
    setup_fail "the fresh install exited before the static-data step"
fi
verified=$(app_logs | grep -o 'CCP EVE static data verified: build [0-9]*, [0-9]* types' | tail -n 1)
[ -n "$verified" ] || defect "no verified static-data import in the log"
build=$(printf '%s\n' "$verified" | sed 's/.*build \([0-9]*\),.*/\1/')
types=$(printf '%s\n' "$verified" | sed 's/.* \([0-9]*\) types/\1/')
counts_before=$(sde_counts)
log "imported build $build: $types types; table counts $counts_before"
[ "${counts_before%% *}" = "$types" ] || defect "invTypes holds ${counts_before%% *} rows, CCP has $types types"
[ "$(db "SELECT value FROM global_settings WHERE name = 'appbox_installed_ccp_sde'" | tr -d '"')" = "$build" ] \
    || defect "the imported build was not recorded"
log "app serves: $(app_serves)"

log "step 2: recreated container on the same volumes"
start_app
wait_serving 1800 || defect "the recreated container exited"
app_logs | grep -q "CCP EVE static data is current (build $build)" \
    || defect "the recreated container did not find build $build current"
[ "$(docker inspect -f '{{.RestartCount}}' "$prefix-app")" = 0 ] || defect "the recreated container restarted"
log "recreated container serves without re-importing: $(app_serves)"

log "step 3: an import interrupted while it seeds keeps the previous data"
db "UPDATE global_settings SET value = '1' WHERE name = 'appbox_installed_ccp_sde'"
start_app
deadline=$(( $(date +%s) + 1800 ))
until docker logs "$prefix-app" 2>&1 | grep -aq 'Seeding SDE into Database'; do
    [ "$(docker inspect -f '{{.State.Status}}' "$prefix-app")" = running ] \
        || defect "the container exited before the import started seeding"
    [ "$(date +%s)" -lt "$deadline" ] || setup_fail "the import did not start seeding within 1800 seconds"
    sleep 5
done
sleep 20
docker exec "$prefix-app" pkill -f '[e]ve:update:sde' || setup_fail "no import process to interrupt"
log "killed the import 20 seconds into seeding"
wait_serving 1800 || defect "SeAT did not start after the interrupted import"
app_logs | grep -q 'Restored the previous EVE static data' \
    || defect "the previous static data was not restored"
app_logs | grep -q 'SeAT keeps the previously imported static data' \
    || defect "no warning that the previous static data was kept"
counts_after=$(sde_counts)
[ "$counts_after" = "$counts_before" ] \
    || defect "static-data counts changed: $counts_before -> $counts_after"
left=$(db "SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name LIKE 'appbox\_sde\_prev\_%'")
[ "$left" = 0 ] || defect "$left static-data copies were left behind"
log "previous data kept ($counts_after), SeAT serves: $(app_serves)"

echo "--- entrypoint log (last container)"
app_logs | tail -n 25
echo "RESULT: PASS"
