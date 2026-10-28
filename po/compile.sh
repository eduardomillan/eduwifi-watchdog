#!/bin/bash
# Compiles the translations (po/*.po) and the translated menu entry into OUTDIR.
# Usage: po/compile.sh OUTDIR     (e.g. "po/compile.sh build" to test from a checkout)
set -e
PROG=eduwifi-watchdog
OUT=${1:?Usage: $0 OUTDIR}
cd "$(dirname "$0")"
mkdir -p "$OUT" 2>/dev/null || true
OUT=$(cd "$OLDPWD" && mkdir -p "$OUT" && cd "$OUT" && pwd)

command -v msgfmt >/dev/null || { echo "msgfmt not found (install the gettext package)" >&2; exit 1; }

for lang in $(grep -v '^#' LINGUAS); do
    mkdir -p "$OUT/locale/$lang/LC_MESSAGES"
    msgfmt --check -o "$OUT/locale/$lang/LC_MESSAGES/$PROG.mo" "$lang.po"
done
msgfmt --desktop --template="../$PROG.desktop.in" -d . -o "$OUT/$PROG.desktop"
echo "Translations compiled into $OUT"
