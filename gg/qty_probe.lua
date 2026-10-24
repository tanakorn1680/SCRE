-- qty_probe.lua (v2) | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- เป้าหมาย: หาโครงสร้างของ "Product Quantity" (จำนวนไอเท็มที่ผลิตได้จากโรงงาน) เพื่อยึดตำแหน่งแบบเสถียร
--   เหมือนที่ทำกับ 11 slots (Registry Search)
-- สิ่งที่สคริปต์ผู้ใช้ทำอยู่ตอนนี้ (findProductQuantityAddresses):
--   ค้นค่า -1190452077 (= ไอดีเรคอร์ด WoodProd ที่ +0x10 ในทะเบียน) -> เลือกที่อยู่ที่ [hit-0x18] == 1 เป็น base
--   -> สแกน base+4, +8, ... (ไม่เกิน 1200 ไบต์) หา dword ที่ == 1 ให้ครบ 11 ช่อง
-- probe นี้ตอบ 4 คำถาม (ยังไม่เคยมีข้อมูล):
--   1) ไอดี Prod ของวัตถุดิบทั้ง 11 (อ่านสดจากทะเบียน ไม่ฮาร์ดโค้ด) -> ใช้ไอดีไหนเป็นตัวยึดได้บ้าง
--   2) ผลค้น anchor แต่ละที่คืออะไร (เรคอร์ดทะเบียน / โหนดแมป / ตัวที่สคริปต์ใช้ / อื่น ๆ)
--   3) รอบ base ที่สคริปต์เลือก: 11 ช่อง "1" ห่างกันเท่าไร และแต่ละช่องมีไอดี Prod ของวัตถุดิบใดอยู่ใกล้ (+0x18)
--   4) มีตัวชี้อะไรชี้มาที่โครงสร้างนี้ (ถ้าอยู่ใน libsimcity.so = ได้ราก static)
-- v2: แก้บั๊ก v1 (candidate [X-0x18]==1 ถูกนับเป็น "โหนดแมป" จน Step 3-5 ไม่ทำงาน) ; Step 3 เพิ่มสถิติ "1" ทั้งหมดในหน้าต่าง + เศษ mod 0x20 ;
--   Step 4 ติดป้ายฟิลด์ของโหนดแมป ; Step 5 ใหม่ = หาโหนดแมปของไอดี Prod ทั้ง 11 ดูว่า "1" อยู่ที่ตำแหน่งเดียวกันในทุกโหนดไหม (แทนการหาตัวชี้)
-- วิธีใช้: เปิดเกม เข้าเมืองให้เต็ม เปิดโรงงานดูสักครั้ง (ยังไม่ต้องแก้จำนวนผลิตในรอบนี้ ถ้าแก้ไปแล้วให้รีสตาร์ทเกมก่อน)
--   -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ qty_probe.txt

local LIB       = "libsimcity.so"
local G_OFF     = 0x23E6318
local MAX_NODES = 40000
local RANGES    = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS
local RANGES2   = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS | gg.REGION_C_DATA | gg.REGION_C_BSS
local MAX_HITS  = 2000
local MAX_PAR   = 4000
local SCAN_MAX  = 1200
local DUMP_BACK = 0x40
local DUMP_DW   = 400

