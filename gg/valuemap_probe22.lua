-- valuemap_probe2.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- แก้จาก valuemap_probe.lua: รอบแรกเลือก "ที่แรกที่ [A+8]==ID" ซึ่งผิดตัวสำหรับ metal/wood
--   รอบนี้: เก็บทุกที่ที่ verify ผ่านของแต่ละ identity -> เดินสั้น ๆ ทดสอบแต่ละที่ว่าเป็นโหนดลิสต์จริงไหม
--   (hash == key ติดกันหลายโหนด) -> เลือกที่เดินได้ยาวที่สุด -> เดินเต็มโดยเริ่มจาก metal ก่อน แล้ว wood ฯลฯ
-- โครงโหนดที่ใช้ (สมมติฐานที่รอบแรกยืนยันบางส่วน): N = A-8 ; N+0 next, N+8 hash, N+0x10 key, N+0x18 value
-- วิธีใช้: เปิดเกม เข้าเมือง (เปิดโรงงานดูสักครั้ง) -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ valuemap_probe2.txt
-- ผลลัพธ์: (1) ทุกที่ที่ verify ผ่านของ 11 identity พร้อม value และความยาวเดินทดสอบ (2) ผลเดินเต็มต่อโหนดเริ่มต้น
--          (3) คู่ ID,value ทั้งหมด (รูปแบบเดียวกับรอบแรก)

local TEST_STEPS = 40          -- เดินทดสอบต่อหนึ่งที่
local MAX_NODES  = 40000       -- เพดานการเดินเต็มรวมทุกจุดเริ่ม
local MAX_HITS   = 40          -- อ่านผลค้นต่อ identity ไม่เกินกี่ที่
local RANGES     = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS   -- เหมือน SEARCH_RANGES ในสคริปต์ผู้ใช้

-- identity ของ 11 วัตถุดิบ (คัดลอกจาก SLOT_IDENTITY ในสคริปต์ผู้ใช้ v9, ค่า signed) เรียง metal ก่อน
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
-- ตัดแท็กไบต์บนสุดของพอยน์เตอร์ arm64
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

-- เดินสั้น ๆ ทดสอบ: คืน (จำนวนโหนดที่ hash==key ติดกัน, เหตุที่หยุด) ไม่แตะ visited
local function testWalk(N, maxSteps)
  local steps, reason = 0, "ครบจำนวนทดสอบ"
  local seen = {}
  while steps < maxSteps do
    if N == 0 then reason = "next = 0"; break end
    if seen[N] then reason = "วนกลับ"; break end
    local w = readWords(N, 8)
    if not w then reason = "อ่านไม่ได้"; break end
    if w[3] ~= w[5] then reason = "hash~=key"; break end
    seen[N] = true
    steps = steps + 1
    N = ptrAt(w, 1)
  end
  return steps, reason
end

