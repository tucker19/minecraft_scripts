local args = {...}

local DASHBOARD_HOSTNAME = args[1] or "draconic_wireless_dash"

local PROTOCOL = "draconic_dashboard_v1"
local STALE_SECONDS = 10
local PAGE_SECONDS = 8

local modem = peripheral.find("modem", function(_, device)
    return device.isWireless()
end)

assert(modem, "No wireless/Ender modem found")

rednet.open(peripheral.getName(modem))

local screen = term.current()

screen.setBackgroundColor(colors.black)
screen.setTextColor(colors.white)
screen.setCursorBlink(false)
screen.clear()

local cores = {}
local dashboardId, receivedAt
local page = 1
local pageStarted = os.epoch("utc")
local previousRows = {}
local previousWidth, previousHeight

local function finite(value)
    return type(value) == "number"
        and value == value
        and math.abs(value) < math.huge
end

local function energy(value)
    if not finite(value) then return "N/A" end

    local units = {
        {1e18, "EFE"},
        {1e15, "PFE"},
        {1e12, "TFE"},
        {1e9, "GFE"},
        {1e6, "MFE"},
        {1e3, "kFE"}
    }

    for _, unit in ipairs(units) do
        if math.abs(value) >= unit[1] then
            return string.format("%.2f %s", value / unit[1], unit[2])
        end
    end

    return string.format("%.0f FE", value)
end

local function net(core)
    if core and finite(core.input) and finite(core.output) then
        return core.input - core.output
    end
end

local function fraction(core)
    if core and finite(core.stored)
        and finite(core.capacity) and core.capacity > 0 then
        return math.max(0, math.min(1, core.stored / core.capacity))
    end
end

local function draw()
    local now = os.epoch("utc")
    local width, height = screen.getSize()

    if width ~= previousWidth or height ~= previousHeight then
        previousRows = {}
        previousWidth, previousHeight = width, height
    end

    local pages = math.max(1, #cores)

    if page > pages then page = 1 end

    if now - pageStarted >= PAGE_SECONDS * 1000 then
        page = page % pages + 1
        pageStarted = now
    end

    local relayAge = receivedAt
        and math.max(0, (now - receivedAt) / 1000) or nil

    local core = cores[page]
    local sourceAge = core and (core.age + (relayAge or 0)) or nil
    local flow = net(core)
    local charge = fraction(core)
    local status, color = "WAITING", colors.gray

    if relayAge and relayAge > STALE_SECONDS then
        status, color = "DASH OFFLINE", colors.orange
    elseif core then
        if sourceAge > STALE_SECONDS then
            status, color = "CORE OFFLINE", colors.orange
        elseif not core.connected then
            status, color = "NO PYLON", colors.orange
        elseif flow == nil then
            status, color = "FLOW UNKNOWN", colors.gray
        elseif flow > 0 then
            status, color = "CHARGING", colors.lime
        elseif flow < 0 then
            status, color = "DRAINING", colors.red
        else
            status, color = "BALANCED", colors.yellow
        end
    elseif receivedAt then
        status = "NO CORES"
    end

    local rows = {}

    local function line(y, message, lineColor)
        rows[y] = {
            text = tostring(message),
            color = lineColor or colors.white
        }
    end

    line(1, "DRACONIC ENERGY", colors.cyan)
    line(2, core and core.name or "Waiting for cores", color)
    line(3, status, color)
    line(
        4,
        "Core " .. (#cores > 0 and page or 0) .. "/" .. #cores,
        colors.gray
    )
    line(
        5,
        "Charge: " .. (
            charge and string.format("%.2f%%", charge * 100)
            or "N/A"
        ),
        color
    )
    line(7, "Stored:")
    line(8, energy(core and core.stored), color)
    line(9, "Capacity:")
    line(10, energy(core and core.capacity), colors.gray)
    line(12, "In:  " .. energy(core and core.input) .. "/t", colors.lime)
    line(13, "Out: " .. energy(core and core.output) .. "/t", colors.red)
    line(14, "Net: " .. energy(flow) .. "/t", color)
    line(
        16,
        "Dash ID: " .. tostring(dashboardId or "Waiting"),
        colors.gray
    )
    line(
        17,
        sourceAge and string.format("Data: %.0fs old", sourceAge)
            or "Waiting for dashboard",
        colors.gray
    )

    local live = core and relayAge
        and relayAge <= STALE_SECONDS
        and sourceAge <= STALE_SECONDS
        and core.connected

    if core and not live then
        line(18, "Readings are not live", colors.orange)
    elseif #cores > 1 then
        line(18, "Auto-cycle: " .. PAGE_SECONDS .. "s", colors.gray)
    end

    for y = 1, height do
        local row = rows[y]
        local rowText = row and row.text or ""

        rowText = rowText:sub(1, width)
        rowText = rowText .. string.rep(" ", width - #rowText)

        local foreground = string.rep(
            colors.toBlit(row and row.color or colors.white),
            width
        )
        local background = string.rep(
            colors.toBlit(colors.black),
            width
        )

        if y == 6 then
            local filled = charge and math.floor(width * charge) or 0
            rowText = string.rep(" ", width)
            background = string.rep(
                colors.toBlit(color), filled
            ) .. string.rep(
                colors.toBlit(colors.gray), width - filled
            )
        end

        local old = previousRows[y]

        if not old or old.text ~= rowText
            or old.fg ~= foreground or old.bg ~= background then
            screen.setCursorPos(1, y)
            screen.blit(rowText, foreground, background)
            previousRows[y] = {
                text = rowText,
                fg = foreground,
                bg = background
            }
        end
    end
end

draw()

while true do
    local deadline = os.epoch("utc") + 1000

    repeat
        local remaining = math.max(
            0, deadline - os.epoch("utc")
        ) / 1000

        local sender, message = rednet.receive(PROTOCOL, remaining)

        if sender and type(message) == "table"
            and message.dashboard == DASHBOARD_HOSTNAME
            and type(message.cores) == "table" then
            local valid = {}

            for _, core in ipairs(message.cores) do
                if type(core) == "table"
                    and type(core.name) == "string"
                    and finite(core.sender)
                    and finite(core.age)
                    and core.age >= 0 then
                    valid[#valid + 1] = core
                end
            end

            table.sort(valid, function(a, b)
                if a.name == b.name then return a.sender < b.sender end
                return a.name < b.name
            end)

            cores = valid
            dashboardId = sender
            receivedAt = os.epoch("utc")
        end
    until os.epoch("utc") >= deadline

    draw()
end