local PROD = {
  { "MetalProd", "Metal" }, { "WoodProd", "Wood" }, { "PlasticProd", "Plastic" },
  { "SeedsProd", "Seeds" }, { "MineralsProd", "Minerals" }, { "ChemicalsProd", "Chemicals" },
  { "TextilesProd", "Textiles" }, { "SugarSpicesProd", "SugarSpices" }, { "GlassProd", "Glass" },
  { "AnimalFeedProd", "AnimalFeed" }, { "ElectricalComponentsProd", "ElectricalComponents" },
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
local function offs(o) if o < 0 then return "-0x" .. hex(-o) end return "+0x" .. hex(o) end

local function readLoose(addr, n)   -- dword ที่อ่านไม่ได้ = false (ไม่ทิ้งทั้งชุด)
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

local function readWords(addr, n)   -- ต้องอ่านได้ครบทุก dword ไม่งั้นคืน nil
  local w = readLoose(addr, n)
  if not w then return nil end
  for i = 1, #w do if w[i] == false then return nil end end
  return w
end

local function readText(addr, n)
  local req = {}
  for i = 0, n - 1 do req[#req + 1] = { address = addr + i, flags = gg.TYPE_BYTE } end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local s = ""
  for i = 1, #res do
    local c = (res[i].value or 0) % 256
    if c == 0 then break end
    if c >= 32 and c < 127 then s = s .. string.char(c) else s = s .. "." end
  end
  return s
end

local out = {}
local function emit(s) out[#out + 1] = s end

local function finish(extra)
  local text = table.concat(out, "\n")
  local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
  local path = nil
  for i = 1, 3 do
    if dirs[i] then
      local ok, f = pcall(io.open, dirs[i] .. "/qty_probe.txt", "w")
      if ok and f then
        f:write(text .. "\n")
        f:close()
        path = dirs[i] .. "/qty_probe.txt"
        break
      end
    end
  end
  pcall(gg.copyText, text, false)
  local head = {}
  for i = 1, math.min(#out, 40) do head[#head + 1] = out[i] end
  gg.alert((extra or "") .. table.concat(head, "\n") .. "\n\nไฟล์เต็ม: " .. tostring(path))
end

-- ── Step 0: base ของ libsimcity.so ──
local ranges = gg.getRangesList(LIB)
if not ranges or #ranges == 0 then
  gg.alert("ไม่พบโมดูล " .. LIB .. "\nเปิดเกมก่อน แล้วเลือกโปรเซสเกมใน GG")
  os.exit()
end
local base, libEnd = nil, 0
for i = 1, #ranges do
  if not base or ranges[i].start < base then base = ranges[i].start end
  if ranges[i]["end"] and ranges[i]["end"] > libEnd then libEnd = ranges[i]["end"] end
end
emit("base " .. LIB .. " = 0x" .. hex(base))

-- ── Step 1: เดินทะเบียน หาโหนดคีย์ *Prod ทั้ง 11 ชื่อ แล้วอ่านไอดีที่ data+0x10 ──
local g = readWords(base + G_OFF, 2)
if not g or ptrAt(g, 1) == 0 then
  gg.alert("ทะเบียนยังไม่พร้อม (เข้าเมืองให้เต็มก่อน) หรือ offset ไม่ตรงเวอร์ชัน")
  os.exit()
end
local singleton = ptrAt(g, 1)
local hd = readWords(singleton + 0x18, 2)
if not hd then gg.alert("อ่านหัวลิสต์ทะเบียนไม่ได้"); os.exit() end

local want = {}
for i, p in ipairs(PROD) do want[p[1]] = i end
local found, nfound = {}, 0
local node, guard = ptrAt(hd, 1), 0
gg.toast("⏳ อ่านทะเบียน...")
while node ~= 0 and guard < MAX_NODES and nfound < #PROD do
  guard = guard + 1
  local w = readWords(node, 12)    -- +0 next | +0x10 คีย์ (std::string 24 ไบต์) | +0x28 ตัวชี้ข้อมูล
  if not w then break end
  local b0 = u32(w[5]) % 256
  local key = nil
  if b0 % 2 == 0 then
    local len = b0 / 2
    if len >= 8 and len <= 22 then
      local t = {}
      for i = 1, len do
        t[i] = string.char(math.floor(u32(w[5 + math.floor(i / 4)]) / 2 ^ (8 * (i % 4))) % 256)
      end
      key = table.concat(t)
    end
  else
    local len = u32(w[7])          -- คีย์ยาว: ความยาวที่ +0x18, ตัวชี้ที่ +0x20
    local p = ptrAt(w, 9)
    if len >= 20 and len <= 30 and p ~= 0 then key = readText(p, len) end
  end
  if key then
    local idx = want[key]
    if idx and not found[idx] then
      found[idx] = { node = node, data = ptrAt(w, 11) }
      nfound = nfound + 1
    end
  end
  node = ptrAt(w, 1)
  if guard % 2000 == 0 then gg.toast("ทะเบียน: เดิน " .. guard .. " (เจอ " .. nfound .. "/11)") end
end

emit("")
emit("== Step 1: ไอดี Prod จากทะเบียน (เดิน " .. guard .. " โหนด, เจอ " .. nfound .. "/" .. #PROD .. ") ==")
emit("คีย์\tไอดี(+0x10) unsigned\tsigned\tเรคอร์ด\t+0x20(ควร=16)")
local idName = {}
local ids = {}
for i, p in ipairs(PROD) do
  local f = found[i]
  if f and f.data ~= 0 then
    local r = readWords(f.data + 0x10, 1)
    local c = readWords(f.data + 0x20, 1)
    if r then
      ids[i] = r[1]
      idName[r[1]] = p[2]
      emit(p[1] .. "\t" .. r[1] .. "\t" .. s32(r[1]) .. "\t0x" .. hex(f.data) .. "\t" .. (c and c[1] or "?"))
    else
      emit(p[1] .. "\t(อ่านเรคอร์ดไม่ได้)\t\t0x" .. hex(f.data))
    end
  else
    emit(p[1] .. "\t(ไม่พบในทะเบียน)")
  end
end

local woodId = ids[2]
if not woodId then
  finish("หา WoodProd ในทะเบียนไม่ได้\n\n")
  os.exit()
end
local ANCHOR_SCRIPT = 3104515219
emit("WoodProd ไอดีตรงกับ anchor ของสคริปต์ (3104515219)? " .. tostring(woodId == ANCHOR_SCRIPT))

-- ── Step 2: ค้นไอดี WoodProd เหมือนสคริปต์ แล้วจัดประเภทผลค้นทุกตัว ──
gg.setRanges(RANGES)
gg.clearResults()
gg.searchNumber(tostring(s32(woodId)), gg.TYPE_DWORD)
local cnt = gg.getResultsCount()
local hits = {}
if cnt > 0 then hits = gg.getResults(math.min(cnt, MAX_HITS)) end
gg.clearResults()

local woodRec = found[2].data
local nReg, nMap, nCand, nOther = 0, 0, 0, 0
local cands = {}
emit("")
emit("== Step 2: ค้น " .. woodId .. " (WoodProd) ได้ " .. cnt .. " ที่ (อ่านมา " .. #hits .. ") ==")
for _, h in ipairs(hits) do
  local X = h.address
  local w = readLoose(X - 0x20, 12)       -- X-0x20 .. X+0x0F
  local tags = {}
  local isCand = (w and w[3] == 1) and true or false
  if X == woodRec + 0x10 then
    tags[#tags + 1] = "เรคอร์ดทะเบียน (WoodProd +0x10)"; nReg = nReg + 1
    isCand = false
  else
    if w and w[7] == woodId then tags[#tags + 1] = "โหนดแมป (hash==key ที่ X-8)"; nMap = nMap + 1 end
    if isCand then tags[#tags + 1] = "CANDIDATE ([X-0x18]==1 ตามสคริปต์)"; nCand = nCand + 1; cands[#cands + 1] = X end
    if #tags == 0 then nOther = nOther + 1 end
  end
  if #tags > 0 or nOther <= 6 then
    emit("0x" .. hex(X) .. "\t" .. (#tags > 0 and table.concat(tags, " + ") or "อื่น ๆ") ..
         "\t[X-0x18]=" .. (w and w[3] and hex8(w[3]) or "?") ..
         "\t[X-8]=" .. (w and w[7] and hex8(w[7]) or "?") .. "\t[X+8]=" .. (w and w[11] and hex8(w[11]) or "?"))
  end
end
emit("สรุป: เรคอร์ดทะเบียน " .. nReg .. " | โหนดแมป " .. nMap .. " | CANDIDATE " .. nCand .. " | อื่น ๆ " .. nOther)

if #cands == 0 then
  finish("ไม่พบตัวที่ [hit-0x18]==1 (โครงสร้างอาจถูกแก้ไปแล้ว ลองรีสตาร์ทเกม)\n\n")
  os.exit()
end

-- ── Step 3: candidate ที่สคริปต์เลือก: สแกน "1" ตามวิธีสคริปต์ + สถิติ "1" ทั้งหมดในหน้าต่าง ──
local function scanOnes(B)
  local w = readLoose(B, SCAN_MAX / 4 + 2)
  local list = { 0 }
  local all = {}
  if not w then return list, all end
  local o = 4
  while o <= SCAN_MAX do
    if w[o / 4 + 1] == 1 then
      all[#all + 1] = o
      if #list < 11 then list[#list + 1] = o end
    end
    o = o + 4
  end
  return list, all
end

emit("")
emit("== Step 3: candidate (ตัวแรก = ตัวที่สคริปต์ใช้จริง) ; N = X-0x10 = ต้นโหนดแมป ; base = X-0x18 = N-8 ==")
local primary = nil
for ci = 1, math.min(#cands, 8) do
  local Bc = cands[ci] - 0x18
  local list, all = scanOnes(Bc)
  local parts = {}
  for _, o in ipairs(list) do parts[#parts + 1] = "+0x" .. hex(o) end
  emit("#" .. ci .. " base=0x" .. hex(Bc) .. " (anchor@0x" .. hex(cands[ci]) .. ") สคริปต์นับ '1' ได้ " .. #list .. " ช่อง: " .. table.concat(parts, " "))
  emit("   '1' ทั้งหมดในหน้าต่าง " .. SCAN_MAX .. " ไบต์ (ไม่จำกัด 11): " .. (#all + 1) .. " ตัว")
  if ci == 1 then primary = { B = Bc, list = list, all = all } end
end

local B = primary.B
local N = B + 8
-- เศษของตำแหน่ง "1" เทียบต้นโหนด N mod 0x20: ถ้า 1 ทุกตัวเศษเท่ากัน = เป็นฟิลด์เดียวกันของโหนดที่เรียงห่าง 0x20
local resid = {}
local function addRes(o)
  local r = (o - 8) % 0x20
  resid[r] = (resid[r] or 0) + 1
end
addRes(0)
for _, o in ipairs(primary.all) do addRes(o) end
local rparts = {}
for r = 0, 0x1C, 4 do if resid[r] then rparts[#rparts + 1] = "N+0x" .. hex(r) .. " : " .. resid[r] .. " ตัว" end end
emit("เศษตำแหน่ง '1' เทียบต้นโหนด N (mod 0x20): " .. table.concat(rparts, " | "))

emit("")
emit("== ช่อง 11 ตัวของสคริปต์ (candidate #1) | ออฟเซ็ตจาก base | ออฟเซ็ตจาก N | ไอดี Prod ที่ช่อง+0x18 ==")
for k, o in ipairs(primary.list) do
  local a = B + o
  local x = readLoose(a + 0x18, 1)
  local nm = x and x[1] and idName[x[1]] or nil
  emit(k .. "\t" .. offs(o) .. "\t" .. offs(o - 8) .. "\t0x" .. hex(a) ..
       "\t[a+0x18]=" .. (x and x[1] and hex8(x[1]) or "?") .. " " .. (nm or "-"))
end

-- ── Step 4: ดัมพ์รอบ base ของ candidate #1 พร้อมป้ายไอดี Prod และฟิลด์ของโหนด N ──
emit("")
emit("== Step 4: ดัมพ์ " .. DUMP_DW .. " dword เริ่ม base-0x" .. hex(DUMP_BACK) .. " | ออฟเซ็ตจาก base | ออฟเซ็ตจาก N | hex | ป้าย ==")
local from = B - DUMP_BACK
local dw = readLoose(from, DUMP_DW)
local nodeField = { [0] = "N.next-lo", [4] = "N.next-hi", [8] = "N.hash-lo", [12] = "N.hash-hi",
                    [16] = "N.key", [20] = "N.pad", [24] = "N.value-lo", [28] = "N.value-hi" }
if dw then
  for i = 1, #dw do
    local v = dw[i]
    local addr = from + (i - 1) * 4
    local o = addr - B
    local tag = ""
    if v then
      if idName[v] then tag = "ID:" .. idName[v] .. "Prod"
      elseif v == 1 then tag = "1"
      else
        local nx = dw[i + 1]
        if nx and nx % 16777216 == 126 and v ~= 0 then tag = "ptr-lo" end
      end
    end
    local nf = nodeField[addr - N]
    if nf then tag = (tag ~= "" and (tag .. " ") or "") .. "<" .. nf .. ">" end
    emit(offs(o) .. "\t" .. offs(addr - N) .. "\t" .. (v and hex8(v) or "????????") .. "\t" .. tag)
  end
else
  emit("(อ่านไม่ได้)")
end

-- ── Step 5: โหนดแมปของไอดี Prod ทั้ง 11 — ค้นแต่ละไอดี เลือกที่ [X-8]==id และ [X+8] ต่ำ == ครึ่งล่างของเรคอร์ด ──
emit("")
emit("== Step 5: โหนดแมปของ *Prod ทั้ง 11 | N | ห่างจาก N ของ Wood | dword N-8..N+0x1C ==")
local woodN = nil
local rows5 = {}
for i, p in ipairs(PROD) do
  local id, f = ids[i], found[i]
  if id and f then
    gg.setRanges(RANGES)
    gg.clearResults()
    gg.searchNumber(tostring(s32(id)), gg.TYPE_DWORD)
    local c2 = gg.getResultsCount()
    local rs = {}
    if c2 > 0 then rs = gg.getResults(math.min(c2, MAX_HITS)) end
    gg.clearResults()
    local nodeN = nil
    for _, r in ipairs(rs) do
      local w = readLoose(r.address - 8, 6)     -- X-8 .. X+0x0F ; X = คีย์ (N+0x10)
      if w and w[1] == id and w[5] == (f.data % 4294967296) then nodeN = r.address - 0x10; break end
    end
    if nodeN then
      if i == 2 then woodN = nodeN end
      local ctx = readLoose(nodeN - 8, 10)
      local cs = {}
      if ctx then for j = 1, #ctx do cs[#cs + 1] = ctx[j] and hex8(ctx[j]) or "????????" end end
      rows5[#rows5 + 1] = { name = p[1], n = nodeN, ctx = table.concat(cs, " ") }
    else
      rows5[#rows5 + 1] = { name = p[1], miss = "(ไม่พบโหนดแมป ค้นเจอ " .. c2 .. " ที่)" }
    end
  end
end

for _, r in ipairs(rows5) do
  if r.miss then emit(r.name .. "\t" .. r.miss)
  else emit(r.name .. "\t0x" .. hex(r.n) .. "\t" .. (woodN and offs(r.n - woodN) or "?") .. "\t" .. r.ctx) end
end

finish("")