local out = {}
local function emit(s) out[#out + 1] = s end

-- ── Step 1: เก็บทุกที่ที่ verify ผ่านของแต่ละ identity แล้วเดินทดสอบ ──
local starts = {}   -- { name, id, A, N, V, testLen }
emit("ทุกที่ที่ verify ([A+8]==ID) ผ่าน: ชื่อ | ID | A | value ที่ [A+0x10] | เดินทดสอบได้ | เหตุที่หยุด | ถูกเลือก")
for _, s in ipairs(START) do
  local id = s[1]
  gg.setRanges(RANGES)
  gg.clearResults()
  gg.searchNumber(tostring(id), gg.TYPE_DWORD)
  local cnt = gg.getResultsCount()
  local cands = {}
  if cnt > 0 then
    local res = gg.getResults(math.min(cnt, MAX_HITS))
    for _, r in ipairs(res) do
      local w = readWords(r.address, 6)
      if w and w[3] == u32(id) then
        local N = r.address - 8
        local len, why = testWalk(N, TEST_STEPS)
        cands[#cands + 1] = { A = r.address, N = N, V = w[5], len = len, why = why }
      end
    end
  end
  gg.clearResults()
  local best = nil
  for _, c in ipairs(cands) do
    if not best or c.len > best.len then best = c end
  end
  for _, c in ipairs(cands) do
    emit(s[2] .. "\t" .. u32(id) .. "\t0x" .. hex(c.A) .. "\t" .. c.V .. "\t" .. c.len .. "\t" .. c.why ..
         "\t" .. ((c == best) and "เลือก" or ""))
  end
  if #cands == 0 then emit(s[2] .. "\t" .. u32(id) .. "\t(ไม่มีที่ verify ผ่าน; ค้นเจอ " .. cnt .. " ที่)") end
  if best then
    starts[#starts + 1] = { name = s[2], id = u32(id), N = best.N, V = best.V, testLen = best.len }
  end
end

if #starts == 0 then
  gg.alert("ไม่พบโหนดเริ่มต้นเลย\nเปิดโรงงานในเกมแล้วรันใหม่")
  os.exit()
end

-- ── Step 2: เดินเต็มต่อเนื่องตามลำดับ (metal ก่อน) ใช้ visited ร่วมกัน ──
local visited = {}
local pairsFound = {}
local walkReports = {}
local total = 0

for si, s in ipairs(starts) do
  local N, newNodes, reason = s.N, 0, "ครบเพดานรวม"
  while total < MAX_NODES do
    if N == 0 then reason = "next = 0 (ท้ายลิสต์)"; break end
    if visited[N] then reason = "ชนโหนดที่เดินแล้ว"; break end
    local w = readWords(N, 8)
    if not w then reason = "อ่านไม่ได้ที่ 0x" .. hex(N); break end
    if w[3] ~= w[5] then reason = "hash~=key ที่ 0x" .. hex(N); break end
    visited[N] = true
    pairsFound[#pairsFound + 1] = { w[5], w[7], N }
    newNodes = newNodes + 1
    total = total + 1
    N = ptrAt(w, 1)
    if total % 1000 == 0 then gg.toast("เดินโหนด " .. total) end
  end
  walkReports[si] = { newNodes = newNodes, reason = reason }
end

-- ── Step 3: เขียนรายงาน ──
local isStart = {}
for _, s in ipairs(starts) do isStart[s.id] = s.name end

emit("")
emit("โหนดเริ่มต้นที่เลือก (ชื่อ | ID | โหนด N | value | เดินทดสอบ | โหนดใหม่ที่เดินเต็มได้ | เหตุที่หยุด)")
for i, s in ipairs(starts) do
  local r = walkReports[i]
  emit(s.name .. "\t" .. s.id .. "\t0x" .. hex(s.N) .. "\t" .. s.V .. "\t" .. s.testLen ..
       "\t" .. r.newNodes .. "\t" .. r.reason)
end
emit("")
local startsHit = 0
for _, p in ipairs(pairsFound) do if isStart[p[1]] then startsHit = startsHit + 1 end end
emit("รวมคู่ (ID,value) ที่เดินได้ทั้งหมด " .. #pairsFound .. " | ในนั้นเป็นของ 11 วัตถุดิบ " .. startsHit .. " ตัว")
emit("")
emit("== ID\tvalue\tโหนด\tชื่อ(ถ้าเป็นหนึ่งใน 11) ==")
for _, p in ipairs(pairsFound) do
  emit(p[1] .. "\t" .. p[2] .. "\t0x" .. hex(p[3]) .. "\t" .. (isStart[p[1]] or ""))
end

local text = table.concat(out, "\n")
local where = "(เขียนไฟล์ไม่ได้)"
local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
for i = 1, 3 do
  if dirs[i] then
    local ok, f = pcall(io.open, dirs[i] .. "/valuemap_probe2.txt", "w")
    if ok and f then
      f:write(text .. "\n")
      f:close()
      where = dirs[i] .. "/valuemap_probe2.txt"
      break
    end
  end
end
gg.alert("โหนดเริ่มต้น " .. #starts .. "/11 | เดินได้ " .. #pairsFound .. " คู่ (ของ 11 วัตถุดิบ " .. startsHit .. ")\n\nไฟล์: " .. tostring(where))
