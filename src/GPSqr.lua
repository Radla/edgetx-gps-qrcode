-- GPSqr: zeigt die GPS-Position des Modells als QR-Code (geo:lat,lon).
-- Telemetrie-Skript fuer monochrome EdgeTX-Funken (128x64).
--
-- Neu geschrieben nach der Idee von github.com/alufers/edgetx-gps-qrcode,
-- damit es auch auf schwachen Funken (z. B. Jumper T-Lite) laeuft:
--  * Der QR-Code wird in vielen kleinen Schritten berechnet (ein Schritt pro
--    Aufruf), statt alles in einem Aufruf.
--  * Jede Matrixzeile ist eine einzige Zahl (ein Bit pro Pixel), das spart RAM.
--  * Die kleinste passende QR-Version wird genutzt (25x25 statt 29x29).
--  * Keine Lookup-Tabellen fuer Reed-Solomon.

local INVERTED   = false -- true fuer OLED-Displays (z. B. Jumper T14)
local REFRESH    = 1500  -- neu erzeugen fruehestens alle 15 s (10-ms-Ticks)
local STEP_ROWS  = 4     -- Arbeit pro Aufruf; kleiner = fluessiger, aber langsamer
local TEST       = false -- true: feste Beispiel-Koordinaten, kein Modell/Sensor noetig.
                         -- Sie wandern leicht, damit alle 15 s neu gerechnet wird.

local floor, bxor, band, bnot, extract = math.floor, bit32.bxor, bit32.band, bit32.bnot, bit32.extract

-- QR-Versionen 1-3, Fehlerkorrektur L, je ein Block (max. 29 Pixel = passt in 32 Bit)
local VDATA  = {19, 34, 55} -- Daten-Codewoerter
local VEC    = {7, 10, 15}  -- Fehlerkorrektur-Codewoerter
local VALIGN = {0, 18, 22}  -- Position des Ausrichtungsmusters

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

-- Bit x in Zeile y einer Zeilen-Tabelle setzen/loeschen
local function setbit(t, x, y, d)
  local v, b = t[y + 1], 2 ^ x
  if d then
    if extract(v, x) == 0 then v = v + b end
  elseif extract(v, x) == 1 then
    v = v - b
  end
  t[y + 1] = v
end

local function draw_format(set, n, mask)
  local data = 8 + mask -- Level L = 01
  local rem = data
  for _ = 1, 10 do rem = bxor(rem * 2, floor(rem / 512) * 0x537) end
  local bits = bxor(data * 1024 + rem, 0x5412)
  local function g(i) return extract(bits, i) == 1 end
  for i = 0, 5 do set(8, i, g(i)) end
  set(8, 7, g(6)); set(8, 8, g(7)); set(7, 8, g(8))
  for i = 9, 14 do set(14 - i, 8, g(i)) end
  for i = 0, 7 do set(n - 1 - i, 8, g(i)) end
  for i = 8, 14 do set(8, n - 15 + i, g(i)) end
end

local function mask_hit(m, x, y)
  if m == 0 then return (x + y) % 2 == 0
  elseif m == 1 then return y % 2 == 0
  elseif m == 2 then return x % 3 == 0
  elseif m == 3 then return (x + y) % 3 == 0
  elseif m == 4 then return (floor(x / 3) + floor(y / 2)) % 2 == 0
  elseif m == 5 then return x * y % 2 + x * y % 3 == 0
  elseif m == 6 then return (x * y % 2 + x * y % 3) % 2 == 0
  end
  return ((x + y) % 2 + x * y % 3) % 2 == 0
end

local function popcount(v)
  local c = 0
  while v ~= 0 do v = band(v, v - 1); c = c + 1 end
  return c
end

-- Strafpunkte einer Linie (Tabelle a[1..n]): lange Laeufe und Finder-aehnliche Muster
local function line_pen(a, n)
  local p, run, last = 0, 0, -1
  for i = 1, n do
    if a[i] == last then
      run = run + 1
    else
      if run >= 5 then p = p + run - 2 end
      run, last = 1, a[i]
    end
  end
  if run >= 5 then p = p + run - 2 end
  for s = 1, n - 6 do
    if a[s] == 1 and a[s + 1] == 0 and a[s + 2] == 1 and a[s + 3] == 1
        and a[s + 4] == 1 and a[s + 5] == 0 and a[s + 6] == 1 then
      local before, after = true, true
      for k = 1, 4 do
        if a[s - k] == 1 then before = false end
        if a[s + 6 + k] == 1 then after = false end
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
local qr = nil    -- fertiger Code: eine Zahl pro Zeile, Bit x = Pixel x dunkel
local qr_n = 0
local qr_error = false

