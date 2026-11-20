-- GPSqr: zeigt die GPS-Position des Modells als QR-Code (geo:lat,lon).
-- Telemetrie-Skript fuer monochrome EdgeTX-Funken (128x64).
--
-- Neu geschrieben nach der Idee von github.com/alufers/edgetx-gps-qrcode,
-- damit es auch auf langsamen Funken (z. B. Jumper T-Lite) nicht einfriert:
--  * Der QR-Code wird in vielen kleinen Schritten berechnet (ein Schritt pro
--    Aufruf), statt alles in einem Aufruf.
--  * Bits werden als Zahlen statt als "0"/"1"-Strings verarbeitet.
--  * Die kleinste passende QR-Version wird genutzt (25x25 statt 29x29).
--  * Keine Lookup-Tabellen fuer Reed-Solomon, kaum Speicher.

local INVERTED   = false -- true fuer OLED-Displays (z. B. Jumper T14)
local REFRESH    = 1500  -- neu erzeugen fruehestens alle 15 s (10-ms-Ticks)
local STEP_ROWS  = 4     -- Arbeit pro Aufruf; kleiner = fluessiger, aber langsamer
local TEST       = false -- true: feste Beispiel-Koordinaten, kein Modell/Sensor noetig.
                         -- Sie wandern leicht, damit alle 15 s neu gerechnet wird.

local floor, bxor = math.floor, bit32.bxor

-- QR-Versionen 1-4, Fehlerkorrektur L, je ein Block
local VDATA  = {19, 34, 55, 80} -- Daten-Codewoerter
local VEC    = {7, 10, 15, 20}  -- Fehlerkorrektur-Codewoerter
local VALIGN = {0, 18, 22, 26}  -- Position des Ausrichtungsmusters

-- Multiplikation im GF(256), ohne Tabellen
local function gmul(a, b)
  local r = 0
  while b > 0 do
    if b % 2 == 1 then r = bxor(r, a) end
    a = a * 2
    if a > 255 then a = bxor(a, 0x11D) end
    b = floor(b / 2)
  end
  return r
end

local function format_bits(mask)
  local data = 8 + mask -- Level L = 01
  local rem = data
  for _ = 1, 10 do rem = bxor(rem * 2, floor(rem / 512) * 0x537) end
  return bxor(data * 1024 + rem, 0x5412)
end

local function draw_format(set, n, bits)
  local function g(i) return floor(bits / 2 ^ i) % 2 == 1 end
  for i = 0, 5 do set(8, i, g(i)) end
  set(8, 7, g(6)); set(8, 8, g(7)); set(7, 8, g(8))
  for i = 9, 14 do set(14 - i, 8, g(i)) end
  for i = 0, 7 do set(n - 1 - i, 8, g(i)) end
  for i = 8, 14 do set(8, n - 15 + i, g(i)) end
end

local MASKS = {
  [0] = function(x, y) return (x + y) % 2 == 0 end,
  function(x, y) return y % 2 == 0 end,
  function(x, y) return x % 3 == 0 end,
  function(x, y) return (x + y) % 3 == 0 end,
  function(x, y) return (floor(x / 3) + floor(y / 2)) % 2 == 0 end,
  function(x, y) return x * y % 2 + x * y % 3 == 0 end,
  function(x, y) return (x * y % 2 + x * y % 3) % 2 == 0 end,
  function(x, y) return ((x + y) % 2 + x * y % 3) % 2 == 0 end,
}

-- Strafpunkte einer Zeile/Spalte: lange Laeufe (N1) und Finder-aehnliche Muster (N3)
local function line_pen(w, start, step, n)
  local p, run, last, idx = 0, 0, -1, start
  for _ = 1, n do
    local c = w[idx]
    if c == last then
      run = run + 1
    else
      if run >= 5 then p = p + run - 2 end
      run, last = 1, c
    end
    idx = idx + step
  end
  if run >= 5 then p = p + run - 2 end
  for s = 0, n - 7 do
    local b = start + s * step
    if w[b] == 1 and w[b + step] == 0 and w[b + 2 * step] == 1 and w[b + 3 * step] == 1
        and w[b + 4 * step] == 1 and w[b + 5 * step] == 0 and w[b + 6 * step] == 1 then
      local before, after = true, true
      for k = 1, 4 do
        if s - k >= 0 and w[b - k * step] == 1 then before = false end
        if s + 6 + k < n and w[b + (6 + k) * step] == 1 then after = false end
      end
      if before or after then p = p + 40 end
    end
  end
  return p
end

---------------------------------------------------------------------------
-- Erzeugung als Zustandsmaschine: jeder Aufruf von step() macht wenig Arbeit
---------------------------------------------------------------------------
local job = nil   -- laufende Erzeugung
local qr = nil    -- fertiger Code: Liste von Laeufen (y*4096 + x*64 + laenge)
local qr_n = 0
local qr_error = false

