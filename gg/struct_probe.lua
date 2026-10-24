-- struct_probe.lua  |  GameGuardian (LuaJ / Lua 5.1)
-- อ่านอย่างเดียว: ไม่แก้ค่าในเกมเลย
-- หา "field offset" ในโครงสร้างข้อมูล: offset = ที่อยู่ของฟิลด์ - ที่อยู่ของค่าที่ค้นเจอ
--
-- ขั้นตอน (ตัวอย่างหา offset รอบ ๆ ค่า XP):
--  1) เมนู 1 ค้นค่า XP ปัจจุบัน  -> ไปเปลี่ยนค่าในเกม -> เมนู 2 Refine  (ทำซ้ำจนเหลือไม่เกิน MAX_HITS)
--  2) เมนู 3 เก็บ Snapshot  (ได้ไฟล์ dump ทุก offset รอบ ๆ ผลลัพธ์ = Snapshot A)
--  3) ไปทำให้ XP เปลี่ยนในเกม (เช่น เก็บของ/ส่งของ) -> เมนู 2 Refine ด้วยค่าใหม่
--  4) เมนู 3 เก็บ Snapshot อีกครั้ง (= Snapshot B)
--  5) เมนู 4 เทียบ A กับ B -> ได้รายการ offset ที่เปลี่ยนตาม พร้อมไฟล์รายงาน

local CFG = {
  BEFORE   = 0x80,   -- อ่านย้อนหลังกี่ไบต์จากที่อยู่ที่ค้นเจอ
  AFTER    = 0x80,   -- อ่านไปข้างหน้ากี่ไบต์
  MAX_HITS = 40,     -- เก็บ snapshot ได้เมื่อผลลัพธ์ไม่เกินจำนวนนี้
  REGIONS  = gg.REGION_ANONYMOUS + gg.REGION_C_ALLOC,  -- ปรับตามที่สคริปต์เดิมใช้
}

local S = {}                 -- รายการ snapshot
local lastType = gg.TYPE_DWORD

-- ---------- ตัวช่วย ----------
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

local function hexoff(o)
  if o < 0 then return "-0x" .. hex(-o) end
  return "+0x" .. hex(o)
end

local function u32(v)
  if v < 0 then return v + 4294967296 end
  return v
end

local function plausibleFloat(f)
  if f == nil or f ~= f then return false end
  local a = math.abs(f)
  return a >= 0.0001 and a <= 1000000000
end

-- เดาว่าเป็น pointer (arm64 Android: 0x7xxxxxxxxx หรือมีแท็ก 0xb4......7x)
local function looksPtr(lo, hi)
  if lo == 0 then return false end
  if hi >= 0x70 and hi <= 0x7f then return true end
  if hi >= 0xb4000070 and hi <= 0xb400007f then return true end
  return false
end

local function writeFile(name, text)
  local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
  for i = 1, 3 do
    local d = dirs[i]
    if d then
      local path = d .. "/" .. name
      local ok, f = pcall(io.open, path, "w")
      if ok and f then
        f:write(text)
        f:close()
        return path
      end
    end
  end
  return nil
end

local function header()
  local t = "# struct_probe\n"
  local ok, info = pcall(gg.getTargetInfo)
  if ok and info then
    t = t .. "# package: " .. tostring(info.packageName) .. "  version: " .. tostring(info.versionName) .. " (" .. tostring(info.versionCode) .. ")\n"
  end
  local ok2, r = pcall(gg.getRangesList, "libsimcity.so")
  if ok2 and r and r[1] then
    t = t .. "# libsimcity.so start: 0x" .. hex(r[1].start) .. "\n"
  end
  return t .. "# offset 0 = ที่อยู่ของค่าที่ค้นเจอ  |  offset ใช้ได้เฉพาะเวอร์ชันเกมข้างบน\n\n"
end

