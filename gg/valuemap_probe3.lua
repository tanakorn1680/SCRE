-- valuemap_probe3.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- เป้าหมาย: ไล่ "ทุกโหนด" ของแมป (ID -> value) โดยไม่ต้องรู้หัวลิสต์
-- เหตุผล (จากข้อมูล valuemap_probe2.txt ที่ตรวจแล้ว):
--   * โหนดที่เดินจาก metal ได้ 15,752 ตัว เรียงเป็นกลุ่มบักเก็ตของ libc++ unordered_map ที่ bucket_count = 25717
--     (id % 25717 ของโหนดที่ติดกันเป็นกลุ่มต่อเนื่อง 9,372 บักเก็ต ไม่มีบักเก็ตใดแตกกลุ่มเลย)
--   * ไอดีของสคริปต์ผู้ใช้ 52 ตัวที่ไม่อยู่ในลิสต์นั้น ไม่มีตัวใดมี id % 25717 ตรงกับบักเก็ตของโหนดที่เดินได้
--     (ถ้าไม่อยู่ในแมปนี้ ควรชนประมาณ 19 ตัว) -> จึงอยู่ในแมปเดียวกันแต่ "ก่อน" โหนด metal
-- วิธี: หา "ตารางบักเก็ต" (อาเรย์ 25717 พอยน์เตอร์; bucket[b] = พอยน์เตอร์ไปโหนด "ก่อนหน้า" โหนดแรกของบักเก็ต b)
--   แล้วใช้มันไล่ทุกบักเก็ต -> ได้ทุกโหนดโดยไม่ต้องรู้หัวลิสต์
-- พิเศษ: อ่าน qword ที่ N+0x18 (value ทั้ง 8 ไบต์) เพื่อตรวจว่า value ที่เคยอ่านเป็น dword คือครึ่งล่างของพอยน์เตอร์หรือไม่
--   แล้วอ่านหน่วยความจำที่พอยน์เตอร์นั้นของ 11 วัตถุดิบ (ถ้าอ่านได้)
-- วิธีใช้: เปิดเกม เข้าเมือง เปิดโรงงานดูสักครั้ง -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ valuemap_probe3.txt
-- ใช้เวลานานกว่ารอบก่อน (ค้นหน่วยความจำหลายรอบ + อ่านประมาณ 25,000 โหนด)

local BC          = 25717       -- bucket_count ที่ยืนยันจากข้อมูลรอบก่อน (เกม 1.83.3)
local SAMPLE_LEN  = 400         -- เดินจาก metal กี่โหนดเพื่อเก็บตัวอย่างหาตารางบักเก็ต
local TRY_TARGETS = 10          -- ลองค้นกี่พอยน์เตอร์เป้าหมาย
local NEED_MATCH  = 8           -- ต้องตรงกี่บักเก็ตตัวอย่างจึงถือว่าเจอตารางจริง
local MAX_HITS    = 50
local MAX_NODES   = 60000
local RANGES      = gg.REGION_C_ALLOC + gg.REGION_ANONYMOUS + gg.REGION_C_HEAP

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
local function u32(v) if v < 0 then return v + 4294967296 end return v end
local function strip(lo, hi) return lo + (hi % 16777216) * 4294967296 end   -- ตัดแท็กไบต์บนสุด
local function ptrAt(w, i) return strip(w[i], w[i + 1]) end

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

