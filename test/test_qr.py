import sys, lupa.lua52 as L52, zxingcpp
from PIL import Image

STUB = r'''
LCD_W, LCD_H, SMLSIZE, INVERS = 128, 64, 0, 1
debug.setmetatable("", nil) -- wie EdgeTX: keine String-Methoden (s:byte() geht nicht)
T = 0
rects = {}
GPS = {lat=0, lon=0}
lcd = { clear=function() rects = {} end,
  drawFilledRectangle=function(x,y,w,h,f) rects[#rects+1]={x,y,w,h} end,
  drawText=function() end, drawPoint=function() end }
function getFieldInfo() return {id=1} end
function getValue() return GPS end
function getTime() return T end
counts = {}
function measured(f)
  local c = 0
  debug.sethook(function() c = c + 1 end, "", 1)
  f()
  debug.sethook()
  return c
end
'''

def run(path, lat, lon):
    lua = L52.LuaRuntime()
    lua.execute(STUB)
    lua.execute(f"GPS = {{lat={lat}, lon={lon}}}")
    src = open(path).read().replace("local TEST       = true", "local TEST       = false")  # Testmodus aus
    script = lua.execute(src)
    script.init()
    measured = lua.globals().measured
    calls, maxc, total = 0, 0, 0
    measured(script.background)
    # run once (requests QR), then loop bg+run until no "QR" job
    for it in range(2000):
        c1 = measured(script.run); c2 = measured(script.background)
        calls += 2; maxc = max(maxc, c1, c2); total += c1 + c2
        lua.execute("T = T + 2")
        # finished when rects present and stable
        if it > 3 and len(lua.globals().rects) > 20:
            # render one more run to capture full picture
            lua.globals().rects  # noop
            nrect = len(lua.globals().rects)
            if getattr(run, "_prev", None) == nrect: break
            run._prev = nrect
    run._prev = None
    rects = list(lua.globals().rects.values())
    img = Image.new("L", (128, 64), 255)
    for r in rects:
        x, y, w, h = int(r[1]), int(r[2]), int(r[3]), int(r[4])
        for xx in range(x, x + w):
            for yy in range(y, y + h):
                if 0 <= xx < 128 and 0 <= yy < 64: img.putpixel((xx, yy), 0)
    big = img.resize((128 * 8, 64 * 8), Image.NEAREST)
    res = zxingcpp.read_barcodes(big)
    return calls, maxc, total, [r.text for r in res], big

if __name__ == "__main__":
    path = sys.argv[1]
    for i, (lat, lon) in enumerate([(52.520008, 13.404954), (-33.868820, 151.209290), (-89.999999, -179.999999), (0.0, 0.0), (37.23333456, -115.8083333)]):
        calls, maxc, total, txt, img = run(path, lat, lon)
        img.save(f"out{i}.png")
        print(f"calls={calls:4d} max_instr/call={maxc:8d} total_instr={total:9d} decoded={txt}")
