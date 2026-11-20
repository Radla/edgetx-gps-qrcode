# GPSqr – GPS-Position als QR-Code (EdgeTX)

Telemetrie-Skript für monochrome EdgeTX-Funken (128×64), das die letzte GPS-Position des Modells als QR-Code (`geo:lat,lon`) anzeigt. Handy-Kamera drauf halten, und die Karten-App öffnet den Punkt.

Neu geschrieben nach der Idee von [alufers/edgetx-gps-qrcode](https://github.com/alufers/edgetx-gps-qrcode), weil das Original auf langsamen Funken wie der Jumper T-Lite einfriert.

## Was anders ist

| | Original | GPSqr (dieses) |
|---|---|---|
| Größter einzelner Aufruf | ~820 000 Lua-Befehle | ~11 000 Lua-Befehle |
| Berechnung | alles in einem Aufruf | ~130 kleine Schritte, verteilt auf ein paar Sekunden |
| QR-Größe für Koordinaten | 29×29 (Version 3) | 25×25 (Version 2) |
| Bits | Strings aus `"0"`/`"1"` | Zahlen |
| Reed-Solomon | Lookup-Tabellen im RAM | ohne Tabellen |

(Gemessen in Lua 5.2 auf dem Mac mit `test/test_qr.py`; auf der Funke selbst nicht gemessen.)

Während der neue Code berechnet wird, bleibt der alte sichtbar, und unten steht `QR xx%`.

## Installation

1. `GPSqr.lua` nach `SCRIPTS/TELEMETRY/` auf die SD-Karte kopieren.
2. Im Modell unter *Telemetrie* die Sensoren suchen lassen, sodass ein Sensor `GPS` existiert.
3. Unter *Bildschirme* (Display) einen Bildschirm vom Typ *Skript* mit `GPSqr` anlegen.

Für OLED-Funken (z. B. Jumper T14) oben im Skript `INVERTED = true` setzen. Die T-Lite hat ein LCD, dort bleibt es auf `false`.

Läuft es noch zu ruckelig, `STEP_ROWS` von 4 auf 2 senken. Jeder Schritt wird dann kleiner, der Code ist aber langsamer fertig.

## Testmodus (ohne Modell und GPS)

Oben im Skript `TEST = true` setzen. Dann braucht das Skript keinen Sensor und zeigt Beispiel-Koordinaten (Berlin) an. Diese wandern minimal, sodass der QR-Code alle 15 s neu berechnet wird. So lässt sich prüfen, ob die Funke dabei flüssig bleibt, und der Code kann mit dem Handy gescannt werden. Für den echten Einsatz wieder `TEST = false` setzen.

## Ohne GPS-Signal

- **Kein Sensor `GPS`:** Anzeige „No GPS sensor / Please discover“.
- **Sensor da, aber keine Daten:** Anzeige „No GPS data yet“.
- **GPS ohne Fix:** Manche Flugcontroller senden dann 0/0. In dem Fall erscheint ein QR-Code für `geo:0.000000,0.000000`.

## Testen am Rechner

```bash
python3 -m venv .venv && .venv/bin/pip install lupa zxing-cpp pillow
.venv/bin/python test/test_qr.py GPSqr.lua
```

Das Skript läuft dabei in Lua 5.2 mit nachgebauten EdgeTX-Funktionen. Der gezeichnete Code wird mit zxing dekodiert und für fünf Testkoordinaten geprüft.
