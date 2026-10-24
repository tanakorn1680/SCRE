-- player_scan.lua  |  GameGuardian (LuaJ / Lua 5.1)  |  อ่านอย่างเดียว ไม่แก้ค่าในเกม
-- หาค่าของผู้เล่น (Player Level, SimCash, Simoleons, ขนาดคลัง ฯลฯ) ทีละเป้าหมาย
-- เก็บ Snapshot หลายรอบ แล้วสรุปว่า offset ไหนในโครงสร้างเปลี่ยนตามค่านั้นทุกครั้ง
-- และหา pointer ที่ชี้มาจาก libsimcity.so ได้ (ถ้ามี) เพื่อใช้ซ้ำหลังเปิดเกมใหม่
--
-- วิธีใช้ (ทำซ้ำได้ทุกเป้าหมาย):
--  1) เมนู 1 เลือกเป้าหมาย
--  2) เมนู 2 ใส่ค่าที่เห็นในเกมตอนนี้ (ค้นครั้งแรก) -> ให้ค่าในเกมเปลี่ยน -> เมนู 2 อีกครั้ง (Refine)
--     ทำซ้ำจนเหลือผลลัพธ์ไม่เกิน MAX_HITS
--  3) เมนู 3 เก็บ Snapshot -> ให้ค่าเปลี่ยนอีก -> เมนู 2 -> เมนู 3  (เก็บอย่างน้อย 3 ครั้ง)
--  4) เมนู 4 สรุป offset  (ได้ไฟล์รายงานใน storage)
--  5) เมนู 5 หา pointer จาก libsimcity.so (ทำตอนผลลัพธ์ยังเหลือน้อย)
-- หมายเหตุ: ที่อยู่ heap เปลี่ยนทุกครั้งที่เปิดเกมใหม่ ต้องเก็บทุก Snapshot ในรอบเกมเดียวกัน

local CFG = {
  BEFORE   = 0x80,   -- อ่านย้อนหลังกี่ไบต์จากที่อยู่ที่ค้นเจอ
  AFTER    = 0x80,   -- อ่านไปข้างหน้ากี่ไบต์
  MAX_HITS = 40,     -- เก็บ snapshot ได้เมื่อผลลัพธ์ไม่เกินจำนวนนี้
  REGIONS  = gg.REGION_ANONYMOUS + gg.REGION_C_ALLOC + gg.REGION_C_HEAP,
  PTR_MAX_OFFSET = 0x400,  -- ระยะห่างสูงสุดระหว่าง pointer กับที่อยู่เป้าหมาย
}

local TARGETS = { "Player Level", "SimCash", "Simoleons", "Storage size", "Other" }

local T = {}          -- T[ชื่อเป้าหมาย] = { snaps = {}, addrs = {} }
local cur = TARGETS[1]
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

local function slug(s)
  return (s:gsub("[^%w]", "_"))
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

