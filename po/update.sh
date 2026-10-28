#!/bin/bash
# Regenerates the translation template (po/eduwifi-watchdog.pot) from the sources
# and merges new or changed messages into every po/*.po file.
# Run it after changing any user-visible message, then translate the new entries.
set -e
PROG=eduwifi-watchdog
cd "$(dirname "$0")"

xgettext -L Shell --from-code=UTF-8 -k -ksay -kerr -klog -kgettext -kask:2 \
    --add-comments=TRANSLATORS --package-name=$PROG \
    --msgid-bugs-address="https://github.com/eduardomillan/$PROG/issues" \
    -o shell.pot ../$PROG.sh ../install.sh
xgettext -L Desktop --from-code=UTF-8 -o desktop.pot ../$PROG.desktop.in
msgcat --use-first shell.pot desktop.pot -o $PROG.pot
rm -f shell.pot desktop.pot

for lang in $(grep -v '^#' LINGUAS); do
    if [ -f "$lang.po" ]; then
        msgmerge --quiet --update --backup=none "$lang.po" $PROG.pot
    else
        msginit --no-translator --locale="$lang" -i $PROG.pot -o "$lang.po"
    fi
done
echo "Updated $PROG.pot and: $(grep -v '^#' LINGUAS | tr '\n' ' ')"
