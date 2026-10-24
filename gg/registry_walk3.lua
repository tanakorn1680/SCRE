-- registry_walk.lua (v3) | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- ยืนยันแล้วจากผลรัน v2 (เกม 1.83.3): base+0x23e6318 -> singleton; +8 = hash table ของ "ข้อมูลทุกอย่างในเกม" (~23,805 รายการ)
--   โหนดแรกที่ singleton+0x20, ตัวถัดไปที่ node+0; node+0x10 = คีย์ (std::string 24 ไบต์), node+0x28 = ตัวชี้ข้อมูล
--   คีย์ที่ลงท้าย "Prod" คือข้อมูลการผลิตของไอเท็ม (เช่น MetalProd)  ลายนิ้วมือ runXp (16, 60000, 1, 5000) ตรงกับ MetalProd
--   60000@+0xA8, 5000@+0x244, ฟิลด์ที่ runXp แก้ = (ตำแหน่ง 5000)-4 = +0x240
-- v3: เดินให้ครบทุกโหนด, อ่านเฉพาะคีย์ "Prod" แล้วทำตารางค่าฟิลด์สำคัญของทุกไอเท็ม เพื่อดูว่าโครงสร้างเหมือนกันทุกชิ้นไหม
-- วิธีใช้: เข้าเมืองให้เต็ม -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งไฟล์ registry_prod.txt (และข้อความในหน้าต่าง)

local LIB = "libsimcity.so"
local G_OFF = 0x23e6318
local MAX_NODES = 40000
local WIN = 0x300
local SUFFIX = "Prod"
local FIELDS = { 0x20, 0xA8, 0x238, 0x23C, 0x240, 0x244, 0x248 }

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
local function u32(v)
  if v < 0 then return v + 4294967296 end
  return v
end
local function s32(v)
  if v >= 2147483648 then return v - 4294967296 end
  return v
end

local ranges = gg.getRangesList(LIB)
if not ranges or #ranges == 0 then
  gg.alert("ไม่พบโมดูล " .. LIB .. "\nเปิดเกมก่อน แล้วเลือกโปรเซสเกมใน GG")
  os.exit()
end
local base = nil
for i = 1, #ranges do
  if not base or ranges[i].start < base then base = ranges[i].start end
end

local function readU32(addr)
  local ok, r = pcall(gg.getValues, { { address = addr, flags = gg.TYPE_DWORD } })
  if not ok or not r or not r[1] or r[1].value == nil then return nil end
  return u32(r[1].value)
end

local function readPtr(addr)
  local lo = readU32(addr)
  local hi = readU32(addr + 4)
  if not lo or not hi then return nil end
  return lo + (hi % 16777216) * 4294967296
end

local function isNull(a) return a == nil or a == 0 end

local function readWindow(addr, bytes)
  local req = {}
  for i = 0, bytes / 4 - 1 do
    req[#req + 1] = { address = addr + i * 4, flags = gg.TYPE_DWORD }
  end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local w = {}
  for i = 1, #res do
    if res[i].value == nil then return nil end
    w[i] = u32(res[i].value)
  end
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

local function readKey(node)
  local s = node + 0x10
  local ok, r = pcall(gg.getValues, { { address = s, flags = gg.TYPE_BYTE } })
  if not ok or not r or not r[1] or r[1].value == nil then return "?" end
  local b0 = r[1].value % 256
  if b0 % 2 == 0 then
    local len = b0 / 2
    if len > 22 then return "?" end
    return readText(s + 1, len) or "?"
  end
  local len = readU32(s + 8)
  local p = readPtr(s + 0x10)
  if not len or isNull(p) or len > 200 then return "?" end
  if len > 48 then len = 48 end
  return readText(p, len) or "?"
end

local lines = {}
local function emit(s) lines[#lines + 1] = s end

emit("base " .. LIB .. " = 0x" .. hex(base))
local P = readPtr(base + G_OFF)
if isNull(P) then
  emit("singleton ยังเป็นค่าว่าง (เข้าเมืองให้เต็มก่อน) หรือ offset ไม่ตรงเวอร์ชัน")
  local text = table.concat(lines, "\n")
  pcall(gg.copyText, text, false)
  gg.alert(text)
  os.exit()
end

local T = P + 8
local first = readPtr(T + 0x10)
local size = readU32(T + 0x18)
emit("singleton = 0x" .. hex(P) .. "  size(เกมบอก) = " .. tostring(size))

local node = first
local guard = 0
local total = 0
local rows = {}
while not isNull(node) and guard < MAX_NODES do
  guard = guard + 1
  total = total + 1
  local key = readKey(node)
  if #key >= #SUFFIX and key:sub(-#SUFFIX) == SUFFIX then
    local val = readPtr(node + 0x28)
    local w = nil
    if not isNull(val) then w = readWindow(val, WIN) end
    rows[#rows + 1] = { key = key, val = val, w = w }
  end
  node = readPtr(node)
  if guard % 500 == 0 then gg.toast("เดินโหนด " .. guard .. "/" .. tostring(size)) end
end
emit("เดินได้ " .. total .. " โหนด | คีย์ลงท้าย \"" .. SUFFIX .. "\": " .. #rows .. " รายการ")
emit("")

local head = "key"
for i = 1, #FIELDS do head = head .. "\t+0x" .. hex(FIELDS[i]) end
local out = { head }
local shown = 0
for i = 1, #rows do
  local r = rows[i]
  local cells = { r.key }
  for j = 1, #FIELDS do
    local v = "?"
    if r.w then
      local x = r.w[FIELDS[j] / 4 + 1]
      if x ~= nil then v = tostring(s32(x)) end
    end
    cells[#cells + 1] = v
  end
  local line = table.concat(cells, "\t")
  out[#out + 1] = line
  if shown < 14 then
    emit(table.concat(cells, " | "))
    shown = shown + 1
  end
end
emit("")
emit("คอลัมน์: " .. head:gsub("\t", " | "))

local text = table.concat(lines, "\n")
local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
for i = 1, 3 do
  if dirs[i] then
    local ok, f = pcall(io.open, dirs[i] .. "/registry_prod.txt", "w")
    if ok and f then
      f:write(text .. "\n\n" .. table.concat(out, "\n") .. "\n")
      f:close()
      text = text .. "\nไฟล์เต็ม: " .. dirs[i] .. "/registry_prod.txt"
      break
    end
  end
end
pcall(gg.copyText, text, false)
gg.alert(text)
