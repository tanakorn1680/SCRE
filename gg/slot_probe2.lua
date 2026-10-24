-- slot_probe.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- เป้าหมาย: หาตำแหน่ง 11 slots ของโรงงาน "โดยไม่พึ่ง anchor สามค่า" (1698928035;-1501685376;1952795914)
-- หลักการ (ข้อเท็จจริงจากผลรัน valuemap_probe2 + โค้ดสคริปต์ v9):
--   * value ของแต่ละวัตถุดิบ (V) อ่านได้จากโหนดแมปของมัน ([A+0x10] โดย A เป็นที่ที่ [A]=ID และ [A+8]=ID)
--   * slot ของโรงงานคือ dword ที่ "เก็บ V ของไอเท็มที่ผลิตอยู่" (สคริปต์ผู้ใช้สแกนหา dword ที่เท่ากับ V ใกล้ base)
--   => ค้น V ทั้ง 11 ค่าทั่วหน่วยความจำ แล้วหา "กลุ่ม" ที่ V หลายตัวอยู่ใกล้กัน = บล็อก slot
--   (โหนดแมปของ 9 วัตถุดิบก็มี V อยู่ห่างกัน >= 0x20 จึงจะโผล่เป็นกลุ่มด้วย: ดูระยะห่างแยกกันได้)
-- ข้อสำคัญ: สมมติฐานว่า slot แต่ละช่องเก็บ V ของไอเท็มตัวเอง ณ ตอนนั้น ; ถ้าผู้ใช้เปลี่ยนไอเท็มในโรงงานไว้แล้ว
--   ค่าใน slot อาจเป็น V ของไอเท็มอื่น ให้รันตอนโรงงานเป็นค่าเดิมของเกม (ยังไม่เปลี่ยนไอเท็ม)
-- วิธีใช้: เปิดเกม เข้าเมือง เปิดโรงงานดูสักครั้ง -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ slot_probe.txt
-- v2: (ก) Step 5 ตรวจตามกลไกของสคริปต์ผู้ใช้จริง: หา baseAddr (กลุ่ม 3 ค่า -> refine 1952795914) แล้วดู V ในช่วง
--      baseAddr..+0x2EE0 (3000 dword) เพราะ slot อาจกระจายห่างกันเกิน GAP ; (ข) กลุ่มที่ห่างกันทีละ 0x20 ถูกติดป้าย
--      "น่าจะโหนดแมป" และไม่ถูกดัมพ์ก่อนกลุ่มอื่น ; (ค) ดัมพ์ทนต่อ dword ที่อ่านไม่ได้

local TEST_STEPS = 40        -- เดินทดสอบเลือกโหนดแมปที่ถูกตัว
local MAX_HITS   = 40        -- ผลค้น identity ต่อไอเท็ม
local MAX_V_HITS = 400       -- ผลค้น V ต่อไอเท็ม
local GAP        = 128       -- ระยะ (ไบต์) ระหว่างผลค้นสองตัวที่ยังนับเป็นกลุ่มเดียวกัน
local MIN_ITEMS  = 4         -- กลุ่มต้องมีไอเท็มต่างกันอย่างน้อยกี่ชนิดจึงรายงาน
local RANGES     = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS

local START = {
  { 267176888,   "metal" },
  { 2090874750,  "wood" },
  { -1270634091, "plastic" },
  { 274276185,   "seeds" },
  { -1369888960, "Mineral" },
  { 1570439054,  "chemicals" },
  { 144394935,   "textiles" },
  { 1807545838,  "sugar and spices" },
  { 260292831,   "glass" },
  { 1658060491,  "animal feed" },
  { -181617693,  "electrical components" },
}

local HEXD = "0123456789ABCDEF"
local function hex(n)
  if n == 0 then return "0" end
  local s = ""
  while n > 0 do
    local d = n % 16
    s = HEXD:sub(d + 1, d + 1) .. s
    n = (n - d) / 16
  end
  return s
