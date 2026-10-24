-- registry_walk.lua (v2) | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- ผลรอบแรกบอกว่า singleton ที่ base+0x23e6318 ไม่ได้ถือ std::map แต่เป็น hash table (unordered_map) ที่ +8:
--   +8 = ตัวชี้ bucket, +0x10 = จำนวน bucket, +0x18 = โหนดแรก, +0x20 = จำนวนรายการ
--   โหนด: +0 = ตัวถัดไป, +0x10 = คีย์ (สตริง 24 ไบต์), +0x28 = ตัวชี้ "ข้อมูลไอเท็ม"
-- สคริปต์เดินทุกโหนด อ่านชื่อคีย์ + หน้าต่างข้อมูลไอเท็ม แล้วหาลายนิ้วมือที่ runXp() ใช้ (16, 60000, 1, 5000)
-- วิธีใช้: เข้าเมืองให้เต็ม -> เลือกโปรเซสเกมใน GG -> รัน -> ส่งข้อความผลลัพธ์ (อยู่ใน clipboard ด้วย) และไฟล์ registry_walk.txt

local LIB = "libsimcity.so"
local G_OFF = 0x23e6318
local WIN = 0x300
local MAX_NODES = 20000
local V_TIME, V_PRICE = 60000, 5000
local V_A, V_B = 16, 1

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

-- คีย์เป็น std::string แบบ libc++ (24 ไบต์) ที่ node+0x10
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
local buckets = readPtr(T)
local bcount = readU32(T + 8)
local first = readPtr(T + 0x10)
local size = readU32(T + 0x18)
emit("singleton = 0x" .. hex(P))
emit("hash: buckets=0x" .. hex(buckets or 0) .. " bucket_count=" .. tostring(bcount) .. " first=0x" .. hex(first or 0) .. " size=" .. tostring(size))

local entries = {}
local node = first
local guard = 0
while not isNull(node) and guard < MAX_NODES do
  guard = guard + 1
  entries[#entries + 1] = { node = node, val = readPtr(node + 0x28) }
  node = readPtr(node)
  if guard % 500 == 0 then gg.toast("เดินโหนด " .. guard) end
end
emit("เดินได้ " .. #entries .. " โหนด (size ที่เกมบอก " .. tostring(size) .. ")")
if #entries == 0 then
  emit("เดินไม่ได้: ส่งข้อความนี้กลับมาให้ปรับ")
  local text = table.concat(lines, "\n")
  pcall(gg.copyText, text, false)
  gg.alert(text)
  os.exit()
end

local readable, matches = 0, {}
local full = {}
for i = 1, #entries do
  local e = entries[i]
  e.key = readKey(e.node)
  full[#full + 1] = i .. "\t" .. e.key .. "\tnode=0x" .. hex(e.node) .. "\tdata=0x" .. hex(e.val or 0)
  if not isNull(e.val) then
    local w = readWindow(e.val, WIN)
    if w then
      readable = readable + 1
      local o60, o5, o16, o1 = nil, nil, nil, nil
      for k = 1, #w do
        local v, off = w[k], (k - 1) * 4
        if v == V_TIME and not o60 then o60 = off end
        if v == V_A and not o16 then o16 = off end
        if v == V_B and not o1 then o1 = off end
      end
      if o60 then
        for k = 1, #w do
          local off = (k - 1) * 4
          if w[k] == V_PRICE and off > o60 and not o5 then o5 = off end
        end
      end
      if o60 and o5 then
        matches[#matches + 1] = { e = e, o60 = o60, o5 = o5, o16 = o16, o1 = o1, xp = w[(o5 - 4) / 4 + 1] }
      end
    end
  end
  if i % 100 == 0 then gg.toast("สแกน " .. i .. "/" .. #entries) end
end

emit("อ่านข้อมูลได้ " .. readable .. " ชิ้น | ตรงลายนิ้วมือ (60000 แล้ว 5000) " .. #matches .. " ชิ้น")
emit("")
emit("ตัวอย่างคีย์ 8 ตัวแรก:")
for i = 1, math.min(8, #entries) do emit("  " .. entries[i].key) end
emit("")
local mlines = {}
for i = 1, #matches do
  local m = matches[i]
  local l = "#" .. i .. " " .. m.e.key .. " data=0x" .. hex(m.e.val) ..
    "  60000@+0x" .. hex(m.o60) .. "  5000@+0x" .. hex(m.o5) ..
    "  16@" .. (m.o16 and ("+0x" .. hex(m.o16)) or "-") .. "  1@" .. (m.o1 and ("+0x" .. hex(m.o1)) or "-") ..
    "  [5000-4]=" .. tostring(m.xp) .. " @+0x" .. hex(m.o5 - 4)
  mlines[#mlines + 1] = l
  if i <= 6 then emit(l) end
end

local cnt = {}
for i = 1, #matches do
  local key = "60000@+0x" .. hex(matches[i].o60) .. " 5000@+0x" .. hex(matches[i].o5)
  cnt[key] = (cnt[key] or 0) + 1
end
emit("")
emit("offset ที่พบซ้ำ:")
for k, v in pairs(cnt) do emit("  " .. k .. "  x" .. v) end
emit("")
emit("สายพอยน์เตอร์: base+0x" .. hex(G_OFF) .. " -> singleton; +8 = hash table; โหนด+0x28 = ข้อมูลไอเท็ม (ยังไม่ยืนยันว่าตรงกับของ runXp)")

local text = table.concat(lines, "\n")
local out = text .. "\n\n== ตรงลายนิ้วมือทั้งหมด ==\n" .. table.concat(mlines, "\n") .. "\n\n== รายการทั้งหมด ==\n" .. table.concat(full, "\n") .. "\n"
local dirs = { gg.EXT_STORAGE, gg.EXT_FILES_DIR, gg.FILES_DIR }
for i = 1, 3 do
  if dirs[i] then
    local ok, f = pcall(io.open, dirs[i] .. "/registry_walk.txt", "w")
    if ok and f then
      f:write(out)
      f:close()
      text = text .. "\nไฟล์เต็ม: " .. dirs[i] .. "/registry_walk.txt"
      break
    end
  end
end
pcall(gg.copyText, text, false)
gg.alert(text)
