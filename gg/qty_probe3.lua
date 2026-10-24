-- qty_probe3.lua (v3) | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- เหตุผล: ผล v2 พบว่า "1" ที่สคริปต์แก้ เป็นฟิลด์ของโหนดแมป "ไอดี->เรคอร์ด" (มีกับไอเท็มอื่นด้วย ไม่ใช่เฉพาะ *Prod,
--   Metal/Seeds ไม่มี "1" ที่ N-8) -> ยังไม่มีหลักฐานว่าเป็น "จำนวนผลิต" จริง รอบนี้หาจากเรคอร์ดทะเบียนของ *Prod ตรง ๆ
-- Step 1 = เหมือน v2 (เดินทะเบียน หา *Prod 11 ตัว + ตัวเทียบ Planks/Hammer/Popcorn)
-- Step 2 = ดัมพ์เรคอร์ด 0x400 ไบต์ของทุกตัวเป็นตารางเดียว (แสดงเฉพาะแถวที่ไม่ใช่ศูนย์ทั้งหมด ; "=" = ทุกตัวค่าเท่ากัน)
-- Step 3 = ตามตัวชี้ (heap) ในเรคอร์ด WoodProd ไม่เกิน 24 ตัว ดัมพ์ 16 dword ต่อตัว (หาอาร์เรย์ผลลัพธ์/จำนวน)
-- วิธีใช้: เปิดเกม เข้าเมือง เปิดโรงงานดูสักครั้ง (ไม่ต้องแก้ค่าใดก่อน ถ้าเคยแก้ให้รีสตาร์ทเกมก่อน)
--   -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ qty_probe3.txt (ไฟล์เล็ก ~20KB)

local LIB       = "libsimcity.so"
local G_OFF     = 0x23E6318
local MAX_NODES = 40000
local RANGES    = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS
local RANGES2   = gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS | gg.REGION_C_DATA | gg.REGION_C_BSS
local MAX_HITS  = 2000
local MAX_PAR   = 4000
local SCAN_MAX  = 1200
local NDW        = 256     -- ดัมพ์เรคอร์ด 0x400 ไบต์
local MAXFOLLOW  = 24      -- ตามตัวชี้ในเรคอร์ด WoodProd ไม่เกินกี่ตัว

local PROD = {
  { "MetalProd", "Metal" }, { "WoodProd", "Wood" }, { "PlasticProd", "Plastic" },
  { "SeedsProd", "Seeds" }, { "MineralsProd", "Minerals" }, { "ChemicalsProd", "Chemicals" },
  { "TextilesProd", "Textiles" }, { "SugarSpicesProd", "SugarSpices" }, { "GlassProd", "Glass" },
  { "AnimalFeedProd", "AnimalFeed" }, { "ElectricalComponentsProd", "ElectricalComponents" },
  { "PlanksProd", "Planks" }, { "HammerProd", "Hammer" }, { "PopcornProd", "Popcorn" },   -- ตัวเทียบ (ไม่ใช่วัตถุดิบ)
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
      local ok, f = pcall(io.open, dirs[i] .. "/qty_probe3.txt", "w")
      if ok and f then
        f:write(text .. "\n")
        f:close()
        path = dirs[i] .. "/qty_probe3.txt"
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

-- ── Step 2: ดัมพ์เรคอร์ดทะเบียนของทุก *Prod เป็นตารางเดียว ──
local cols, woodW = {}, nil
for i, p in ipairs(PROD) do
  local f = found[i]
  if f and f.data ~= 0 then
    local w = readLoose(f.data, NDW)
    if w then
      cols[#cols + 1] = { p[2], w }
      if i == 2 then woodW = w end
    end
  end
end
local function cell(v)
  if v == false then return "?" end
  if v < 100000000 then return tostring(v) end
  return "h" .. hex(v)
end
emit("")
emit("== Step 2: เรคอร์ดทะเบียน *Prod 0x" .. hex(NDW * 4) .. " ไบต์ | ค่า <1e8 = ฐานสิบ, อื่น ๆ = h+hex ==")
if #cols == 0 then
  emit("(อ่านเรคอร์ดไม่ได้เลย)")
else
  local hd2 = "ออฟเซ็ต"
  for _, c in ipairs(cols) do hd2 = hd2 .. "\t" .. c[1] end
  emit(hd2)
  for k = 1, NDW do
    local nz, same, first = false, true, cols[1][2][k]
    for _, c in ipairs(cols) do
      local v = c[2][k]
      if v ~= 0 then nz = true end
      if v ~= first then same = false end
    end
    if nz then
      local line = "+0x" .. hex((k - 1) * 4) .. (same and " =" or "")
      for _, c in ipairs(cols) do line = line .. "\t" .. cell(c[2][k]) end
      emit(line)
    end
  end
end

-- ── Step 3: ตามตัวชี้ในเรคอร์ด WoodProd ──
emit("")
emit("== Step 3: ตัวชี้ในเรคอร์ด WoodProd -> ปลายทาง 16 dword (ตัวชี้เข้า libsimcity.so แสดงเป็น lib+offset) ==")
if not woodW then
  emit("(ไม่มีเรคอร์ด WoodProd)")
else
  local nfollow = 0
  for k = 1, NDW - 1, 2 do
    local lo, hi = woodW[k], woodW[k + 1]
    if lo and hi and lo ~= 0 and hi >= 0x70 and hi <= 0x7F then
      local p = lo + hi * 4294967296
      local off = (k - 1) * 4
      if p >= base and p < libEnd then
        emit("+0x" .. hex(off) .. " -> lib+0x" .. hex(p - base))
      elseif nfollow < MAXFOLLOW then
        nfollow = nfollow + 1
        local d = readLoose(p, 16)
        local s = {}
        if d then for j = 1, #d do s[j] = cell(d[j]) end end
        emit("+0x" .. hex(off) .. " -> 0x" .. hex(p) .. " : " .. (d and table.concat(s, " ") or "(อ่านไม่ได้)"))
      end
    end
  end
  emit("(ตามตัวชี้ไป " .. nfollow .. " ตัว)")
end

finish("qty_probe3 เสร็จ\n\n")