-- ---------- อ่านหน้าต่างหน่วยความจำรอบ ๆ ที่อยู่ ----------
local function readWindow(addr)
  local reqD, reqF, offs = {}, {}, {}
  local o = -CFG.BEFORE
  while o < CFG.AFTER do
    offs[#offs + 1] = o
    reqD[#reqD + 1] = { address = addr + o, flags = gg.TYPE_DWORD }
    reqF[#reqF + 1] = { address = addr + o, flags = gg.TYPE_FLOAT }
    o = o + 4
  end
  local okD, rd = pcall(gg.getValues, reqD)
  if not okD or not rd then return nil end
  local okF, rf = pcall(gg.getValues, reqF)
  local w = {}
  for i = 1, #offs do
    local d = rd[i] and rd[i].value
    local f = nil
    if okF and rf and rf[i] then f = rf[i].value end
    if d ~= nil then w[offs[i]] = { d = d, f = f } end
  end
  return w
end

-- ---------- เมนู 1: ค้นหาใหม่ ----------
local function newSearch()
  local p = gg.prompt({ "ค่าที่จะค้น (เช่น 1500 หรือ 1000~2000)" }, { "" }, { "text" })
  if not p or p[1] == "" then return end
  local t = gg.choice({ "DWORD (ปกติ)", "FLOAT", "QWORD", "DOUBLE" }, 1, "ชนิดข้อมูล")
  if not t then return end
  local types = { gg.TYPE_DWORD, gg.TYPE_FLOAT, gg.TYPE_QWORD, gg.TYPE_DOUBLE }
  lastType = types[t]
  gg.clearResults()
  gg.setRanges(CFG.REGIONS)
  gg.toast("กำลังค้นหา...")
  gg.searchNumber(p[1], lastType)
  gg.toast("เจอ " .. gg.getResultsCount() .. " ที่อยู่")
end

-- ---------- เมนู 2: Refine ----------
local function refine()
  if gg.getResultsCount() == 0 then
    gg.alert("ยังไม่มีผลลัพธ์ ให้ค้นใหม่ก่อน (เมนู 1)")
    return
  end
  local p = gg.prompt({ "ค่าใหม่ในเกมตอนนี้" }, { "" }, { "text" })
  if not p or p[1] == "" then return end
  gg.searchNumber(p[1], lastType)
  gg.toast("เหลือ " .. gg.getResultsCount() .. " ที่อยู่")
end

-- ---------- เมนู 3: Snapshot + dump ----------
local function dumpText(snap)
  local out = { header(), "## Snapshot " .. snap.label .. "\n" }
  for _, addr in ipairs(snap.order) do
    local w = snap.hits[addr]
    out[#out + 1] = "== 0x" .. hex(addr) .. " ==\n"
    for o = -CFG.BEFORE, CFG.AFTER - 4, 4 do
      local c = w[o]
      if c then
        local line = hexoff(o) .. "  dword=" .. c.d .. " (0x" .. hex(u32(c.d)) .. ")"
        if plausibleFloat(c.f) then line = line .. "  float=" .. c.f end
        local n = w[o + 4]
        if n and looksPtr(u32(c.d), u32(n.d)) then line = line .. "  ptr?" end
        out[#out + 1] = line .. "\n"
      end
    end
    out[#out + 1] = "\n"
  end
  return table.concat(out)
end

local function snapshot()
  local n = gg.getResultsCount()
  if n == 0 then
    gg.alert("ยังไม่มีผลลัพธ์")
    return
  end
  if n > CFG.MAX_HITS then
    gg.alert("ผลลัพธ์ยังเยอะ (" .. n .. ") ให้เปลี่ยนค่าในเกมแล้ว Refine ต่อจนเหลือไม่เกิน " .. CFG.MAX_HITS)
    return
  end
  local res = gg.getResults(n)
  local snap = { label = string.char(64 + #S + 1), hits = {}, order = {} }
  for i = 1, #res do
    local w = readWindow(res[i].address)
    if w then
      snap.hits[res[i].address] = w
      snap.order[#snap.order + 1] = res[i].address
    end
  end
  S[#S + 1] = snap
  local path = writeFile("struct_probe_snap" .. snap.label .. ".txt", dumpText(snap))
  gg.alert("Snapshot " .. snap.label .. ": " .. #snap.order .. " ที่อยู่\n" .. (path and ("ไฟล์: " .. path) or "เขียนไฟล์ไม่ได้ (ดูผลในเมนูเทียบแทน)"))
end

-- ---------- เมนู 4: เทียบ ----------
local function compare()
  if #S < 2 then
    gg.alert("ต้องมี Snapshot อย่างน้อย 2 อัน (ก่อน/หลังค่าเปลี่ยน)")
    return
  end
  local labels = {}
  for i = 1, #S do labels[i] = "Snapshot " .. S[i].label end
  local a = gg.choice(labels, #S - 1, "ก่อน (A)")
  if not a then return end
  local b = gg.choice(labels, #S, "หลัง (B)")
  if not b or a == b then return end
  local A, B = S[a], S[b]

  local common = {}
  for _, addr in ipairs(A.order) do
    if B.hits[addr] then common[#common + 1] = addr end
  end
  if #common == 0 then
    gg.alert("ไม่มีที่อยู่ร่วมกัน ให้เก็บ A ก่อนเปลี่ยนค่าในเกม แล้ว Refine ก่อนเก็บ B")
    return
  end

  local lines = {}
  for o = -CFG.BEFORE, CFG.AFTER - 4, 4 do
    local changed, same, ex1, ex2, f1, f2, d0 = 0, 0, nil, nil, nil, nil, nil
    for _, addr in ipairs(common) do
      local ca, cb = A.hits[addr][o], B.hits[addr][o]
      if ca and cb and ca.d ~= cb.d then
        changed = changed + 1
        local delta = cb.d - ca.d
        if d0 == nil then
          d0, ex1, ex2, f1, f2 = delta, ca.d, cb.d, ca.f, cb.f
        end
        if delta == d0 then same = same + 1 end
      end
    end
    if changed > 0 then
      local line = hexoff(o) .. "  " .. ex1 .. " -> " .. ex2 .. "  (d=" .. d0 .. ")  เปลี่ยน " .. changed .. "/" .. #common .. "  delta เท่ากัน " .. same
      if plausibleFloat(f1) and plausibleFloat(f2) then
        line = line .. "  float " .. f1 .. " -> " .. f2
      end
      lines[#lines + 1] = line
    end
  end

  local text = header() .. "## เทียบ " .. A.label .. " -> " .. B.label .. "  (ที่อยู่ร่วมกัน " .. #common .. ")\n"
    .. "## offset ที่ 'เปลี่ยน' และ 'delta เท่ากัน' สูง ๆ มักเป็นฟิลด์จริง\n\n"
    .. table.concat(lines, "\n") .. "\n"
  local path = writeFile("struct_probe_diff" .. A.label .. B.label .. ".txt", text)

  local preview = table.concat(lines, "\n", 1, math.min(#lines, 15))
  if #lines == 0 then preview = "(ไม่มี offset ที่เปลี่ยน)" end
  gg.alert("พบ " .. #lines .. " offset ที่เปลี่ยน\n\n" .. preview .. "\n\n" .. (path and ("ไฟล์: " .. path) or ""))
end

-- ---------- เมนูหลัก ----------
local function mainMenu()
  local m = gg.choice({
    "1) ค้นหาค่าใหม่",
    "2) Refine (หลังค่าในเกมเปลี่ยน)",
    "3) เก็บ Snapshot รอบ ๆ ผลลัพธ์",
    "4) เทียบ Snapshot -> หา offset",
    "5) ออก",
  }, nil, "Struct Probe (อ่านอย่างเดียว)")
  if m == 1 then newSearch()
  elseif m == 2 then refine()
  elseif m == 3 then snapshot()
  elseif m == 4 then compare()
  elseif m == 5 then os.exit() end
end

gg.showUiButton()
gg.toast("Struct Probe พร้อม — กดไอคอน GG")
while true do
  if gg.isClickedUiButton() then mainMenu() end
  gg.sleep(100)
end