local function start_job(text)
  local len = #text
  local ver
  for v = 1, 3 do
    if VDATA[v] >= len + 2 then ver = v; break end
  end
  if not ver then qr_error = true; return end
  qr_error = false

  -- Byte-Modus: 4 Bit Modus, 8 Bit Laenge, Daten, 4 Bit Ende -> alles um 4 Bit versetzt
  local cw = {0x40 + floor(len / 16)}
  local prev = len % 16
  for k = 1, len do
    local b = string.byte(text, k) -- EdgeTX kennt kein text:byte()
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
  job = {phase = 1, ver = ver, n = n, cw = cw, ndata = #cw, deg = VEC[ver],
         k = 1, right = n - 1, bit = 0, mask = 0, i = 0, pen = 0, dark = 0,
         best = 1e9, bestmask = 0, final = false, done = 0}
  job.total = 3 + floor(#cw / STEP_ROWS) + floor(n / (2 * STEP_ROWS))
              + 17 * (floor((n - 1) / STEP_ROWS) + 1)
end

local function step_job(j)
  local n, ph = j.n, j.phase

  if ph == 1 then -- Generatorpolynom
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
    j.g, j.rem = g, {}
    for i = 1, deg do j.rem[i] = 0 end
    j.phase = 2

  elseif ph == 2 then -- Reed-Solomon-Rest, ein paar Bytes pro Aufruf
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
      j.phase = 3
    end

  elseif ph == 3 then -- Funktionsmuster: F = Funktionspixel, D = dunkel
    local F, D = {}, {}
    for y = 1, n do F[y] = 0; D[y] = 0 end
    local function fset(x, y, d) setbit(F, x, y, true); setbit(D, x, y, d) end
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
    j.F, j.D = F, D
    j.phase = 4

  elseif ph == 4 then -- Datenbits im Zickzack einsetzen
    local F, D, cw, total = j.F, j.D, j.cw, #j.cw * 8
    for _ = 1, STEP_ROWS do
      local right = j.right
      if right < 1 then break end
      if right == 6 then right = 5 end
      local upward = floor((right + 1) / 2) % 2 == 0
      for vert = 0, n - 1 do
        local y = upward and (n - 1 - vert) or vert
        for x = right, right - 1, -1 do
          if extract(F[y + 1], x) == 0 and j.bit < total then
            local bit = j.bit
            if extract(cw[floor(bit / 8) + 1], 7 - bit % 8) == 1 then setbit(D, x, y, true) end
            j.bit = bit + 1
          end
        end
      end
      j.right = right - 2
    end
    if j.right < 1 then
      j.cw = nil
      j.W, j.R, j.C = {}, {}, {}
      j.phase = 5
    end

  elseif ph == 5 then -- Maske anwenden, ein paar Zeilen pro Aufruf
    local W, F, D, m = j.W, j.F, j.D, j.mask
    local y1 = math.min(j.i + STEP_ROWS - 1, n - 1)
    for y = j.i, y1 do
      local mr = 0
      for x = 0, n - 1 do
        if mask_hit(m, x, y) then mr = mr + 2 ^ x end
      end
      W[y + 1] = bxor(D[y + 1], band(mr, bnot(F[y + 1])))
    end
    j.i = y1 + 1
    if j.i >= n then
      draw_format(function(x, y, d) setbit(W, x, y, d) end, n, m)
      j.i, j.pen, j.dark = 0, 0, 0
      if j.final then
        qr, qr_n = W, n
        job = nil
        collectgarbage()
        return
      end
      j.phase = 6
    end

  else -- Strafpunkte: Zeile k, Spalte k, 2x2-Bloecke, Anteil dunkel
    local W, R, C = j.W, j.R, j.C
    local k1 = math.min(j.i + STEP_ROWS - 1, n - 1)
    local full, inner = 2 ^ n - 1, 2 ^ (n - 1) - 1
    for k = j.i, k1 do
      local a = W[k + 1]
      for i = 1, n do
        R[i] = extract(a, i - 1)
        C[i] = extract(W[i], k)
      end
      local p = line_pen(R, n) + line_pen(C, n)
      if k < n - 1 then
        local v = bnot(bxor(a, W[k + 2]))           -- gleich wie darunter
        local h = bnot(bxor(a, floor(a / 2)))       -- gleich wie rechts daneben
        p = p + 3 * popcount(band(v, floor(v / 2), h, inner))
      end
      j.dark = j.dark + popcount(band(a, full))
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
      j.phase = 5
    end
  end
end

local function step()
  if job then
    job.done = job.done + 1
    step_job(job)
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
    for y = 0, qr_n - 1 do
      local row, x = qr[y + 1], 0
      while x < qr_n do
        if extract(row, x) == 1 then
          local x0 = x
          while x < qr_n and extract(row, x) == 1 do x = x + 1 end
          lcd.drawFilledRectangle(o + x0 * s, o + y * s, (x - x0) * s, s)
        else
          x = x + 1
        end
      end
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
