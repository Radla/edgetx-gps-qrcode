#!/bin/sh
# Erzeugt die minifizierten Dateien fuer die SD-Karte (spart RAM beim Laden).
#   dist/GPSqr.lua  - normaler Betrieb
#   dist/GPSqrT.lua - Testmodus mit Beispiel-Koordinaten
#   dist/GPSqrI.lua - fuer OLED-Displays (invertiert)
# Braucht Node.js; luamin wird beim ersten Mal nach .build/ installiert.
set -e
cd "$(dirname "$0")"
if [ ! -d .build/node_modules/luamin ]; then
  npm install --silent --no-save --prefix .build luamin@1.0.4
fi
mkdir -p dist
node - <<'EOF'
const fs = require('fs');
const luamin = require('./.build/node_modules/luamin');
const src = fs.readFileSync('src/GPSqr.lua', 'utf8');
const variants = {
  'GPSqr.lua':  src,
  'GPSqrT.lua': src.replace(/^local TEST       = false/m, 'local TEST       = true'),
  'GPSqrI.lua': src.replace(/^local INVERTED   = false/m, 'local INVERTED   = true'),
};
for (const [name, code] of Object.entries(variants)) {
  if (code === src && name !== 'GPSqr.lua') throw new Error('Schalter nicht gefunden: ' + name);
  fs.writeFileSync('dist/' + name, '-- GPSqr (minifiziert, Quelle: src/GPSqr.lua)\n' + luamin.minify(code) + '\n');
}
EOF
ls -l dist