end
local function hex8(n) local s = hex(n); return string.rep("0", 8 - #s) .. s end
local function u32(v) if v < 0 then return v + 4294967296 end return v end
local function s32(v) if v >= 2147483648 then return v - 4294967296 end return v end
local function ptrAt(w, i) return u32(w[i]) + (u32(w[i + 1]) % 16777216) * 4294967296 end

local function readWords(addr, n)
  local req = {}
  for i = 0, n - 1 do req[#req + 1] = { address = addr + i * 4, flags = gg.TYPE_DWORD } end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local w = {}
  for i = 1, #res do
    if res[i].value == nil then return nil end
    w[i] = u32(tonumber(res[i].value))
  end
  return w
end

local function readLoose(addr, n)   -- เหมือน readWords แต่ dword ที่อ่านไม่ได้ = false (ไม่ทิ้งทั้งชุด)
  local req = {}
  for i = 0, n - 1 do req[#req + 1] = { address = addr + i * 4, flags = gg.TYPE_DWORD } end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local w = {}
  for i = 1, #res do
    local v = res[i].value
    if v ~= nil then w[i] = u32(tonumber(v)) else w[i] = false end
  end
  return w
end

local function testWalk(N, maxSteps)
  local steps, seen = 0, {}
  while steps < maxSteps do
    if N == 0 or seen[N] then break end
    local w = readWords(N, 8)
    if not w or w[3] ~= w[5] then break end
    seen[N] = true
    steps = steps + 1
    N = ptrAt(w, 1)
  end
  return steps
end

local out = {}
local function emit(s) out[#out + 1] = s end

-- ── Step 1: อ่าน V ปัจจุบันของแต่ละวัตถุดิบ (เลือกโหนดที่เดินลิสต์ต่อได้ยาวที่สุด) ──
local items = {}   -- { name, id, V }
emit("value (V) ปัจจุบันของแต่ละวัตถุดิบ: ชื่อ | ID | V | เดินทดสอบได้")
for _, s in ipairs(START) do
  gg.setRanges(RANGES)
  gg.clearResults()
  gg.searchNumber(tostring(s[1]), gg.TYPE_DWORD)
  local cnt = gg.getResultsCount()
  local best = nil
  if cnt > 0 then
    local res = gg.getResults(math.min(cnt, MAX_HITS))
    for _, r in ipairs(res) do
      local w = readWords(r.address, 6)
      if w and w[3] == u32(s[1]) then
        local len = testWalk(r.address - 8, TEST_STEPS)
        if not best or len > best.len then best = { V = w[5], len = len } end
      end
    end
  end
  gg.clearResults()
  if best and best.len >= 20 then
    items[#items + 1] = { name = s[2], id = u32(s[1]), V = best.V }
    emit(s[2] .. "\t" .. u32(s[1]) .. "\t" .. best.V .. "\t" .. best.len)
  else
    emit(s[2] .. "\t" .. u32(s[1]) .. "\t(อ่าน V ไม่สำเร็จ)\t" .. (best and best.len or 0))
  end
end

if #items < 4 then
  gg.alert("อ่านค่า V ได้น้อยเกินไป (" .. #items .. "/11)\nเปิดโรงงานในเกมแล้วรันใหม่")
  os.exit()
end

-- ── Step 2: ค้นแต่ละ V ทั่วหน่วยความจำ รวมผลทั้งหมด ──
local hits = {}   -- { addr, name, V }
emit("")
emit("จำนวนที่ค้นเจอของ V แต่ละตัว (ชื่อ | V | เจอกี่ที่ | อ่านมากี่ที่)")
for _, it in ipairs(items) do
  gg.setRanges(RANGES)
  gg.clearResults()
  gg.searchNumber(tostring(s32(it.V)), gg.TYPE_DWORD)
  local cnt = gg.getResultsCount()
  local got = 0
  if cnt > 0 then
    local res = gg.getResults(math.min(cnt, MAX_V_HITS))
    for _, r in ipairs(res) do
      hits[#hits + 1] = { addr = r.address, name = it.name, V = it.V }
      got = got + 1
    end
  end
  gg.clearResults()
  emit(it.name .. "\t" .. it.V .. "\t" .. cnt .. "\t" .. got)
end

table.sort(hits, function(a, b) return a.addr < b.addr end)

-- ── Step 3: จัดกลุ่มผลค้นที่อยู่ใกล้กัน (ห่างกันไม่เกิน GAP) ──
local runs = {}
local cur = nil
for _, h in ipairs(hits) do
  if cur and h.addr - cur.last <= GAP then
    cur.list[#cur.list + 1] = h
    cur.last = h.addr
  else
    cur = { first = h.addr, last = h.addr, list = { h } }
    runs[#runs + 1] = cur
  end
end
for _, r in ipairs(runs) do
  local set, n = {}, 0
  for _, h in ipairs(r.list) do
    if not set[h.name] then set[h.name] = true; n = n + 1 end
  end
  r.distinct = n
  r.span = r.last - r.first
end
local good = {}
for _, r in ipairs(runs) do if r.distinct >= MIN_ITEMS then good[#good + 1] = r end end
table.sort(good, function(a, b)
  if a.distinct ~= b.distinct then return a.distinct > b.distinct end
  return a.span < b.span
end)

-- ติดป้ายกลุ่มที่ผลค้นห่างกันทีละ 0x20 เกือบทั้งหมด = โหนดแมปของวัตถุดิบ (V ที่ N+0x18) ไม่ใช่ slot
for _, r in ipairs(good) do
  local g20 = 0
  for i = 2, #r.list do if r.list[i].addr - r.list[i - 1].addr == 0x20 then g20 = g20 + 1 end end
  r.mapLike = (#r.list >= 4 and g20 >= #r.list - 2)
end

emit("")
emit("กลุ่มที่มีไอเท็มต่างกัน >= " .. MIN_ITEMS .. " ชนิด: " .. #good .. " กลุ่ม (จากทั้งหมด " .. #runs .. " กลุ่ม)")
for gi, r in ipairs(good) do
  r.no = gi
  emit("")
  emit("== กลุ่ม " .. gi .. " | เริ่ม 0x" .. hex(r.first) .. " | ไอเท็มต่างกัน " .. r.distinct ..
       " | ครอบคลุม 0x" .. hex(r.span) .. " ไบต์ | จำนวนผลค้น " .. #r.list ..
       (r.mapLike and " | น่าจะโหนดแมป (ห่างกันทีละ 0x20)" or "") .. " ==")
  local prev = nil
  for _, h in ipairs(r.list) do
    emit("+0x" .. hex(h.addr - r.first) .. "\t0x" .. hex(h.addr) .. "\t" .. h.name .. "\t(ห่างจากตัวก่อนหน้า " ..
         (prev and ("0x" .. hex(h.addr - prev)) or "-") .. ")")
    prev = h.addr
  end
end

-- ── Step 4: ดัมพ์ dword รอบกลุ่มที่ดีที่สุด 3 กลุ่ม (ดูโครงสร้างรอบ ๆ) ──
local isV = {}
for _, it in ipairs(items) do isV[it.V] = it.name end
local dumpList = {}
for _, r in ipairs(good) do
  if not r.mapLike and #dumpList < 3 then dumpList[#dumpList + 1] = r end
end
for _, r in ipairs(dumpList) do
  local from = r.first - 32
  local count = math.min(160, math.floor((r.last - from) / 4) + 10)
  local w = readLoose(from, count)
  emit("")
  emit("== ดัมพ์รอบกลุ่ม " .. r.no .. " (เริ่ม 0x" .. hex(from) .. " = กลุ่ม-0x20) offset จากเริ่มกลุ่ม | ค่า hex | ชื่อถ้าเป็น V ==")
  if w then
    for i = 1, #w do
      local off = from + (i - 1) * 4 - r.first
      local offs = (off < 0) and ("-0x" .. hex(-off)) or ("+0x" .. hex(off))
      emit(offs .. "\t" .. (w[i] and hex8(w[i]) or "????????") .. "\t" .. (w[i] and isV[w[i]] or ""))
    end
  else
    emit("(อ่านไม่ได้)")
  end
end

-- ── Step 5: ตรวจตามกลไกสคริปต์ผู้ใช้: หา baseAddr แล้วดู V ในช่วง baseAddr..+0x2EE0 (สคริปต์ผู้ใช้สแกน 3000 dword) ──
local WIN_BACK, WIN_FWD = 0x100, 0x2EE0 + 0x100
emit("")
emit("ตัวยึดเดิม: ค้นกลุ่ม 1698928035;-1501685376;1952795914 แล้ว refine 1952795914 (เหมือนสคริปต์ผู้ใช้)")
gg.setRanges(RANGES)
gg.clearResults()
gg.searchNumber("1698928035;-1501685376;1952795914", gg.TYPE_DWORD)
local gcnt = gg.getResultsCount()
local anchors = {}
if gcnt > 0 then
  gg.refineNumber("1952795914", gg.TYPE_DWORD)
  local rc = gg.getResultsCount()
  if rc > 0 then
    for _, r in ipairs(gg.getResults(math.min(rc, 20))) do anchors[#anchors + 1] = r.address end
  end
end
gg.clearResults()
emit("ผลค้นกลุ่ม: " .. gcnt .. " ค่า | ตำแหน่ง 1952795914 หลัง refine: " .. #anchors .. " ที่")
for ai, a in ipairs(anchors) do
  local seen, n, lines = {}, 0, {}
  for _, h in ipairs(hits) do
    local d = h.addr - a
    if d >= -WIN_BACK and d <= WIN_FWD then
      lines[#lines + 1] = ((d < 0) and ("-0x" .. hex(-d)) or ("+0x" .. hex(d))) .. "\t0x" .. hex(h.addr) .. "\t" .. h.name
      if not seen[h.name] then seen[h.name] = true; n = n + 1 end
    end
  end
  emit("")
  emit("== ตัวยึด " .. ai .. " @0x" .. hex(a) .. " | ไอเท็มที่เจอ V ในช่วง " .. n .. "/" .. #items .. " | ผลค้นในช่วง " .. #lines .. " ==")
  for _, l in ipairs(lines) do emit(l) end
end
if #anchors == 0 then
  emit("(ไม่เจอตัวยึด: เปิดโรงงานในเกมแล้วรันใหม่ หรือเกมอาจอัปเดตจนค่าเปลี่ยน — ผลกลุ่มจาก Step 3 ยังใช้ได้)")
end

local text = table.concat(out, "\n")
local where = "(เขียนไฟล์ไม่ได้)"
local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
for i = 1, 3 do
  if dirs[i] then
    local ok, f = pcall(io.open, dirs[i] .. "/slot_probe.txt", "w")
    if ok and f then
      f:write(text .. "\n")
      f:close()
      where = dirs[i] .. "/slot_probe.txt"
      break
    end
  end
end
gg.alert("อ่าน V ได้ " .. #items .. "/11 | กลุ่มที่น่าสนใจ " .. #good .. " กลุ่ม\n\nไฟล์: " .. tostring(where))
