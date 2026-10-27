#!/bin/sh
# Builds CGRBAR, installs it to /Applications and starts it. The packaged copy
# in build/ is removed afterwards, so only the installed app remains.
set -eu

cd "$(dirname "$0")/.."

./Scripts/package_app.sh

pkill -x CGRBAR 2>/dev/null || true
rm -rf /Applications/CGRBAR.app
cp -R build/CGRBAR.app /Applications/
rm -rf build/CGRBAR.app

open /Applications/CGRBAR.app
echo "Installed /Applications/CGRBAR.app"