local function start_job(text)
  local len = #text
  local ver
  for v = 1, 4 do
    if VDATA[v] >= len + 2 then ver = v; break end
  end
  if not ver then qr_error = true; return end
  qr_error = false

  -- Byte-Modus: 4 Bit Modus, 8 Bit Laenge, Daten, 4 Bit Ende -> alles um 4 Bit versetzt
  local cw = {0x40 + floor(len / 16)}
  local prev = len % 16
  for k = 1, len do
    local b = text:byte(k)
    cw[#cw + 1] = prev * 16 + floor(b / 16)
    prev = b % 16
  end
  cw[#cw + 1] = prev * 16
  local pad = 0xEC
  while #cw < VDATA[ver] do
    cw[#cw + 1] = pad
    pad = (pad == 0xEC) and 0x11 or 0xEC
  end

  local n = ver * 4 + 17
  job = {phase = "gen", ver = ver, n = n, cw = cw, ndata = #cw, deg = VEC[ver],
         k = 1, right = n - 1, bit = 0, mask = 0, i = 0, pen = 0, dark = 0,
         best = 1e9, bestmask = 0, final = false, done = 0}
  job.total = 2 + floor(#cw / STEP_ROWS) + floor(n / (2 * STEP_ROWS)) + 1
              + 9 * (floor(n / STEP_ROWS) + 1) + 8 * (floor(n / STEP_ROWS) + 1) + 1
end

local phases = {}

phases.gen = function(j) -- Generatorpolynom
  local deg, g, root = j.deg, {}, 1
  for i = 1, deg - 1 do g[i] = 0 end
  g[deg] = 1
  for _ = 1, deg do
    for i = 1, deg do
      g[i] = gmul(g[i], root)
      if i < deg then g[i] = bxor(g[i], g[i + 1]) end
    end
    root = gmul(root, 2)
  end
  j.g = g
  j.rem = {}
  for i = 1, deg do j.rem[i] = 0 end
  j.phase = "ec"
end

phases.ec = function(j) -- Reed-Solomon-Rest, ein paar Bytes pro Aufruf
  local g, rem, deg = j.g, j.rem, j.deg
  local last = math.min(j.k + STEP_ROWS - 1, j.ndata)
  for k = j.k, last do
    local f = bxor(j.cw[k], rem[1])
    for i = 1, deg - 1 do rem[i] = bxor(rem[i + 1], gmul(g[i], f)) end
    rem[deg] = gmul(g[deg], f)
  end
  j.k = last + 1
  if j.k > j.ndata then
    for i = 1, deg do j.cw[#j.cw + 1] = rem[i] end
    j.g, j.rem = nil, nil
    j.phase = "base"
  end
end

phases.base = function(j) -- Funktionsmuster (2 = hell, 3 = dunkel)
  local n = j.n
  local base = {}
  for i = 1, n * n do base[i] = 0 end
  local function fset(x, y, d) base[y * n + x + 1] = d and 3 or 2 end
  for i = 0, n - 1 do fset(6, i, i % 2 == 0); fset(i, 6, i % 2 == 0) end
  local c = {3, 3, n - 4, 3, 3, n - 4}
  for f = 1, 5, 2 do
    for dy = -4, 4 do
      for dx = -4, 4 do
        local x, y = c[f] + dx, c[f + 1] + dy
        if x >= 0 and x < n and y >= 0 and y < n then
          local d = math.max(math.abs(dx), math.abs(dy))
          fset(x, y, d ~= 2 and d ~= 4)
        end
      end
    end
  end
  local a = VALIGN[j.ver]
  if a > 0 then
    for dy = -2, 2 do
      for dx = -2, 2 do
        fset(a + dx, a + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1)
      end
    end
  end
  draw_format(fset, n, 0) -- Platz reservieren
  fset(8, n - 8, true)
  j.base = base
  j.phase = "place"
end

phases.place = function(j) -- Datenbits im Zickzack einsetzen
  local n, base, cw, total = j.n, j.base, j.cw, #j.cw * 8
  for _ = 1, STEP_ROWS do
    local right = j.right
    if right < 1 then break end
    if right == 6 then right = 5 end
    local upward = floor((right + 1) / 2) % 2 == 0
    for vert = 0, n - 1 do
      local y = upward and (n - 1 - vert) or vert
      for x = right, right - 1, -1 do
        local i = y * n + x + 1
        if base[i] < 2 and j.bit < total then
          local bit = j.bit
          base[i] = floor(cw[floor(bit / 8) + 1] / 2 ^ (7 - bit % 8)) % 2
          j.bit = bit + 1
        end
      end
    end
    j.right = right - 2
  end
  if j.right < 1 then
    j.cw = nil
    j.work = {}
    j.phase = "mask"
  end
end

phases.mask = function(j) -- Maske anwenden, ein paar Zeilen pro Aufruf
  local n, base, work, m = j.n, j.base, j.work, MASKS[j.mask]
  local y1 = math.min(j.i + STEP_ROWS - 1, n - 1)
  for y = j.i, y1 do
    local i = y * n + 1
    for x = 0, n - 1 do
      local v = base[i]
      if v < 2 then
        if m(x, y) then v = 1 - v end
        work[i] = v
      else
        work[i] = v - 2
      end
      i = i + 1
    end
  end
  j.i = y1 + 1
  if j.i >= n then
    draw_format(function(x, y, d) work[y * n + x + 1] = d and 1 or 0 end, n, format_bits(j.mask))
    j.i, j.pen, j.dark = 0, 0, 0
    j.phase = j.final and "finish" or "penalty"
  end
end

phases.penalty = function(j) -- Strafpunkte: Zeile k, Spalte k, 2x2-Bloecke
  local n, w = j.n, j.work
  local k1 = math.min(j.i + STEP_ROWS - 1, n - 1)
  for k = j.i, k1 do
    local p = line_pen(w, k * n + 1, 1, n) + line_pen(w, k + 1, n, n)
    local row = k * n + 1
    for x = 0, n - 1 do
      local c = w[row + x]
      j.dark = j.dark + c
      if k < n - 1 and x < n - 1 and c == w[row + x + 1]
          and c == w[row + x + n] and c == w[row + x + n + 1] then
        p = p + 3
      end
    end
    j.pen = j.pen + p
  end
  j.i = k1 + 1
  if j.i >= n then
    local pen = j.pen + floor(math.abs(j.dark * 20 / (n * n) - 10)) * 10
    if pen < j.best then j.best, j.bestmask = pen, j.mask end
    j.i = 0
    if j.mask < 7 then
      j.mask = j.mask + 1
    else
      j.mask, j.final = j.bestmask, true
    end
    j.phase = "mask"
  end
end

phases.finish = function(j) -- in Laeufe zum Zeichnen umwandeln
  local n, w, runs = j.n, j.work, {}
  for y = 0, n - 1 do
    local x = 0
    while x < n do
      if w[y * n + x + 1] == 1 then
        local s = x
        while x < n and w[y * n + x + 1] == 1 do x = x + 1 end
        runs[#runs + 1] = y * 4096 + s * 64 + (x - s)
      else
        x = x + 1
      end
    end
  end
  qr, qr_n = runs, n
  job = nil
  collectgarbage()
end

local function step()
  if job then
    job.done = job.done + 1
    phases[job.phase](job)
  end
end

---------------------------------------------------------------------------
-- EdgeTX-Schnittstelle
---------------------------------------------------------------------------
local gps_id = nil
local has_gps = false
local lat, lon = "", ""
local qr_lat, qr_lon = nil, nil
local last_refresh = 0

local function init()
  if TEST then gps_id = -1; return end
  local fi = getFieldInfo("GPS")
  gps_id = fi and fi.id or nil
end

local function background()
  if TEST then
    local t = floor(getTime() / 100)
    lat = string.format("%.6f", 52.520008 + t * 0.000001)
    lon = string.format("%.6f", 13.404954 - t * 0.000001)
    has_gps = true
  elseif gps_id then
    local gps = getValue(gps_id)
    if type(gps) == "table" and gps.lat and gps.lon then
      lat = string.format("%.6f", gps.lat)
      lon = string.format("%.6f", gps.lon)
      has_gps = true
    end
  end
  step()
end

local function run()
  lcd.clear()
  if not gps_id then
    lcd.drawText(20, 22, "No GPS sensor")
    lcd.drawText(20, 34, "Please discover")
    return 0
  end
  if not has_gps then
    lcd.drawText(20, 28, "No GPS data yet")
    return 0
  end

  local now = getTime()
  if not job and (lat ~= qr_lat or lon ~= qr_lon)
      and (not qr or now - last_refresh >= REFRESH) then
    qr_lat, qr_lon, last_refresh = lat, lon, now
    start_job("geo:" .. lat .. "," .. lon)
  end
  step() -- zusaetzlicher Schritt, solange der Bildschirm sichtbar ist

  local text_x = 66
  if qr then
    local s = floor((LCD_H - 4) / qr_n)
    local o = floor((LCD_H - qr_n * s) / 2)
    text_x = o * 2 + qr_n * s + 2
    if INVERTED then lcd.drawFilledRectangle(0, 0, text_x - 2, LCD_H) end
    for r = 1, #qr do
      local v = qr[r]
      local y = floor(v / 4096)
      local x = floor(v / 64) % 64
      lcd.drawFilledRectangle(o + x * s, o + y * s, (v % 64) * s, s)
    end
  else
    lcd.drawText(4, 28, qr_error and "QR error" or "QR...")
  end

  lcd.drawText(text_x, 2, "Lat", SMLSIZE)
  lcd.drawText(text_x, 10, lat, SMLSIZE)
  lcd.drawText(text_x, 20, "Lon", SMLSIZE)
  lcd.drawText(text_x, 28, lon, SMLSIZE)
  if job then
    lcd.drawText(text_x, 44, string.format("QR %d%%", math.min(99, floor(job.done * 100 / job.total))), SMLSIZE)
  end
  lcd.drawText(text_x, 54, string.format("%ds ago", floor((now - last_refresh) / 100)), SMLSIZE)
  return 0
end

return {init = init, background = background, run = run}
