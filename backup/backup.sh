#!/bin/sh
# Periodic dump of the pools collection.
#
# Only pools. It is the sole collection that cannot be rebuilt: players and
# day_leaders are re-derivable from the NHL API by the scraper jobs, and
# `played` is a leftover from 2022 that nothing reads. Dumping only pools keeps
# the archive at ~7 MB instead of ~25 MB, which is what makes it cheap enough
# to keep two a day and copy off the host.
#
# Sleeps until the next scheduled hour rather than running on an interval, so
# the backup times do not drift every time the container restarts.
set -eu

DB=${BACKUP_DB:-hockeypool}
COLLECTION=${BACKUP_COLLECTION:-pools}
URI=${BACKUP_MONGO_URI:-mongodb://mongo:27017}
OUT=${BACKUP_OUT:-/backups}
KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}
HOURS=${BACKUP_HOURS:-04 16}

dump_once() {
    ts=$(date +%F-%H%M)
    part="$OUT/.$COLLECTION-$ts.gz.part"
    final="$OUT/$COLLECTION-$ts.gz"

    # Dump to .part and rename only on success. A shell redirect would create
    # the destination before mongodump runs, so a stopped database or a full
    # disk would leave a 0-byte file sitting there looking like a backup.
    if mongodump --uri="$URI" --db="$DB" --collection="$COLLECTION" \
                 --gzip --archive="$part" 2>&1; then
        mv "$part" "$final"
        echo "[backup] wrote $final ($(wc -c < "$final") bytes)"
    else
        rm -f "$part"
        echo "[backup] FAILED at $ts — no file written" >&2
        return 1
    fi

    # Retention. Only ever matches this collection's own dumps, so a second
    # backup writing into the same directory is not collateral damage.
    find "$OUT" -maxdepth 1 -name "$COLLECTION-*.gz" -mtime "+$KEEP_DAYS" -print -delete
}

seconds_until_next() {
    now=$(date +%s)
    best=""
    for h in $HOURS; do
        t=$(date -d "today $h:00" +%s)
        if [ "$t" -le "$now" ]; then
            t=$(date -d "tomorrow $h:00" +%s)
        fi
        if [ -z "$best" ] || [ "$t" -lt "$best" ]; then
            best=$t
        fi
    done
    echo $((best - now))
}

# `backup.sh once` runs a single dump and exits — how you verify the setup
# without waiting for a scheduled hour, and how you take an ad-hoc dump before
# a risky change.
if [ "${1:-}" = "once" ]; then
    dump_once
    exit $?
fi

echo "[backup] $DB.$COLLECTION -> $OUT at $HOURS daily, keeping $KEEP_DAYS days"
while true; do
    wait_for=$(seconds_until_next)
    echo "[backup] next dump in $((wait_for / 3600))h $((wait_for % 3600 / 60))m"
    sleep "$wait_for"
    # A failure must not kill the loop, or one unreachable-mongo moment ends
    # every future backup silently. restart: unless-stopped would not help —
    # the container would be running and doing nothing.
    dump_once || true
done
