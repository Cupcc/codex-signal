#!/bin/bash
set -eu
parent_pid="$1"
replacement="$2"
destination="$3"
receipt="$4"
staging="$5"
data_directory="$6"
backup="${replacement%.app}-previous.app"

fail() {
    printf 'failed\n' > "$receipt"
    /usr/bin/open 'https://github.com/Cupcc/codex-signal/releases/latest' || true
}

# Do not replace files while the old process owns the data-directory lock.
for ((attempt = 0; attempt < 60; attempt++)); do
    if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then break; fi
    /bin/sleep 1
done
if /bin/kill -0 "$parent_pid" 2>/dev/null; then
    fail
    /bin/rm -rf "$replacement"
    exit 1
fi

if ! /bin/mv "$destination" "$backup"; then
    fail
    /usr/bin/open "$destination" --args --data-dir "$data_directory" || true
    exit 1
fi
if ! /bin/mv "$replacement" "$destination"; then
    /bin/mv "$backup" "$destination" || true
    fail
    /usr/bin/open "$destination" --args --data-dir "$data_directory" || true
    exit 1
fi
if ! /usr/bin/open "$destination" --args --data-dir "$data_directory"; then
    /bin/mv "$destination" "$replacement" || true
    /bin/mv "$backup" "$destination" || true
    fail
    /usr/bin/open "$destination" --args --data-dir "$data_directory" || true
    exit 1
fi
printf 'success\n' > "$receipt"
# Keep the previous app beside the installation for recovery after launch.
/bin/rm -rf "$staging"
