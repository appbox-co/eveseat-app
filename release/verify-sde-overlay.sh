#!/usr/bin/env bash
# Release gate for the EVE static-data fix (5.0.1-6): a previous release image
# (gate_base_ref in release/image.env) with only the files listed as
# gate_overlay_file=<repository path>:<image path> replaced. It is
# release/verify-overlay.sh with two changes: overlay files ending in .php are
# checked as mode 644 PHP files, and the regression test is
# release/sde-import-test.sh against CCP's current static data.
#
# Usage: release/verify-sde-overlay.sh <image>     (on the builder, needs internet)
#
# Exits 0 only when:
# - the authenticated registry can read the base digest and definitively
#   reports the release tag as absent (MANIFEST_UNKNOWN), before and after
#   the tests;
# - the base image's layers are the start of the new image, one new layer per
#   overlay file holds only that file (plus unchanged parent directories),
#   and the image config (entrypoint, command, user, environment, labels,
#   volumes, ports, health check) is identical to the base;
# - each overlay file in the image is byte-identical to the committed file and
#   owned by root; scripts are mode 755 and pass bash -n, .php files are mode
#   644 and pass php -l;
# - PHP still reports gate_php_release_version and serves a multipart upload
#   through the image's nginx and php-fpm;
# - release/sde-import-test.sh passes on the new image (fresh install imports
#   CCP's current static data, a recreated container starts without
#   re-importing, and an import killed mid-way keeps the previous tables and
#   SeAT still starts), and FAILS on the base image with the import error,
#   which proves the test catches the defect.
set -euo pipefail
LC_ALL=C
export LC_ALL

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

release_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(dirname "$release_dir")
for key in cylo_build_image cylo_build_release_ref gate_base_ref gate_php_release_version; do
    value=$(sed -n "s/^$key=//p" "$release_dir/image.env")
    case "$value" in ''|*[!A-Za-z0-9._/:@-]*) fail "release/image.env: bad or missing $key" ;; esac
    printf -v "$key" '%s' "$value"