local function libRanges()
  -- ช่วงของ libsimcity.so (รวมส่วนที่ต่อท้ายแบบไม่มีชื่อ เช่น .bss ถ้า GG แสดง)
  local out = {}
  local ok, all = pcall(gg.getRangesList, "")
  if not ok or not all then
    local ok2, only = pcall(gg.getRangesList, "libsimcity.so")
    if ok2 and only then
      for i = 1, #only do out[#out + 1] = { s = only[i].start, e = only[i]["end"] } end
    end
    return out
  end
  table.sort(all, function(a, b) return a.start < b.start end)
  local inLib, prevEnd = false, nil
  for i = 1, #all do
    local r = all[i]
    local nm = tostring(r.internalName or r.name or "")
    if nm:find("libsimcity.so", 1, true) then
      inLib = true
      out[#out + 1] = { s = r.start, e = r["end"] }
      prevEnd = r["end"]
    elseif inLib and prevEnd == r.start and (nm == "" or nm:find("bss", 1, true)) then
      out[#out + 1] = { s = r.start, e = r["end"] }
      prevEnd = r["end"]
    else
      inLib = false
    end
  end
  return out
end

local function libBase()
  local ok, r = pcall(gg.getRangesList, "libsimcity.so")
  if ok and r and r[1] then return r[1].start end
  return nil
end

local function header()
  local t = "# player_scan  target: " .. cur .. "\n"
  local ok, info = pcall(gg.getTargetInfo)
  if ok and info then
    t = t .. "# package: " .. tostring(info.packageName) .. "  version: " .. tostring(info.versionName) .. " (" .. tostring(info.versionCode) .. ")\n"
  end
  local b = libBase()
  if b then t = t .. "# libsimcity.so start: 0x" .. hex(b) .. "\n" end
  return t .. "# offset 0 = ที่อยู่ของค่าที่ค้นเจอ  |  ใช้ได้เฉพาะเวอร์ชันเกมข้างบน\n\n"
end

local function tgt()
  if not T[cur] then T[cur] = { snaps = {} } end
  return T[cur]
end

-- ---------- อ่านหน้าต่างหน่วยความจำรอบ ๆ ที่อยู่ ----------
local function readWindow(addr)
  local reqD, offs = {}, {}
  local o = -CFG.BEFORE
  while o < CFG.AFTER do
    offs[#offs + 1] = o
    reqD[#reqD + 1] = { address = addr + o, flags = gg.TYPE_DWORD }
    o = o + 4
  end
  local ok, rd = pcall(gg.getValues, reqD)
  if not ok or not rd then return nil end
  local w = {}
  for i = 1, #offs do
    if rd[i] and rd[i].value ~= nil then w[offs[i]] = { d = rd[i].value } end
  end
  return w
end

-- ---------- เมนู 1: เลือกเป้าหมาย ----------
local function pickTarget()
  local labels = {}
  for i = 1, #TARGETS do
    local n = T[TARGETS[i]] and #T[TARGETS[i]].snaps or 0
    labels[i] = TARGETS[i] .. "  (snapshot " .. n .. ")"
  end
  local c = gg.choice(labels, nil, "เลือกเป้าหมาย")
  if c then
    cur = TARGETS[c]
    gg.clearResults()
    gg.toast("เป้าหมาย: " .. cur)
  end
end

-- ---------- เมนู 2: ค้น / Refine ----------
local function searchOrRefine()
  local n = gg.getResultsCount()
  if n == 0 then
    local p = gg.prompt({ "ค่าของ " .. cur .. " ที่เห็นในเกมตอนนี้" }, { "" }, { "text" })
    if not p or p[1] == "" then return end
    local t = gg.choice({ "DWORD (ปกติ)", "QWORD", "FLOAT", "DOUBLE" }, 1, "ชนิดข้อมูล")
    if not t then return end
    local types = { gg.TYPE_DWORD, gg.TYPE_QWORD, gg.TYPE_FLOAT, gg.TYPE_DOUBLE }
    lastType = types[t]
    gg.setRanges(CFG.REGIONS)
    gg.toast("กำลังค้นหา...")
    gg.searchNumber(p[1], lastType)
    gg.toast("เจอ " .. gg.getResultsCount() .. " ที่อยู่")
  else
    local p = gg.prompt({ "ค่าใหม่ในเกมตอนนี้ (Refine, ตอนนี้เหลือ " .. n .. ")" }, { "" }, { "text" })
    if not p or p[1] == "" then return end
    gg.searchNumber(p[1], lastType)
    gg.toast("เหลือ " .. gg.getResultsCount() .. " ที่อยู่")
  end
end

-- ---------- เมนู 3: Snapshot ----------
local function dumpText(snap)
  local out = { header(), "## Snapshot " .. snap.n .. "\n" }
  for _, addr in ipairs(snap.order) do
    local w = snap.hits[addr]
    out[#out + 1] = "== 0x" .. hex(addr) .. " ==\n"
    for o = -CFG.BEFORE, CFG.AFTER - 4, 4 do
      local c = w[o]
      if c then
        out[#out + 1] = hexoff(o) .. "  dword=" .. c.d .. " (0x" .. hex(u32(c.d)) .. ")\n"
      end
    end
    out[#out + 1] = "\n"
  end
  return table.concat(out)
end

local function snapshot()
  local n = gg.getResultsCount()
  if n == 0 then gg.alert("ยังไม่มีผลลัพธ์ (เมนู 2)"); return end
  if n > CFG.MAX_HITS then
    gg.alert("ผลลัพธ์ยังเยอะ (" .. n .. ") ให้เปลี่ยนค่าในเกมแล้ว Refine ต่อจนเหลือไม่เกิน " .. CFG.MAX_HITS)
    return
  end
  local res = gg.getResults(n)
  local t = tgt()
  local snap = { n = #t.snaps + 1, hits = {}, order = {}, value = res[1] and res[1].value }
  for i = 1, #res do
    local w = readWindow(res[i].address)
    if w then
      snap.hits[res[i].address] = w
      snap.order[#snap.order + 1] = res[i].address
    end
  end
  t.snaps[#t.snaps + 1] = snap
  local path = writeFile("player_scan_" .. slug(cur) .. "_snap" .. snap.n .. ".txt", dumpText(snap))
  gg.alert("Snapshot " .. snap.n .. " ของ " .. cur .. ": " .. #snap.order .. " ที่อยู่\n"
    .. (path and ("ไฟล์: " .. path) or "เขียนไฟล์ไม่ได้") .. "\n\nให้ค่าในเกมเปลี่ยน แล้วเมนู 2 -> เมนู 3 อีกครั้ง")
end

-- ---------- เมนู 4: สรุป ----------
local function summarize()
  local snaps = tgt().snaps
  if #snaps < 2 then gg.alert("ต้องมี Snapshot อย่างน้อย 2 อัน (แนะนำ 3+) ของ " .. cur); return end

  local common = {}
  for _, addr in ipairs(snaps[1].order) do
    local inAll = true
    for k = 2, #snaps do
      if not snaps[k].hits[addr] then inAll = false; break end
    end
    if inAll then common[#common + 1] = addr end
  end
  if #common == 0 then
    gg.alert("ไม่มีที่อยู่ร่วมกันทุก Snapshot\nต้อง Refine ให้ที่อยู่เดิมเหลืออยู่ก่อนเก็บ Snapshot ถัดไป")
    return
  end

  local follow, other = {}, {}
  for o = -CFG.BEFORE, CFG.AFTER - 4, 4 do
    if o ~= 0 then
      local cntChanged, cntFollow, ex = 0, 0, nil
      for _, addr in ipairs(common) do
        local allChanged, allFollow = true, true
        for k = 2, #snaps do
          local h1, h2 = snaps[k - 1].hits[addr], snaps[k].hits[addr]
          local a, b, m1, m2 = h1[o], h2[o], h1[0], h2[0]
          if not (a and b and m1 and m2) then allChanged = false; allFollow = false; break end
          if a.d == b.d then allChanged = false end
          if (b.d - a.d) ~= (m2.d - m1.d) then allFollow = false end
        end
        if allChanged then cntChanged = cntChanged + 1 end
        if allFollow then cntFollow = cntFollow + 1 end
        if allChanged and not ex then
          ex = {}
          for k = 1, #snaps do ex[k] = snaps[k].hits[addr][o].d end
        end
      end
      if cntChanged > 0 then
        local line = hexoff(o) .. "  ค่า: " .. table.concat(ex, " -> ")
          .. "  เปลี่ยนทุกครั้ง " .. cntChanged .. "/" .. #common
        if cntFollow > 0 then
          follow[#follow + 1] = line .. "  [ขยับเท่าค่าหลัก " .. cntFollow .. "]"
        else
          other[#other + 1] = line
        end
      end
    end
  end

  local vals = {}
  for k = 1, #snaps do vals[k] = tostring(snaps[k].value) end
  local text = header() .. "## สรุป " .. cur .. "  snapshot " .. #snaps .. "  ที่อยู่ร่วมกัน " .. #common .. "\n"
    .. "## ค่าหลัก (offset 0): " .. table.concat(vals, " -> ") .. "\n\n"
    .. "## A) ขยับเท่ากับค่าหลักทุกครั้ง (น่าเป็นสำเนา/ค่าคู่กัน)\n" .. table.concat(follow, "\n") .. "\n\n"
    .. "## B) เปลี่ยนทุกครั้งแต่ไม่เท่าค่าหลัก (อาจเป็นตัวนับ/เวลา/ค่าที่เกี่ยวข้อง)\n" .. table.concat(other, "\n") .. "\n"
  local path = writeFile("player_scan_" .. slug(cur) .. "_summary.txt", text)

  local pv = {}
  for i = 1, math.min(#follow, 6) do pv[#pv + 1] = follow[i] end
  local preview = (#pv > 0) and table.concat(pv, "\n") or "(ไม่มี offset ที่ขยับเท่าค่าหลัก)"
  gg.alert("A) " .. #follow .. "  B) " .. #other .. "\n\n" .. preview .. "\n\n" .. (path and ("ไฟล์: " .. path) or ""))
end

-- ---------- เมนู 5: pointer จาก libsimcity.so ----------
local function pointerScan()
  local n = gg.getResultsCount()
  if n == 0 or n > CFG.MAX_HITS then
    gg.alert("ต้องมีผลลัพธ์ 1-" .. CFG.MAX_HITS .. " ที่อยู่ก่อน (ตอนนี้ " .. n .. ")")
    return
  end
  local targets = {}
  local res = gg.getResults(n)
  for i = 1, #res do targets[i] = res[i].address end

  local ranges = libRanges()
  if #ranges == 0 then gg.alert("ไม่พบช่วงของ libsimcity.so"); return end

  gg.toast("กำลังหา pointer...")
  local ok, err = pcall(gg.searchPointer, CFG.PTR_MAX_OFFSET)
  if not ok then gg.alert("searchPointer ไม่ทำงาน: " .. tostring(err)); return end

  local cnt = gg.getResultsCount()
  local lim = math.min(cnt, 2000)
  local ptrs = gg.getResults(lim)
  local base = libBase() or ranges[1].s
  local hits, lines = 0, {}
  local reqs = {}
  for i = 1, #ptrs do reqs[i] = { address = ptrs[i].address, flags = gg.TYPE_QWORD } end
  local okv, vals = pcall(gg.getValues, reqs)
  if not okv or not vals then gg.alert("อ่านค่า pointer ไม่ได้"); return end

  for i = 1, #ptrs do
    local a = ptrs[i].address
    local inLib = false
    for _, r in ipairs(ranges) do
      if a >= r.s and a < r.e then inLib = true; break end
    end
    if inLib then
      local v = vals[i].value
      for _, t in ipairs(targets) do
        local d = t - v
        if d >= 0 and d <= CFG.PTR_MAX_OFFSET then
          hits = hits + 1
          lines[#lines + 1] = "libsimcity+0x" .. hex(a - base) .. " -> ชี้ 0x" .. hex(v) .. "  ห่างเป้าหมาย +0x" .. hex(d)
        end
      end
    end
  end

  local text = header() .. "## pointer จาก libsimcity.so ไปยัง " .. cur .. "  (ตรวจ " .. lim .. " จาก " .. cnt .. ")\n"
    .. "## รูปแบบ: ค่าที่ที่อยู่ libsimcity+X ชี้ใกล้เป้าหมาย; ต้องตรวจซ้ำหลังเปิดเกมใหม่ว่ายังชี้ถูกที่\n\n"
    .. table.concat(lines, "\n") .. "\n"
  local path = writeFile("player_scan_" .. slug(cur) .. "_ptr.txt", text)
  local preview = (#lines > 0) and table.concat(lines, "\n", 1, math.min(#lines, 8)) or "(ไม่เจอ pointer จาก libsimcity.so)"
  gg.alert("เจอ " .. hits .. " รายการ\n\n" .. preview .. "\n\n" .. (path and ("ไฟล์: " .. path) or "")
    .. "\n\nผลลัพธ์ใน GG ตอนนี้เป็นรายการ pointer ให้เมนู 6 ล้างก่อนค้นใหม่")
end

-- ---------- เมนูหลัก ----------
local function mainMenu()
  local t = tgt()
  local m = gg.choice({
    "1) เลือกเป้าหมาย  [" .. cur .. "]",
    "2) ค้น / Refine  (ผลลัพธ์ " .. gg.getResultsCount() .. ")",
    "3) เก็บ Snapshot  (มี " .. #t.snaps .. ")",
    "4) สรุป offset",
    "5) หา pointer จาก libsimcity.so",
    "6) ล้างผลลัพธ์ (ค้นใหม่)",
    "7) ออก",
  }, nil, "Player Scan (อ่านอย่างเดียว)")
  if m == 1 then pickTarget()
  elseif m == 2 then searchOrRefine()
  elseif m == 3 then snapshot()
  elseif m == 4 then summarize()
  elseif m == 5 then pointerScan()
  elseif m == 6 then gg.clearResults(); gg.toast("ล้างแล้ว")
  elseif m == 7 then os.exit() end
end

gg.showUiButton()
gg.toast("Player Scan พร้อม — กดไอคอน GG")
while true do
  if gg.isClickedUiButton() then mainMenu() end
  gg.sleep(100)
end
