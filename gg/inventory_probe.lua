-- inventory_probe.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- ตรวจ pointer chain ที่ได้จาก Ghidra (เวอร์ชันเกม 1.83.3 / 1083003):
--   base + 0x23e6318  ->  ตัวชี้ singleton ของออบเจ็กต์ที่โหลดค่า "InventorySettings"
--   ออบเจ็กต์ขนาด 0xd0, ไบต์แรกเป็น vtable (base + 0x2297d40)
--   ฟิลด์ที่เติมตอนโหลดค่า (ฟิลด์ละ 0x18 ไบต์): +0x80 CityStorageSize, +0x98 MaterialStorageSize, +0xb0 FutureStorageSize
-- วิธีใช้: เปิดเกมจนเข้าเมือง -> เลือกโปรเซสเกมใน GG -> รันสคริปต์ -> ส่งข้อความผลลัพธ์ (อยู่ใน clipboard ด้วย)

local LIB = "libsimcity.so"
local G_OFF  = 0x23e6318
local VT_OFF = 0x2297d40
local OBJ_SIZE = 0xd0
local FIELDS = {
  { 0x80, "CityStorageSize" },
  { 0x98, "MaterialStorageSize" },
  { 0xb0, "FutureStorageSize" },
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
local function hex2(n)
  local h = hex(n)
  if #h < 2 then h = "0" .. h end
  return h
end
local function u32(v)
  if v < 0 then return v + 4294967296 end
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

-- อ่านพอยน์เตอร์ 64 บิตแบบไม่เสียความแม่นยำ และตัดแท็กไบต์บนสุดออก
local function readPtr(addr)
  local lo = readU32(addr)
  local hi = readU32(addr + 4)
  if not lo or not hi then return nil end
  local tag = math.floor(hi / 16777216)
  local a = lo + (hi % 16777216) * 4294967296
  return a, tag
end

local function readBytes(addr, n)
  local req = {}
  for i = 0, n - 1 do req[#req + 1] = { address = addr + i, flags = gg.TYPE_BYTE } end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local out = {}
  for i = 1, #res do
    if res[i].value == nil then return nil end
    out[i] = res[i].value % 256
  end
  return out
end

local lines = {}
lines[#lines + 1] = "base " .. LIB .. " = 0x" .. hex(base)

local gaddr = base + G_OFF
local P, tag = readPtr(gaddr)
lines[#lines + 1] = "global @0x" .. hex(gaddr) .. " -> ptr " .. (P and ("0x" .. hex(P) .. " (tag 0x" .. hex(tag) .. ")") or "อ่านไม่ได้")
if not P or P == 0 then
  lines[#lines + 1] = "พอยน์เตอร์ว่าง: ยังไม่ถูกสร้าง (เข้าเมืองให้เต็มก่อน) หรือ offset ไม่ตรงเวอร์ชัน"
  local text = table.concat(lines, "\n")
  pcall(gg.copyText, text, false)
  gg.alert(text)
  os.exit()
end

local vt = readPtr(P)
local vtOk = (vt == base + VT_OFF)
lines[#lines + 1] = "vtable @obj+0 = " .. (vt and ("0x" .. hex(vt)) or "?") .. (vtOk and "  OK (ตรงกับ base+0x" .. hex(VT_OFF) .. ")" or "  ไม่ตรง (คาด 0x" .. hex(base + VT_OFF) .. ")")
lines[#lines + 1] = ""

for i = 1, #FIELDS do
  local off, name = FIELDS[i][1], FIELDS[i][2]
  local b = readBytes(P + off, 24)
  lines[#lines + 1] = "[+0x" .. hex(off) .. "] " .. name
  if b then
    local h = {}
    for k = 1, 24 do h[k] = hex2(b[k]) end
    lines[#lines + 1] = "  bytes: " .. table.concat(h, " ", 1, 8) .. " | " .. table.concat(h, " ", 9, 16) .. " | " .. table.concat(h, " ", 17, 24)
    local d = {}
    for k = 0, 5 do
      local v = b[k * 4 + 1] + b[k * 4 + 2] * 256 + b[k * 4 + 3] * 65536 + b[k * 4 + 4] * 16777216
      d[#d + 1] = tostring(v)
    end
    lines[#lines + 1] = "  dword x6: " .. table.concat(d, ", ")
    -- เดาว่าเป็น std::string แบบ libc++ (24 ไบต์)
    if b[1] % 2 == 0 then
      local len = b[1] / 2
      local s = ""
      if len <= 22 then
        for k = 1, len do
          local c = b[1 + k]
          if c >= 32 and c < 127 then s = s .. string.char(c) else s = s .. "." end
        end
        lines[#lines + 1] = "  ถ้าเป็นสตริงสั้น: \"" .. s .. "\" (len " .. len .. ")"
      end
    else
      local sz = b[9] + b[10] * 256 + b[11] * 65536 + b[12] * 16777216
      lines[#lines + 1] = "  ถ้าเป็นสตริงยาว: ขนาด " .. sz
    end
  else
    lines[#lines + 1] = "  อ่านไม่ได้"
  end
end

lines[#lines + 1] = ""
lines[#lines + 1] = "หมายเหตุ: นี่เป็นค่าที่โหลดจากไฟล์ตั้งค่า (limit ของเกม) ยังไม่ยืนยันว่าเป็นตัวกำหนดความจุจริง"
local text = table.concat(lines, "\n")
pcall(gg.copyText, text, false)
gg.alert(text)