local out = {}
local function emit(s) out[#out + 1] = s end

local function writeOut()
  local text = table.concat(out, "\n")
  local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
  for i = 1, 3 do
    if dirs[i] then
      local ok, f = pcall(io.open, dirs[i] .. "/valuemap_probe3.txt", "w")
      if ok and f then
        f:write(text .. "\n")
        f:close()
        return dirs[i] .. "/valuemap_probe3.txt"
      end
    end
  end
  return nil
end

local function finish(msg)
  gg.clearResults()
  local where = writeOut()
  gg.alert(msg .. "\n\nไฟล์: " .. tostring(where))
  os.exit()
end

-- เดินสั้น ๆ ทดสอบว่าเป็นโหนดลิสต์จริง (hash==key ติดกัน)
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

-- ── Step 1: หาโหนด metal ที่เป็นโหนดลิสต์จริง ──
gg.setRanges(RANGES)
gg.clearResults()
gg.searchNumber(tostring(START[1][1]), gg.TYPE_DWORD)
local cnt = gg.getResultsCount()
local best = nil
if cnt > 0 then
  local res = gg.getResults(math.min(cnt, MAX_HITS))
  for _, r in ipairs(res) do
    local w = readWords(r.address, 6)
    if w and w[3] == u32(START[1][1]) then
      local len = testWalk(r.address - 8, 40)
      if not best or len > best.len then best = { N = r.address - 8, len = len } end
    end
  end
end
gg.clearResults()
if not best or best.len < 20 then
  emit("ไม่พบโหนด metal ที่เดินลิสต์ต่อได้ (ค้นเจอ " .. cnt .. " ที่) เปิดโรงงานในเกมแล้วรันใหม่")
  finish("ไม่พบโหนดเริ่มต้น")
end
emit("โหนด metal ที่ใช้: 0x" .. hex(best.N) .. " เดินทดสอบได้ " .. best.len)

-- ── Step 2: เดินตัวอย่าง เก็บ next ดิบ (ทั้ง 8 ไบต์) ──
local L = {}
do
  local N, seen = best.N, {}
  while #L < SAMPLE_LEN do
    if N == 0 or seen[N] then break end
    local w = readWords(N, 10)
    if not w or w[3] ~= w[5] then break end
    seen[N] = true
    L[#L + 1] = { N = N, nlo = w[1], nhi = w[2], key = w[5], b = w[5] % BC }
    N = ptrAt(w, 1)
  end
end
emit("โหนดตัวอย่าง " .. #L .. " ตัว")

-- เป้าหมาย: โหนด i (i>=3) ที่เป็นโหนดแรกของบักเก็ตตัวเอง (b ต่างจากโหนดก่อนหน้า)
-- bucket[b_i] = พอยน์เตอร์ไปโหนด i-1 = ค่าเดียวกับ next ของโหนด i-2
local E = {}
for i = 3, #L do
  if L[i].b ~= L[i - 1].b then
    E[#E + 1] = { b = L[i].b, plo = L[i - 2].nlo, phi = L[i - 2].nhi }
  end
end
emit("พอยน์เตอร์เป้าหมายสำหรับหาตารางบักเก็ต " .. #E .. " ตัว")
if #E < NEED_MATCH + 2 then
  emit("ตัวอย่างน้อยเกินไป")
  finish("ตัวอย่างโหนดน้อยเกินไป")
end

local function samePtr(w, e)
  return w and w[1] == e.plo and (w[2] % 16777216) == (e.phi % 16777216)
end

local function countMatches(B)
  local ok_, tot = 0, 0
  for _, e in ipairs(E) do
    if tot >= 24 then break end
    tot = tot + 1
    if samePtr(readWords(B + 8 * e.b, 2), e) then ok_ = ok_ + 1 end
  end
  return ok_, tot
end

local function searchPtr(lo, hi)
  gg.setRanges(RANGES)
  gg.clearResults()
  if hi < 2097152 then
    pcall(gg.searchNumber, string.format("%.0f", lo + hi * 4294967296), gg.TYPE_QWORD)
  else
    local bytes, d = {}, { lo, hi }
    for j = 1, 2 do
      local x = d[j]
      for _ = 1, 4 do
        bytes[#bytes + 1] = string.format("%02X", x % 256)
        x = math.floor(x / 256)
      end
    end
    pcall(gg.searchNumber, "h " .. table.concat(bytes, " "), gg.TYPE_BYTE)
  end
  local c = gg.getResultsCount()
  local res = {}
  if c > 0 then res = gg.getResults(math.min(c, MAX_HITS)) end
  gg.clearResults()
  return res, c
end

-- ── Step 3: หาตารางบักเก็ต ──
local base, baseInfo = nil, nil
local tries = 0
for ei = 1, #E do
  if base or tries >= TRY_TARGETS then break end
  local e = E[ei]
  tries = tries + 1
  gg.toast("ค้นพอยน์เตอร์เป้าหมาย " .. tries .. "/" .. TRY_TARGETS)
  local variants = { { e.plo, e.phi } }
  if (e.phi % 16777216) ~= e.phi then variants[2] = { e.plo, e.phi % 16777216 } end
  for _, v in ipairs(variants) do
    local res, c = searchPtr(v[1], v[2])
    emit("ค้นพอยน์เตอร์เป้าหมาย #" .. tries .. " (บักเก็ต " .. e.b .. ", hi=0x" .. hex(v[2]) .. "): เจอ " .. c .. " ที่")
    for _, r in ipairs(res) do
      local B = r.address - 8 * e.b
      if B > 0 then
        local ok_, tot = countMatches(B)
        if ok_ >= NEED_MATCH then
          base = B
          baseInfo = "ตรง " .. ok_ .. "/" .. tot .. " (จากพอยน์เตอร์ที่ " .. tries .. ")"
          break
        end
      end
    end
    if base then break end
  end
end
if not base then
  emit("ไม่พบตารางบักเก็ตที่ตรวจผ่าน (อาจเพราะเลย์เอาต์ต่างจากที่ตั้งสมมติฐาน เช่น bucket เก็บแท็กต่างกัน)")
  finish("ไม่พบตารางบักเก็ต ดูรายละเอียดในไฟล์")
end
emit("ตารางบักเก็ต: 0x" .. hex(base) .. " | " .. baseInfo)

-- ── Step 4: อ่านตารางบักเก็ตทั้งหมด ──
local entry = {}
local nonEmpty = 0
do
  local b = 0
  while b < BC do
    local top = math.min(b + 1000, BC)
    local req = {}
    for k = b, top - 1 do
      req[#req + 1] = { address = base + 8 * k, flags = gg.TYPE_DWORD }
      req[#req + 1] = { address = base + 8 * k + 4, flags = gg.TYPE_DWORD }
    end
    local ok, res = pcall(gg.getValues, req)
    if not ok or not res then emit("อ่านตารางบักเก็ตพังที่บักเก็ต " .. b); break end
    for k = b, top - 1 do
      local lo = u32(tonumber(res[(k - b) * 2 + 1].value))
      local hi = u32(tonumber(res[(k - b) * 2 + 2].value))
      if lo ~= 0 or hi ~= 0 then
        entry[k] = strip(lo, hi)
        nonEmpty = nonEmpty + 1
      end
    end
    b = top
    gg.toast("อ่านตารางบักเก็ต " .. b .. "/" .. BC)
  end
end
emit("บักเก็ตที่ไม่ว่าง: " .. nonEmpty)

-- โหนดแรกของแต่ละบักเก็ต = next ของโหนดที่ entry ชี้
local firstNode = {}
do
  local keys = {}
  for k in pairs(entry) do keys[#keys + 1] = k end
  table.sort(keys)
  local i = 1
  while i <= #keys do
    local top = math.min(i + 499, #keys)
    local req = {}
    for j = i, top do
      local a = entry[keys[j]]
      req[#req + 1] = { address = a, flags = gg.TYPE_DWORD }
      req[#req + 1] = { address = a + 4, flags = gg.TYPE_DWORD }
    end
    local ok, res = pcall(gg.getValues, req)
    if ok and res then
      for j = i, top do
        local lo = res[(j - i) * 2 + 1].value
        local hi = res[(j - i) * 2 + 2].value
        if lo ~= nil and hi ~= nil then
          firstNode[keys[j]] = strip(u32(tonumber(lo)), u32(tonumber(hi)))
        end
      end
    end
    i = top + 1
  end
end

-- ── Step 5: ไล่ทุกบักเก็ต ──
local pairsAll, byId = {}, {}
local visited = {}
local stopBad, stopMismatch = 0, 0
local total = 0
do
  local keys = {}
  for k in pairs(firstNode) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, b in ipairs(keys) do
    local N = firstNode[b]
    while N ~= 0 and total < MAX_NODES do
      if visited[N] then break end
      local w = readWords(N, 10)
      if not w then stopBad = stopBad + 1; break end
      if w[3] ~= w[5] then stopBad = stopBad + 1; break end
      if (w[5] % BC) ~= b then break end          -- จบกลุ่มของบักเก็ต b
      visited[N] = true
      local p = { id = w[5], v = w[7], hi = w[8], N = N }
      pairsAll[#pairsAll + 1] = p
      byId[p.id] = p
      total = total + 1
      N = ptrAt(w, 1)
      if total % 1000 == 0 then gg.toast("ไล่โหนด " .. total) end
    end
  end
end
emit("ไล่ได้ทั้งหมด " .. #pairsAll .. " โหนด | หยุดผิดปกติ " .. stopBad .. " ครั้ง")

-- ── Step 6: ตรวจว่า value (qword ที่ N+0x18) เป็นพอยน์เตอร์หรือไม่ ──
local hiCount, hiOrder = {}, {}
for _, p in ipairs(pairsAll) do
  if not hiCount[p.hi] then hiCount[p.hi] = 0; hiOrder[#hiOrder + 1] = p.hi end
  hiCount[p.hi] = hiCount[p.hi] + 1
end
table.sort(hiOrder, function(a, b) return hiCount[a] > hiCount[b] end)
emit("ครึ่งบน (dword ที่ N+0x1C) ของ value: มี " .. #hiOrder .. " ค่าต่างกัน; ที่พบมากสุด:")
for i = 1, math.min(#hiOrder, 6) do
  emit("   0x" .. hex(hiOrder[i]) .. " x " .. hiCount[hiOrder[i]])
end

emit("")
emit("== 11 วัตถุดิบ: ID | value(ล่าง) | value(บน) | โหนด | เนื้อหาที่ตำแหน่ง (บน:ล่าง) 0x100 ไบต์ ==")
for _, s in ipairs(START) do
  local id = u32(s[1])
  local p = byId[id]
  if not p then
    emit(s[2] .. "\t" .. id .. "\t(ไม่เจอในการไล่)")
  else
    emit(s[2] .. "\t" .. id .. "\t" .. p.v .. "\t" .. p.hi .. "\t0x" .. hex(p.N))
    local target = strip(p.v, p.hi)
    local w = readWords(target, 64)
    if not w then
      emit("   อ่านที่ 0x" .. hex(target) .. " ไม่ได้")
    else
      local line = {}
      for i = 1, #w do
        line[#line + 1] = hex(w[i])
        if i % 8 == 0 then
          emit("   +0x" .. hex((i - 8) * 4) .. ": " .. table.concat(line, " "))
          line = {}
        end
      end
    end
  end
end

emit("")
emit("== ID\tvalue_lo\tvalue_hi ==")
for _, p in ipairs(pairsAll) do
  emit(p.id .. "\t" .. p.v .. "\t" .. p.hi)
end

finish("ตารางบักเก็ต 0x" .. hex(base) .. "\nไล่ได้ " .. #pairsAll .. " โหนด (หยุดผิดปกติ " .. stopBad .. ")")
