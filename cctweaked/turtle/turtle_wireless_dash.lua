-- turtle_wireless_dash [hostname]
-- Shows every chunk_dig turtle broadcasting on turtle_quarry_v1.
local args = {...}
local host = args[1] or os.getComputerLabel() or "turtle_wireless_dash"
local protocol = "turtle_quarry_v1"
local OFFLINE_SECONDS = 15
local GPS_STALE_SECONDS = 30

local modem = peripheral.find("modem", function(_, m)
    return m.isWireless == nil or m.isWireless()
end)
assert(modem, "Attach a wireless or Ender modem")
rednet.open(peripheral.getName(modem))
rednet.host(protocol, host)

local screen = peripheral.find("monitor") or term.current()
if screen.setTextScale then screen.setTextScale(0.5) end
screen.setCursorBlink(false)

local HEADING = {[0] = "forward", "right", "back", "left"}
local ROWS = 8

local STATUS_COLOR = {
    mining = colors.lime,
    resuming = colors.lime,
    returning_to_unload = colors.yellow,
    returning_to_refuel = colors.yellow,
    returning_home = colors.yellow,
    unloading = colors.lightBlue,
    refueling = colors.lightBlue,
    waiting_output = colors.orange,
    waiting_fuel = colors.orange,
    waiting_turtle = colors.orange,
    blocked = colors.orange,
    complete = colors.cyan,
    recovering = colors.yellow,
    resumed = colors.lime,
    recovery_required = colors.red,
    stopped = colors.red,
    error = colors.red,
}

local latest, previous, page = {}, {}, 1

local function label(s)
    return tostring(s or "?"):gsub("_", " "):upper()
end

local function gpsLine(loc, received)
    local g = loc and loc.gps
    if type(g) ~= "table" then
        return "GPS: none - position is relative to home", colors.gray
    end
    local age = math.floor((g.age or loc.gpsAge or 0) + os.clock() - received)
    local where = string.format("%.0f %.0f %.0f", g.x or 0, g.y or 0, g.z or 0)
    if g.moved or age > GPS_STALE_SECONDS then
        return "GPS last fix " .. where .. ", " .. age
            .. "s ago - STALE" .. (g.moved and " (turtle moved since)" or ""), colors.gray
    end
    return "GPS " .. where .. " (" .. age .. "s ago)", colors.lightBlue
end

local function draw()
    local w, h = screen.getSize()
    local list = {}
    for _, value in pairs(latest) do list[#list + 1] = value end
    table.sort(list, function(a, b) return a.id < b.id end)

    local perPage = math.max(1, math.floor((h - 4) / (ROWS + 1)))
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
    if #list == 0 then
        row(4, "Waiting for chunk_dig broadcasts...", colors.yellow)
    end

    for i = (page - 1) * perPage + 1, math.min(#list, page * perPage) do
        local d = list[i]
        local y = 4 + ((i - 1) % perPage) * (ROWS + 1)
        local offline = os.clock() - d.received > OFFLINE_SECONDS
        local col = offline and colors.gray
            or STATUS_COLOR[d.status] or colors.white

        row(y, "#" .. d.id .. " " .. tostring(d.name) .. " | "
            .. (offline and "OFFLINE" or label(d.status)), col)

        local fuel = tostring(d.fuel) .. " / " .. tostring(d.fuelLimit)
        local reserve = d.reserve and (" | reserve " .. tostring(d.reserve))
            or ""
        row(y + 1, "Fuel: " .. fuel .. reserve .. " | last: "
            .. tostring(d.fuelType), colors.orange)

        local j = d.job or {}
        local swarm = type(d.swarm)=="table" and d.swarm
        if swarm then
            row(y + 2, ("Swarm: %s | #%s | %s"):format(tostring(swarm.quarryId or "?"),
                tostring(swarm.assignmentId or "-"),tostring(swarm.area or "staging")))
        else
            row(y + 2, string.format(
                "Job: %sx%s chunks (%sx%s) | layer %s: %s/%s cells, %s blocked",
                j.chunks or "?", j.chunks or "?", j.side or "?", j.side or "?",
                j.layer or "?", j.layerCleared or "?", j.area or "?",
                j.layerBlocked or 0))
        end
        row(y + 3, string.format("Total cleared: %s cells | service trips: %s",
            j.cells or "?", j.trips or 0))

        local inv = d.inventory or {}
        row(y + 4, string.format("Cargo: %s/%s slots (%.0f%%), %s items",
            inv.usedSlots or "?", inv.totalSlots or 16, inv.percent or 0,
            inv.items or "?"))

        local loc = d.location or {}
        local p = loc.relative or {}
        row(y + 5, loc.uncertain and "Position / heading not verified" or string.format(
            "Position: forward %s, up %s, right %s | facing %s",
            p.x or "?", p.y or "?", p.z or "?",
            HEADING[loc.heading] or "?"), colors.lightBlue)

        local gtext, gcol = gpsLine(loc, d.received)
        row(y + 6, gtext, gcol)
        local detail=tostring(d.detail or "")
        if swarm and type(swarm.waitingReason)=="string" and swarm.waitingReason~="" then
            detail=swarm.waitingReason..": "..detail
        end
        row(y + 7, detail:match("^[^\r\n]*"), colors.gray)
    end

    row(h, "Left/right or scroll: pages | touch: next", colors.gray)

    for y = 1, h do
        local r = frame[y] or {"", colors.white}
        local t = r[1] .. string.rep(" ", w - #r[1])
        if not previous[y] or previous[y].text ~= t
            or previous[y].color ~= r[2]
        then
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
        and b.type == "quarry" and b.version == 1
    then
        b.id, b.received = a, os.clock()
        latest[a] = b
    elseif e == "key" then
        if a == keys.right then page = page % pages + 1
        elseif a == keys.left then page = (page - 2) % pages + 1 end
    elseif e == "monitor_touch" or e == "mouse_click" then
        page = page % pages + 1
    elseif e == "mouse_scroll" then
        page = (page - 1 + a) % pages + 1
    elseif e == "monitor_resize" or e == "term_resize" then
        previous = {}
    elseif e == "timer" and a == timer then
        timer = os.startTimer(1)
    end
    pages = draw()
end
