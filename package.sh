#!/bin/bash
# Packages a ready-to-install bundle for another Mac (no Swift toolchain needed there):
#   dist/Zquig.zip  ->  Zquig.app, install.sh
# Set UNIVERSAL=1 for an arm64 + x86_64 build; otherwise the target Mac needs Apple Silicon.
set -euo pipefail
cd "$(dirname "$0")"

./build_app.sh
OUT=dist/Zquig
rm -rf "$OUT" dist/Zquig.zip
mkdir -p "$OUT"
cp -R dist/Zquig.app "$OUT/"

cat > "$OUT/install.sh" <<'SH'
#!/bin/bash
# Installs Zquig.app into /Applications.
set -euo pipefail
cd "$(dirname "$0")"
if [ -w /Applications ]; then cp -R Zquig.app /Applications/; else sudo cp -R Zquig.app /Applications/; fi
xattr -cr /Applications/Zquig.app   # clear the download quarantine flag (app is not notarized)
echo "Installed /Applications/Zquig.app"
SH
chmod +x "$OUT/install.sh"

(cd dist && ditto -c -k --norsrc --noextattr --keepParent Zquig Zquig.zip)
echo "Created dist/Zquig.zip"
