-- turtle_wireless_dash [hostname]
local args = {...}
local host = args[1] or os.getComputerLabel() or "turtle_wireless_dash"
local protocol = "turtle_quarry_v1"
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
assert(modem, "Attach a wireless or Ender modem")
rednet.open(peripheral.getName(modem))
rednet.host(protocol, host)
local screen = peripheral.find("monitor") or term.current()
if screen.setTextScale then screen.setTextScale(0.5) end
screen.setCursorBlink(false)
local latest, previous, page = {}, {}, 1
local function draw()
    local w, h = screen.getSize()
    local list = {}
    for _, value in pairs(latest) do list[#list + 1] = value end
    table.sort(list, function(a, b) return a.id < b.id end)
    local perPage = math.max(1, math.floor((h - 4) / 8))
    local pages = math.max(1, math.ceil(#list / perPage))
    page = math.min(page, pages)
    local frame = {}
    local function row(y, message, color)
        if y > 0 and y <= h then
            frame[y] = {tostring(message):sub(1, w), color or colors.white}
        end
    end
    row(1, "TURTLE QUARRIES | " .. host, colors.cyan)
    row(2, #list .. " turtles | Page " .. page .. "/" .. pages, colors.gray)
    if #list == 0 then row(4, "Waiting for chunk_dig broadcasts...", colors.yellow) end
    for i = (page - 1) * perPage + 1, math.min(#list, page * perPage) do
        local d = list[i]
        local y = 4 + ((i - 1) % perPage) * 8
        local offline = os.clock() - d.received > 15
        local col = offline and colors.gray or d.status == "mining" and colors.lime
            or d.status == "complete" and colors.cyan or colors.yellow
        row(y, "#" .. d.id .. " " .. tostring(d.name) .. " | "
            .. (offline and "OFFLINE" or tostring(d.status)), col)
        row(y + 1, "Fuel: " .. tostring(d.fuel) .. " / " .. tostring(d.fuelLimit))
        row(y + 2, "Last fuel: " .. tostring(d.fuelType), colors.orange)
        local j, inv, loc = d.job or {}, d.inventory or {}, d.location or {}
        row(y + 3, string.format("Job: %sx%s chunks | %sx%s blocks | layer %s",
            j.chunks or "?", j.chunks or "?", j.side or "?", j.side or "?", j.layer or "?"))
        row(y + 4, string.format("Cargo: %s/%s slots (%.0f%%), %s items | cells %s",
            inv.usedSlots or "?", inv.totalSlots or "?", inv.percent or 0,
            inv.items or "?", j.cells or "?"))
        local p = loc.relative or {}
        row(y + 5, string.format("Relative: forward %s, up %s, right %s",
            p.x or "?", p.y or "?", p.z or "?"), colors.lightBlue)
        local g = loc.gps
        row(y + 6, g and string.format("GPS fix: %.0f %.0f %.0f (%ss old)",
            g.x, g.y, g.z, math.floor((loc.gpsAge or 0) + os.clock() - d.received))
            or "GPS unavailable | offsets are relative to job start", colors.gray)
        row(y + 7, d.detail or "", colors.gray)
    end
    row(h, "Left/right or scroll: pages | touch: next", colors.gray)
    for y = 1, h do
        local r = frame[y] or {"", colors.white}
        local t = r[1] .. string.rep(" ", w - #r[1])
        if not previous[y] or previous[y].text ~= t or previous[y].color ~= r[2] then
            screen.setCursorPos(1, y)
            screen.setBackgroundColor(colors.black)
            screen.setTextColor(r[2])
            screen.write(t)
            previous[y] = {text = t, color = r[2]}
        end
    end
    return pages
end
local pages = draw()
local timer = os.startTimer(1)
while true do
    local e, a, b, c = os.pullEvent()
    if e == "rednet_message" and c == protocol and type(b) == "table"
        and b.type == "quarry" and b.version == 1 then
        b.id, b.received = a, os.clock()
        latest[a] = b
    elseif e == "key" then
        if a == keys.right then page = page % pages + 1
        elseif a == keys.left then page = (page - 2) % pages + 1 end
    elseif e == "monitor_touch" or e == "mouse_click" then
        page = page % pages + 1
    elseif e == "mouse_scroll" then
        page = (page - 1 + a) % pages + 1
    elseif e == "monitor_resize" or e == "term_resize" then previous = {}
    elseif e == "timer" and a == timer then timer = os.startTimer(1) end
    pages = draw()
end
