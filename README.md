# GPSqr – GPS-Position als QR-Code (EdgeTX)

Telemetrie-Skript für monochrome EdgeTX-Funken (128×64), das die letzte GPS-Position des Modells als QR-Code (`geo:lat,lon`) anzeigt. Handy-Kamera drauf halten, und die Karten-App öffnet den Punkt.

Neu geschrieben nach der Idee von [alufers/edgetx-gps-qrcode](https://github.com/alufers/edgetx-gps-qrcode), weil das Original auf schwachen Funken wie der Jumper T-Lite einfriert oder keinen Speicher mehr hat.

## Dateien für die SD-Karte

Eine davon nach `SCRIPTS/TELEMETRY/` kopieren:

| Datei | Wofür |
|---|---|
| `dist/GPSqr.lua` | Normalbetrieb, LCD-Funken (z. B. Jumper T-Lite) |
| `dist/GPSqrT.lua` | Testmodus: Beispiel-Koordinaten, kein Modell/GPS nötig |
| `dist/GPSqrI.lua` | Normalbetrieb für OLED-Funken (z. B. Jumper T14) |

Die Dateien sind minifiziert, weil das beim Laden auf der Funke RAM spart. Die lesbare Quelle liegt in `src/GPSqr.lua`.

## Installation

1. Datei aus `dist/` nach `SCRIPTS/TELEMETRY/` kopieren.
2. Im Modell unter *Telemetrie* die Sensoren suchen lassen, sodass ein Sensor `GPS` existiert (entfällt beim Testmodus).
3. Unter *Bildschirme* (Display) einen Bildschirm vom Typ *Skript* mit `GPSqr` (bzw. `GPSqrT`/`GPSqrI`) anlegen.

## Testmodus

`GPSqrT` zeigt Beispiel-Koordinaten (Berlin) an. Diese wandern minimal, sodass der QR-Code alle 15 s neu berechnet wird. So lässt sich prüfen, ob die Funke dabei flüssig bleibt, und der Code kann mit dem Handy gescannt werden. Für den echten Einsatz den Bildschirm wieder auf `GPSqr` stellen.

## Ohne GPS-Signal

- **Kein Sensor `GPS`:** Anzeige „No GPS sensor / Please discover“.
- **Sensor da, aber keine Daten:** Anzeige „No GPS data yet“.
- **GPS ohne Fix:** Manche Flugcontroller senden dann 0/0. In dem Fall erscheint ein QR-Code für `geo:0.000000,0.000000`.

## Was anders ist als im Original

| | Original | GPSqr |
|---|---|---|
| Größter einzelner Aufruf | ~820 000 Lua-Befehle | ~20 000 Lua-Befehle |
| Berechnung | alles in einem Aufruf | ~130 kleine Schritte, verteilt auf ein paar Sekunden |
| Zusätzlicher RAM beim Rechnen | ~59 KB | ~5 KB |
| QR-Größe für Koordinaten | 29×29 (Version 3) | 25×25 (Version 2) |
| Matrix | Tabelle pro Pixel, Bits als `"0"`/`"1"`-Strings | eine Zahl pro Zeile (1 Bit pro Pixel) |
| Reed-Solomon | Lookup-Tabellen im RAM | ohne Tabellen |

Gemessen in Lua 5.2 auf dem Mac (64-bit). Auf der Funke sind die absoluten Werte kleiner, das Verhältnis sollte aber ähnlich sein.

Während der neue Code berechnet wird, bleibt der alte sichtbar, und unten steht `QR xx%`.

## Anpassen

Einstellungen stehen oben in `src/GPSqr.lua`:

- `STEP_ROWS` (Standard 4): Arbeit pro Aufruf. Läuft es zu ruckelig, auf 2 senken. Jeder Schritt wird dann kleiner, der Code ist aber langsamer fertig.
- `REFRESH` (Standard 15 s): wie oft der Code höchstens neu erzeugt wird.

Danach die Dateien in `dist/` neu erzeugen (braucht Node.js):

```bash
./build.sh
```

## Testen am Rechner

```bash
python3 -m venv .venv && .venv/bin/pip install lupa zxing-cpp pillow
.venv/bin/python test/test_qr.py dist/GPSqr.lua
```

Das Skript läuft dabei in Lua 5.2 mit nachgebauten EdgeTX-Funktionen (auch ohne String-Methoden wie `s:byte()`, die EdgeTX nicht hat). Der gezeichnete Code wird mit zxing dekodiert und für fünf Testkoordinaten geprüft.