done
mapfile -t overlay_files < <(sed -n 's/^gate_overlay_file=//p' "$release_dir/image.env")
[ "${#overlay_files[@]}" -gt 0 ] || fail "release/image.env lists no gate_overlay_file"
for entry in "${overlay_files[@]}"; do
    case "$entry" in
        /*|*..*|*[!A-Za-z0-9._/:-]*|*:*:*) fail "bad gate_overlay_file $entry" ;;
        *:/*) ;;
        *) fail "bad gate_overlay_file $entry" ;;
    esac
    [ -f "$repo_dir/${entry%%:*}" ] || fail "missing ${entry%%:*}"
done

[ "$#" -eq 1 ] || fail "usage: $0 <image>"
image_ref=$1
[ "$image_ref" = "$cylo_build_release_ref" ] || fail "unexpected image reference $image_ref"
for tool in docker curl jq tar sha256sum cmp diff sort; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

work_dir=$(mktemp -d)
test_pids=()
cleanup() {
    for pid in "${test_pids[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

in_image() {
    local image=$1
    shift
    docker run --rm --platform linux/amd64 --network none --user 0:0 \
        -v "$release_dir:/release:ro" --entrypoint "$1" "$image" "${@:2}"
}

echo "== Gate: $image_ref (base $gate_base_ref)"

registry=${cylo_build_release_ref%%/*}
repository_and_tag=${cylo_build_release_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || fail "release reference has no tag"
base_digest=${gate_base_ref#*@}
registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS --max-time 60 -K - -o "$work_dir/registry-body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}
registry_check() {
    local status
    status=$(registry_get /v2/) || fail "registry unreachable"
    [ "$status" = 200 ] || fail "registry API check returned HTTP $status"
    status=$(registry_get "/v2/$repository/manifests/$base_digest") || fail "registry unreachable"
    [ "$status" = 200 ] || fail "registry read of the base digest returned HTTP $status; state is indeterminate"
    status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
    case "$status" in
        200) fail "$cylo_build_release_ref already exists in the registry; refusing to replace it" ;;
        404)
            grep -q 'MANIFEST_UNKNOWN' "$work_dir/registry-body" \
                || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$work_dir/registry-body")"
            echo "base digest readable; $cylo_build_release_ref is definitively absent (MANIFEST_UNKNOWN)"
            ;;
        *) fail "registry returned HTTP $status for $cylo_build_release_ref" ;;
    esac
}
echo "== Registry"
registry_check

echo "== Image identity"
docker image inspect "$image_ref" >/dev/null 2>&1 || fail "$image_ref is not a local image"
docker image inspect "$gate_base_ref" >/dev/null 2>&1 \
    || docker pull -q --platform linux/amd64 "$gate_base_ref" >/dev/null \
    || fail "cannot read the base image $gate_base_ref"
[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")" = linux/amd64 ] \
    || fail "image is not linux/amd64"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$gate_base_ref" | sed '/^$/d' > "$work_dir/base-layers"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" | sed '/^$/d' > "$work_dir/image-layers"
base_layer_count=$(wc -l < "$work_dir/base-layers")
image_layer_count=$(wc -l < "$work_dir/image-layers")
head -n "$base_layer_count" "$work_dir/image-layers" | cmp -s - "$work_dir/base-layers" \
    || fail "the base image's layers are not the start of the new image"
[ "$((image_layer_count - base_layer_count))" -eq "${#overlay_files[@]}" ] \
    || fail "expected ${#overlay_files[@]} new layers, found $((image_layer_count - base_layer_count))"
echo "base layers ($base_layer_count) unchanged; ${#overlay_files[@]} new layers"
for field in '{{json .Config.Entrypoint}}' '{{json .Config.Cmd}}' '{{json .Config.User}}' \
    '{{json .Config.WorkingDir}}' '{{json .Config.ExposedPorts}}' '{{json .Config.Volumes}}' \
    '{{json .Config.Healthcheck}}' '{{json .Config.StopSignal}}' '{{json .Config.Shell}}' \
    '{{json .Config.Env}}' '{{json .Config.Labels}}' '{{json .Config.OnBuild}}'; do
    [ "$(docker image inspect --format "$field" "$image_ref")" = "$(docker image inspect --format "$field" "$gate_base_ref")" ] \
        || fail "image config $field differs from the base image"
done
echo "entrypoint, command, user, environment, labels, ports, volumes and health check identical to the base"

echo "== New layer contents"
docker save -o "$work_dir/image.tar" "$image_ref"
mkdir "$work_dir/save"
tar -xf "$work_dir/image.tar" -C "$work_dir/save" manifest.json
mapfile -t new_layers < <(jq -r '.[0].Layers[]' "$work_dir/save/manifest.json" | tail -n "${#overlay_files[@]}")
[ "${#new_layers[@]}" -eq "${#overlay_files[@]}" ] || fail "cannot find the new layers in docker save output"
expected_dirs=
index=0
for entry in "${overlay_files[@]}"; do
    target=${entry#*:}
    layer=${new_layers[$index]}
    index=$((index + 1))
    case "$layer" in *..*|/*) fail "unexpected layer path $layer" ;; esac
    tar -xf "$work_dir/image.tar" -C "$work_dir/save" "$layer"
    tar -tvf "$work_dir/save/$layer" > "$work_dir/layer.list"
    files=$(awk '$1 !~ /^d/ {print $NF}' "$work_dir/layer.list")
    [ "$files" = "${target#/}" ] || { cat "$work_dir/layer.list" >&2; fail "layer for $target holds more than that file"; }
    case "$target" in *.php) want_mode=-rw-r--r-- ;; *) want_mode=-rwxr-xr-x ;; esac
    awk -v want="${target#/}" -v mode="$want_mode" '$1 == mode && ($2 == "root/root" || $2 == "0/0") && $NF == want {found = 1}
        END {exit !found}' "$work_dir/layer.list" \
        || { cat "$work_dir/layer.list" >&2; fail "$target in its layer is not a $want_mode root:root file"; }
    expected_dirs="$expected_dirs $(awk '$1 ~ /^d/ {print $NF}' "$work_dir/layer.list" | tr '\n' ' ')"
    echo "layer $index: $(awk '{print $1, $2, $NF}' "$work_dir/layer.list" | tr '\n' ';')"
done
rm -f "$work_dir/image.tar"
for dir in $expected_dirs; do
    dir=/${dir%/}
    case "$dir" in *[!A-Za-z0-9._/-]*) fail "unexpected directory $dir" ;; esac
    base_stat=$(in_image "$gate_base_ref" stat -c '%a %u %g %F' "$dir")
    image_stat=$(in_image "$image_ref" stat -c '%a %u %g %F' "$dir")
    [ "$base_stat" = "$image_stat" ] || fail "directory $dir changed: $base_stat -> $image_stat"
    base_list=$(in_image "$gate_base_ref" ls -A "$dir")
    image_list=$(in_image "$image_ref" ls -A "$dir")
    [ "$base_list" = "$image_list" ] || fail "the entries in $dir changed"
done
echo "parent directories ($expected_dirs) unchanged"

echo "== Overlay files"
for entry in "${overlay_files[@]}"; do
    source=${entry%%:*}
    target=${entry#*:}
    want=$(sha256sum < "$repo_dir/$source" | cut -c1-64)
    got=$(in_image "$image_ref" sha256sum "$target" | cut -c1-64)
    [ "$want" = "$got" ] || fail "$target is not the committed $source"
    case "$target" in
        *.php)
            [ "$(in_image "$image_ref" stat -c '%a %U:%G' "$target")" = "644 root:root" ] \
                || fail "$target is not mode 644 root:root"
            in_image "$image_ref" php -l "$target" >/dev/null || fail "$target fails php -l"
            echo "$target = $source ($want), 644 root:root, php -l ok"
            ;;
        *)
            [ "$(in_image "$image_ref" stat -c '%a %U:%G' "$target")" = "755 root:root" ] \
                || fail "$target is not mode 755 root:root"
            in_image "$image_ref" bash -n "$target" || fail "$target fails bash -n"
            echo "$target = $source ($want), 755 root:root, bash -n ok"
            ;;
    esac
done

echo "== PHP"
php_versions=$(in_image "$image_ref" sh -c 'php -v | head -n 1; php-fpm -v | head -n 1')
printf '%s\n' "$php_versions"
printf '%s\n' "$php_versions" | sed -n 1p | grep -q "^PHP $gate_php_release_version (cli)" \
    || fail "php does not report $gate_php_release_version"
printf '%s\n' "$php_versions" | sed -n 2p | grep -q "^PHP $gate_php_release_version (fpm-fcgi)" \
    || fail "php-fpm does not report $gate_php_release_version"
in_image "$image_ref" sh /release/fpm-nginx-smoke.sh "$gate_php_release_version" \
    || fail "nginx -> php-fpm page or multipart upload failed"

echo "== Regression: EVE static-data import against CCP's current build (about 15-25 minutes)"
run_test() {
    local name=$1
    shift
    "$release_dir/sde-import-test.sh" "$@" > "$work_dir/test-$name.log" 2>&1
}
run_test new "$image_ref" & test_pids+=("$!")
run_test base "$gate_base_ref" & test_pids+=("$!")
results=()
for pid in "${test_pids[@]}"; do
    status=0
    wait "$pid" || status=$?
    results+=("$status")
done
test_pids=()
for name in new base; do
    echo "-- $name"
    cat "$work_dir/test-$name.log"
done
echo "exit codes: new=${results[0]} base=${results[1]}"
[ "${results[0]}" -eq 0 ] || fail "the new image failed the static-data test"
[ "${results[1]}" -eq 1 ] || fail "the test did not reproduce the import failure on the base image (exit ${results[1]})"
grep -q 'Data too long for column\|EVE SDE update failed\|EVE static-data update failed' "$work_dir/test-base.log" \
    || fail "the base image run did not show the import failure"
echo "defect reproduced on the base image and fixed in the new image"

echo "== Registry (again)"
registry_check

echo "PASS: $image_ref"
