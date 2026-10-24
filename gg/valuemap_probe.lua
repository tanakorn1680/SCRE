-- valuemap_probe.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- จุดประสงค์: ตรวจสมมติฐาน (ยังไม่ยืนยัน) ว่าโหนดที่สคริปต์ผู้ใช้ค้นเจอด้วยค่า identity ของไอเท็ม
--   ([A]=ID, [A+8]=ID, [A+0x10]=value ที่เปลี่ยนทุกรอบ) เป็นโหนดของ unordered_map ที่เรียงเป็นลิสต์เชื่อม:
--   N+0 = next, N+8 = hash, N+0x10 = key, N+0x18 = value  (โดย N = A-8)
--   ถ้าจริง เดินตาม next จากโหนดเดียวจะได้คู่ (ID, value) ของไอเท็มอื่นด้วย โดยไม่ต้องค้นทีละตัว
-- วิธีใช้: เปิดเกม เข้าเมือง (เปิดโรงงานดูสักครั้ง) -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ valuemap_probe.txt
-- ผลลัพธ์: ไฟล์ valuemap_probe.txt (1) โหนดเริ่มต้น 11 ตัว (2) ความยาวลิสต์ที่เดินได้ + เหตุที่หยุด (3) คู่ ID,value ทั้งหมดที่เจอ

local MAX_NODES = 4000                       -- เพดานต่อการเดินหนึ่งครั้ง กันวนไม่รู้จบ
local RANGES    = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS   -- เหมือน SEARCH_RANGES ในสคริปต์ผู้ใช้

-- identity ของ 11 วัตถุดิบ (คัดลอกจาก SLOT_IDENTITY ในสคริปต์ผู้ใช้ v9, เป็นค่า signed)
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
-- ตัดแท็กไบต์บนสุดของพอยน์เตอร์ arm64 (เหมือนสคริปต์ registry)
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

-- ── Step 1: หาโหนดเริ่มต้นของแต่ละ identity (เงื่อนไขเดียวกับ findMoreItemValues: [A+8] == ID) ──
local out = {}
local function emit(s) out[#out + 1] = s end

local starts = {}   -- { name, id(u32), A, N, V }
for _, s in ipairs(START) do
  local id = s[1]
  gg.setRanges(RANGES)
  gg.clearResults()
  gg.searchNumber(tostring(id), gg.TYPE_DWORD)
  local cnt = gg.getResultsCount()
  local hitsTotal, valid = cnt, 0
  local pick = nil
  if cnt > 0 then
    local res = gg.getResults(math.min(cnt, 2000))
    for _, r in ipairs(res) do
      local w = readWords(r.address, 6)   -- [A], [A+4], [A+8], [A+C], [A+0x10], [A+0x14]
      if w and w[3] == u32(id) then
        valid = valid + 1
        if not pick then pick = { A = r.address, V = w[5] } end
      end
    end
  end
  gg.clearResults()
  if pick then
    starts[#starts + 1] = { name = s[2], id = u32(id), A = pick.A, N = pick.A - 8, V = pick.V,
                            hits = hitsTotal, valid = valid }
  else
    emit("ไม่พบโหนดที่ verify ผ่าน: " .. s[2] .. " (ค้นเจอ " .. hitsTotal .. " ที่)")
  end
end

if #starts == 0 then
  gg.alert("ไม่พบโหนดเริ่มต้นเลย\nเปิดโรงงานในเกมแล้วรันใหม่")
  os.exit()
end

-- ── Step 2: เดินตาม next จากแต่ละโหนด (ข้ามโหนดที่เคยเดินแล้ว) ──
local visited = {}      -- [N] = true
local pairsFound = {}   -- ลำดับที่เจอ: { key, value, N }
local walkReports = {}

for si, s in ipairs(starts) do
  local N, steps, reason = s.N, 0, "ครบเพดาน"
  local newNodes = 0
  while steps < MAX_NODES do
    if N == 0 then reason = "next = 0 (ท้ายลิสต์)"; break end
    if visited[N] then reason = "ชนโหนดที่เดินแล้ว"; break end
    local w = readWords(N, 8)     -- next(2) hash(2) key(2) value(2)
    if not w then reason = "อ่านหน่วยความจำไม่ได้ที่ 0x" .. hex(N); break end
    local hash, key, val = w[3], w[5], w[7]
    if hash ~= key then
      reason = "รูปแบบไม่ตรง (hash~=key) ที่ 0x" .. hex(N)
      break
    end
    visited[N] = true
    pairsFound[#pairsFound + 1] = { key, val, N }
    newNodes = newNodes + 1
    steps = steps + 1
    N = ptrAt(w, 1)
    if si == 1 and steps % 500 == 0 then gg.toast("เดินโหนด " .. steps) end
  end
  walkReports[si] = { newNodes = newNodes, reason = reason }
end

-- ── Step 3: เขียนรายงาน ──
local isStart = {}
for _, s in ipairs(starts) do isStart[s.id] = s.name end

emit("โหนดเริ่มต้น (ชื่อ | ID | โหนด N | value ที่ +0x10 จาก A | เจอกี่ที่ | verify ผ่านกี่ที่ | โหนดใหม่ที่เดินได้ | เหตุที่หยุด)")
for i, s in ipairs(starts) do
  local r = walkReports[i]
  emit(s.name .. "\t" .. s.id .. "\t0x" .. hex(s.N) .. "\t" .. s.V .. "\t" .. s.hits .. "\t" .. s.valid ..
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
    local ok, f = pcall(io.open, dirs[i] .. "/valuemap_probe.txt", "w")
    if ok and f then
      f:write(text .. "\n")
      f:close()
      where = dirs[i] .. "/valuemap_probe.txt"
      break
    end
  end
end
gg.alert("โหนดเริ่มต้น " .. #starts .. "/11 | เดินได้ " .. #pairsFound .. " คู่ (ของ 11 วัตถุดิบ " .. startsHit .. ")\n\nไฟล์: " .. tostring(where))
