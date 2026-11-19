# Releasing eveseat 5.0.1-6

5.0.1-6 is the released 5.0.1-5 image
(`repo.cylo.net/eveseat@sha256:5fdb93052c1d27f8e30722fbdf337632340ce0f0902771fb239d93ba5f6783f6`)
with `/entrypoint.sh` and the release tree's `AppboxSdeUpdater.php` replaced
(see `Dockerfile.release`).

Why: CCP's EVE static data build 3720952 (19 November 2026) has a type name of
161 characters (type 96196), longer than the `VARCHAR(150)` SeAT's
`InvTypesSeeder` creates, so strict MariaDB rejects the import. The import runs
from `/entrypoint.sh` whenever a container is created, its failure was fatal,
and the seeders rebuild their tables outside any transaction. The 5.0.1-5
canary (seat.nullsec, 19 November 2026) restarted in a loop with `invTypes`
left at 50,000 of 53,941 rows. The monthly scheduled import (1st of the month,
00:00) would have left the same partial table on running installs.

- `/entrypoint.sh` patches the persisted tree on every start, only where the
  files are exactly the known versions: it installs the fixed updater over the
  5.0.1-2 Appbox updater (sha256 `c440615b...`) and widens the seeder's
  `typeName` to 255 characters (also for installs whose plugins replaced
  `vendor/eveseat` and run SeAT's own SDE command). The release marker stays
  the same, because re-applying a release replaces `vendor/` and would remove
  customer-installed plugins.
- When the import still fails or times out, `/entrypoint.sh` restores the
  updater's copies of the static-data tables and starts SeAT on the previous
  data. Only an install without any static data still stops with an error.
- `AppboxSdeUpdater.php` copies the 10 static-data tables before an import,
  puts them back when the import fails (and at the start of the next run after
  an interrupted one), and logs the database driver's message, such as
  `Data too long for column 'typeName'`, instead of only the exception class.

The gate is `release/verify-sde-overlay.sh`: the overlay checks of
`verify-overlay.sh` (with `.php` overlay files checked as mode 644 and
`php -l`), and `release/sde-import-test.sh` against CCP's current static data
on the new image (must pass: fresh import, recreate without re-import, and an
import killed while seeding keeps the previous tables) and on the base image
(must fail with the import error). It needs internet on the builder.

Build, gate and push from a clean checkout of branch `sde-import-fix`:

    CYLO_BUILD_TMP=<scratch dir> release/build-on-builder.sh release

# Releasing eveseat 5.0.1-5 (previous release)

5.0.1-5 is the released 5.0.1-4 image
(`repo.cylo.net/eveseat@sha256:7474bd7a45eb159fec1727b2f77953e3a71920c07a662b584ca4a8307c768a86`)
with PHP's own files copied in from
`repo.cylo.net/php-artifacts:docker-library-php-8.2.36-fpm-bookworm`, the way
5.0.1-3 replaced PHP in 5.0.1-2 (see `Dockerfile.release`). PHP 8.2.36
carries the php-src security fixes of 19 November 2026. The 5.0.1-4 startup
fixes and SeAT are unchanged.

- The artifact recipe is docker-library/php 8f7cce49 `8.2/bookworm/fpm`,
  which differs from the 8.2.35 recipe only in the PHP version, URL and
  sha256 lines; `FROM` stays pinned to the same debian:bookworm-slim digest.
- It was built directly on the dedicated builder (builder.grant) from the
  pushed recipe commit, made into the artifact with `make-artifact.sh`, gated
  with `verify-artifact.sh` and pushed. `artifact.env` records the
  provenance.
- The gate is `release/verify-image.sh` again, with 5.0.1-4 as the base.
- `release/build-on-builder.sh` now targets builder.grant (port 12246) and
  builds with `--builder default`.

Build, gate and push from a clean checkout of branch `php-8.2.36`:

    CYLO_BUILD_TMP=<scratch dir> release/build-on-builder.sh release

# Releasing eveseat 5.0.1-4 (previous release)

5.0.1-4 is the released 5.0.1-3 image
(`repo.cylo.net/eveseat@sha256:57f8ee40267ae1ab29f39d1210c8812b5964e2a6ab926b5130731228cc331f76`)
with two startup files replaced (see `Dockerfile.release`):

- `scripts/Entrypoint.sh` -> `/entrypoint.sh`. MariaDB waits are bounded by
  `MYSQL_WAIT_TIMEOUT_SECONDS` (default 900, was a fixed 180 seconds). The
  post-start Appbox callback no longer dies when its MariaDB wait runs out:
  it keeps waiting for MariaDB, Redis and the web server for up to
  `CALLBACK_READY_TIMEOUT_SECONDS` (default 3600) and then sends the callback.
- `rootfs/etc/cont-init.d/00-permissions` -> `/etc/cont-init.d/00-permissions`.
  It only changes ownership that is not already appbox's, instead of a
  recursive chown of /home/appbox that rewrote every inode before s6 started
  the services.

Why: on busy nodes the s6 cont-init chown took minutes, so the supervised
MariaDB answered after the callback's 180 second wait had already expired.
The callback subshell then exited and the instance stayed "updating" in the
API although SeAT was up (261698, 261879, 255637 on 21 October 2026).

Build, gate and push from a clean checkout of branch `seat-db-wait`:

    CYLO_BUILD_TMP=<scratch dir> release/build-on-builder.sh release

The gate is `release/verify-overlay.sh`. Besides the registry precondition
(base digest readable, 5.0.1-4 MANIFEST_UNKNOWN, checked before and after the
tests) it checks that the 5.0.1-3 layers are unchanged, that each new layer
holds only its overlay file, that the image config is identical, that the
files equal the committed ones, and that PHP 8.2.35 still serves a multipart
upload through nginx and php-fpm. It then runs
`release/slow-db-callback-test.sh` three times in parallel (about 15
minutes): on the new image with the s6 services held 240 seconds (must pass),
on the new image held 100 seconds with `MYSQL_WAIT_TIMEOUT_SECONDS=30` (must
pass through the retry), and on the 5.0.1-3 base image held 240 seconds (must
fail with the lost callback). The test needs no internet: it builds a
migrated SeAT install on an internal Docker network and sends the callback to
a local endpoint that checks the test token.

# Releasing eveseat 5.0.1-3 (previous release)

The image is the deployed 5.0.1-2 digest with PHP's own files copied in from
`repo.cylo.net/php-artifacts:docker-library-php-8.2.35-fpm-bookworm` (see `Dockerfile.release`).

## 1. The patched PHP

On 21 October 2026 Docker Hub's `php:8.2.35-fpm-bookworm` tag was an empty image index
(no linux/amd64 image), so PHP 8.2.35 was built here instead, from the
unmodified docker-library/php `8.2/bookworm/fpm` recipe with `FROM` pinned by digest:

1. `release/php-artifact/node-build.sh` built `release/php-artifact/docker-library/`
   on a low-load Cylo node (legacy builder, `--cpu-shares 256`), saved the
   image as a gzip'd docker archive and recorded its sha256.
2. The archive was copied node -> builder with `scp -3` and its sha256 was
   checked again on the builder before `docker load`.
3. `release/php-artifact/make-artifact.sh` turned the loaded image into a
   FROM-scratch artifact (the whole /usr/local tree plus /php-artifact/
   README, SHA256SUMS, SYMLINKS, Dockerfile, runtime packages, php -v/-m).
4. `release/php-artifact/verify-artifact.sh` gated it (PHP version, libraries,
   php-fpm -t, multipart upload, artifact contents identical to the image,
   tag absent) and it was pushed, then pinned by digest in `Dockerfile.release`.

`release/php-artifact/artifact.env` records the provenance (recipe commit,
base digest, PHP tarball sha256 and signing key, node, image ID, archive
sha256).

## 2. Build, gate, push

From a clean checkout of branch `php-multipart-fix` on the Mac:

    git pull --ff-only origin php-multipart-fix
    CYLO_BUILD_TMP=<scratch dir> release/build-on-builder.sh release

`release` builds `repo.cylo.net/eveseat:5.0.1-3` on builder1 from the pushed
commit, runs `release/verify-image.sh` and pushes only if the gate passes,
then prints the pushed digest. The gate checks the deployed layers and image
config are unchanged apart from PHP_VERSION and the PHP files, the PHP files
match the pinned artifact, php and php-fpm report 8.2.35, no library is
missing, `php -m` and `php-fpm -m` equal the deployed image, `php-fpm -t`
and `nginx -t` pass, a PHP page served through the image's nginx and
php-fpm parses a multipart upload, PHP's built-in server parses one too, and
the tag is definitively absent from the registry (MANIFEST_UNKNOWN).
