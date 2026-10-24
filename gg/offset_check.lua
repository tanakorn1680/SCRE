-- offset_check.lua | GameGuardian (LuaJ / Lua 5.1) | อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- ตรวจว่า offset จาก Ghidra (strings.tsv / functions.tsv) ตรงกับเกมที่รันอยู่จริง
-- วิธีใช้: เปิดเกม -> ใน GG เลือกโปรเซสเกม -> รันสคริปต์นี้ -> อ่านผลในหน้าต่าง (และคัดลอกลง clipboard ให้)
-- ใช้ได้กับเกมเวอร์ชัน 1.83.3 (versionCode 1083003) เท่านั้น

local LIB = "libsimcity.so"
local EXPECT_VERSION_CODE = 1083003

-- {offset ของสตริง, ข้อความที่ต้องอยู่ตรงนั้น}  จาก strings.tsv
local STR_TESTS = {
  { 0x1cfa805, "xp_total" },
  { 0x1cde0c2, "wallet_size" },
  { 0x1cdeeb5, "walletCap" },
  { 0x1ce409e, "CityStorageSize" },
  { 0x1cfb6f1, "storage_level" },
  { 0x1cfd702, "Player Level" },
}

-- {offset ของฟังก์ชัน, ที่มา}  ต้องอยู่ในช่วงที่รันโค้ดได้ (r-x) และเรียงตาม 4 ไบต์
local FUNC_TESTS = {
  { 0x1be4878, "อ้าง xp_total" },
  { 0x10b8494, "อ้าง wallet_size" },
  { 0x1a21b6c, "อ้าง walletCap" },
  { 0xa7e64c,  "อ้าง CityStorageSize" },
  { 0x7c2f30,  "อ้าง storage_level" },
  { 0x1b92274, "อ้าง Player Level" },
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

local ranges = gg.getRangesList(LIB)
if not ranges or #ranges == 0 then
  gg.alert("ไม่พบโมดูล " .. LIB .. "\nเปิดเกมก่อน แล้วเลือกโปรเซสเกมใน GG")
  os.exit()
end

local base = nil
for i = 1, #ranges do
  if not base or ranges[i].start < base then base = ranges[i].start end
end

local function readBytes(addr, n)
  local req = {}
  for i = 0, n - 1 do
    req[#req + 1] = { address = addr + i, flags = gg.TYPE_BYTE }
  end
  local ok, res = pcall(gg.getValues, req)
  if not ok or not res then return nil end
  local out = {}
  for i = 1, #res do
    local v = res[i].value
    if v == nil then return nil end
    out[i] = v % 256
  end
  return out
end

local function execInfo(addr)
  for i = 1, #ranges do
    local r = ranges[i]
    if addr >= r.start and addr < r["end"] then
      local t = r.type or "?"
      return t:sub(3, 3) == "x", t
    end
  end
  return false, "นอกโมดูล"
end

-- ถ้าสตริงไม่ตรงทุกตัว ลองค้นข้อความจริงในโมดูลเพื่อดูว่าเลื่อนไปเท่าไร
local function findOffsets(s)
  gg.clearResults()
  gg.setRanges(gg.REGION_CODE_APP + gg.REGION_C_DATA + gg.REGION_OTHER)
  gg.searchNumber(":" .. s, gg.TYPE_BYTE)
  local n = gg.getResultsCount()
  local res = gg.getResults(math.min(n, 30))
  local found = {}
  for i = 1, #res do
    local a = res[i].address
    for j = 1, #ranges do
      local r = ranges[j]
      if a >= r.start and a < r["end"] then
        found[#found + 1] = a - base
        break
      end
    end
  end
  gg.clearResults()
  return found
end

local lines = {}
local ok, info = pcall(gg.getTargetInfo)
if ok and info then
  lines[#lines + 1] = "เกม: " .. tostring(info.packageName) .. " v" .. tostring(info.versionName) .. " (" .. tostring(info.versionCode) .. ")"
  if info.versionCode ~= EXPECT_VERSION_CODE then
    lines[#lines + 1] = "!! เวอร์ชันไม่ตรงกับที่วิเคราะห์ (" .. EXPECT_VERSION_CODE .. ") offset อาจใช้ไม่ได้"
  end
end
lines[#lines + 1] = "base " .. LIB .. " = 0x" .. hex(base)
lines[#lines + 1] = ""

local strOk = 0
lines[#lines + 1] = "[สตริง]"
for i = 1, #STR_TESTS do
  local off, s = STR_TESTS[i][1], STR_TESTS[i][2]
  local b = readBytes(base + off, #s + 1)
  local good = false
  if b then
    good = (b[#s + 1] == 0)
    for k = 1, #s do
      if b[k] ~= s:byte(k) then good = false end
    end
  end
  if good then strOk = strOk + 1 end
  lines[#lines + 1] = (good and "OK   " or "FAIL ") .. "0x" .. hex(off) .. "  " .. s
end
lines[#lines + 1] = "ตรง " .. strOk .. "/" .. #STR_TESTS

if strOk == 0 then
  local first = STR_TESTS[1]
  local found = findOffsets(first[2])
  lines[#lines + 1] = ""
  lines[#lines + 1] = "ไม่ตรงเลย -> ค้น \"" .. first[2] .. "\" ในโมดูลเจอที่ offset:"
  if #found == 0 then
    lines[#lines + 1] = "(ไม่เจอ: อาจเป็นคนละเวอร์ชันหรือคนละไฟล์ .so)"
  else
    for i = 1, #found do
      local d = found[i] - first[1]
      local sign = "+"
      if d < 0 then sign = "-"; d = -d end
      lines[#lines + 1] = "0x" .. hex(found[i]) .. "  (ต่างจาก Ghidra " .. sign .. "0x" .. hex(d) .. ")"
    end
  end
end

lines[#lines + 1] = ""
lines[#lines + 1] = "[ฟังก์ชัน]"
local fnOk = 0
for i = 1, #FUNC_TESTS do
  local off, why = FUNC_TESTS[i][1], FUNC_TESTS[i][2]
  local isExec, t = execInfo(base + off)
  local good = isExec and (off % 4 == 0)
  if good then fnOk = fnOk + 1 end
  lines[#lines + 1] = (good and "OK   " or "FAIL ") .. "0x" .. hex(off) .. "  " .. why .. "  [" .. t .. "]"
end
lines[#lines + 1] = "ถูกต้อง " .. fnOk .. "/" .. #FUNC_TESTS

lines[#lines + 1] = ""
if strOk == #STR_TESTS and fnOk == #FUNC_TESTS then
  lines[#lines + 1] = "สรุป: offset จาก Ghidra ตรงกับเกมที่รันอยู่ ใช้ base + offset ได้"
else
  lines[#lines + 1] = "สรุป: ยังไม่ตรงทั้งหมด ดูบรรทัด FAIL ด้านบน"
end

local text = table.concat(lines, "\n")
pcall(gg.copyText, text, false)
gg.alert(text)
