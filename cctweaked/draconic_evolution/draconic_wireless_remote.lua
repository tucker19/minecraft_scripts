local args = {...}

local DASHBOARD_HOSTNAME = args[1] or "draconic_wireless_dash"

local PROTOCOL = "draconic_dashboard_v1"
local STALE_SECONDS = 10
local PAGE_SECONDS = 8
local INFO_WIDTH = 30

local modem = peripheral.find("modem", function(_, device)
    return device.isWireless()
end)

assert(modem, "Attach a wireless or Ender modem")

rednet.open(peripheral.getName(modem))

local screen = peripheral.find("monitor") or term.current()

if screen.setTextScale then
    screen.setTextScale(0.5)
end

screen.setBackgroundColor(colors.black)
screen.setTextColor(colors.white)
screen.setCursorBlink(false)
screen.clear()

local cores = {}
local receivedAt
local dashboardId

local previousRows = {}
local previousWidth, previousHeight

local page = 1
local pageStarted = os.epoch("utc")

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
            return string.format(
                "%.2f %s",
                value / unit[1],
                unit[2]
            )
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
    if core
        and finite(core.stored)
        and finite(core.capacity)
        and core.capacity > 0 then
        return math.max(
            0,
            math.min(1, core.stored / core.capacity)
        )
    end
end

local function flowColor(flow)
    if not finite(flow) then return colors.gray end
    if flow > 0 then return colors.lime end
    if flow < 0 then return colors.red end
    return colors.yellow
end

local function coreState(core, relayAge)
    if relayAge > STALE_SECONDS then
        return "DASH OFFLINE", colors.orange
    end

    if core.age + relayAge > STALE_SECONDS then
        return "CORE OFFLINE", colors.orange
    end

    if not core.connected then
        return "NO PYLON", colors.orange
    end

    local flow = net(core)

    if flow == nil then
        return "FLOW UNKNOWN", colors.gray
    elseif flow > 0 then
        return "CHARGING", colors.lime
    elseif flow < 0 then
        return "DRAINING", colors.red
    end

    return "BALANCED", colors.yellow
end

local function draw()
    local now = os.epoch("utc")
    local width, height = screen.getSize()

    if width ~= previousWidth or height ~= previousHeight then
        previousRows = {}
        previousWidth, previousHeight = width, height
    end

    local frame = {}

    for y = 1, height do
        frame[y] = {
            text = {},
            fg = {},
            bg = {}
        }

        for x = 1, width do
            frame[y].text[x] = " "
            frame[y].fg[x] = colors.toBlit(colors.white)
            frame[y].bg[x] = colors.toBlit(colors.black)
        end
    end

    local function text(x, y, message, color, limit)
        if y < 1 or y > height then return end

        message = tostring(message)

        for i = 1, math.min(#message, limit or #message) do
            local px = x + i - 1

            if px >= 1 and px <= width then
                frame[y].text[px] = message:sub(i, i)
                frame[y].fg[px] = colors.toBlit(
                    color or colors.white
                )
            end
        end
    end

    local function pixel(x, y, color)
        if x >= 1 and x <= width
            and y >= 1 and y <= height then
            frame[y].text[x] = " "
            frame[y].bg[x] = colors.toBlit(color)
        end
    end

    local pages = math.max(1, #cores)

    if page > pages then page = 1 end

    if now - pageStarted >= PAGE_SECONDS * 1000 then
        page = page % pages + 1
        pageStarted = now
    end

    local relayAge = receivedAt
        and math.max(0, (now - receivedAt) / 1000)
        or math.huge

    local dashboardLive = receivedAt ~= nil
        and relayAge <= STALE_SECONDS

    local online = 0
    local totalStored, totalCapacity, totalNet = 0, 0, 0
    local storageComplete, flowComplete = true, true

    for _, core in ipairs(cores) do
        local live = dashboardLive
            and core.connected
            and core.age + relayAge <= STALE_SECONDS

        if live then
            online = online + 1

            if finite(core.stored)
                and finite(core.capacity)
                and core.capacity > 0 then
                totalStored = totalStored + core.stored
                totalCapacity = totalCapacity + core.capacity
            else
                storageComplete = false
            end

            local flow = net(core)

            if flow ~= nil then
                totalNet = totalNet + flow
            else
                flowComplete = false
            end
        end
    end

    local sideBySide = width >= 50 and height >= 16
    local leftWidth = sideBySide and INFO_WIDTH or width

    text(
        1, 1,
        "DRACONIC REMOTE DASHBOARD",
        colors.cyan,
        width
    )

    text(
        1, 2,
        "Online: " .. online .. "/" .. #cores
            .. "  Source: " .. DASHBOARD_HOSTNAME,
        colors.gray,
        width
    )

    local function info(y, message, color)
        if y >= 3 and y < height then
            text(1, y, message, color, leftWidth)
        end
    end

    local core = cores[page]

    if core then
        local status, color = coreState(core, relayAge)
        local charge = fraction(core)

        info(4, core.name, color)
        info(5, status, color)
        info(7, "Stored: " .. energy(core.stored), color)
        info(8, "Max: " .. energy(core.capacity))

        info(
            9,
            "Charge: " .. (
                charge
                and string.format("%.2f%%", charge * 100)
                or "N/A"
            ),
            color
        )

        info(
            11,
            "In:  " .. energy(core.input) .. "/t",
            colors.lime
        )

        info(
            12,
            "Out: " .. energy(core.output) .. "/t",
            colors.red
        )

        info(
            13,
            "Net: " .. energy(net(core)) .. "/t",
            color
        )

        info(15, "Sender: " .. core.sender, colors.gray)

        info(
            16,
            string.format(
                "Data: %.0fs old",
                core.age + relayAge
            ),
            colors.gray
        )
    else
        info(
            4,
            receivedAt and "No cores reported"
                or "Waiting for dashboard...",
            colors.orange
        )
    end

    if not receivedAt then
        info(18, "Link: WAITING", colors.orange)
    elseif not dashboardLive then
        info(18, "Link: OFFLINE", colors.orange)
    else
        info(18, "Link: CONNECTED", colors.lime)
    end

    text(
        1, height,
        "Core " .. (#cores > 0 and page or 0)
            .. "/" .. #cores
            .. "  Main ID: " .. tostring(dashboardId or "?"),
        colors.gray,
        leftWidth
    )

    if sideBySide then
        local divider = leftWidth + 1

        for y = 3, height do
            pixel(divider, y, colors.gray)
        end

        local panelX = divider + 2
        local panelWidth = width - panelX + 1

        local function centered(y, message, color)
            message = tostring(message):sub(1, panelWidth)

            text(
                panelX + math.floor((panelWidth - #message) / 2),
                y,
                message,
                color,
                panelWidth
            )
        end

        centered(
            4,
            #cores <= 1
                and "ENERGY CORE STORAGE"
                or "COMBINED STORAGE",
            colors.cyan
        )

        local charge = online > 0
            and storageComplete
            and totalCapacity > 0
            and math.max(
                0,
                math.min(1, totalStored / totalCapacity)
            )
            or nil

        local ringColor = online > 0 and flowComplete
            and flowColor(totalNet)
            or colors.gray

        local graphTop = 5
        local graphBottom = height - 7

        local maxRadiusX = math.floor((panelWidth - 2) / 2)
        local maxRadiusY = math.floor(
            (graphBottom - graphTop) / 2
        )

        local radiusY = math.max(
            2,
            math.min(
                maxRadiusY,
                math.floor(maxRadiusX / 1.6)
            )
        )

        local radiusX = math.max(
            3,
            math.min(
                maxRadiusX,
                math.floor(radiusY * 1.6)
            )
        )

        local centerX = panelX
            + math.floor((panelWidth - 1) / 2)

        local centerY = graphTop
            + math.floor((graphBottom - graphTop) / 2)

        for y = centerY - radiusY, centerY + radiusY do
            for x = centerX - radiusX, centerX + radiusX do
                local dx = (x - centerX) / radiusX
                local dy = (y - centerY) / radiusY
                local distance = math.sqrt(dx * dx + dy * dy)

                if distance >= 0.64 and distance <= 1 then
                    local angle = math.atan2(dx, -dy)

                    if angle < 0 then
                        angle = angle + 2 * math.pi
                    end

                    local filled = charge and charge > 0
                        and angle <= charge * 2 * math.pi

                    pixel(
                        x,
                        y,
                        filled and ringColor or colors.gray
                    )
                end
            end
        end

        centered(
            centerY,
            charge
                and string.format("%.1f%%", charge * 100)
                or "N/A",
            ringColor
        )

        centered(
            height - 5,
            "Stored: " .. (
                online > 0 and storageComplete
                and energy(totalStored)
                or "N/A"
            )
        )

        centered(
            height - 4,
            "Capacity: " .. (
                online > 0 and storageComplete
                and energy(totalCapacity)
                or "N/A"
            ),
            colors.gray
        )

        centered(
            height - 3,
            "Net: " .. (
                online > 0 and flowComplete
                and energy(totalNet)
                or "N/A"
            ) .. "/t",
            ringColor
        )

        if not receivedAt then
            centered(
                height - 1,
                "Waiting for dashboard",
                colors.orange
            )
        elseif not dashboardLive then
            centered(
                height - 1,
                "Dashboard link offline",
                colors.orange
            )
        elseif #cores == 0 then
            centered(
                height - 1,
                "Waiting for core senders",
                colors.orange
            )
        elseif online < #cores then
            centered(
                height - 1,
                "Offline cores excluded",
                colors.orange
            )
        elseif not storageComplete or not flowComplete then
            centered(
                height - 1,
                "Missing readings",
                colors.orange
            )
        end
    end

    for y = 1, height do
        local row = {
            text = table.concat(frame[y].text),
            fg = table.concat(frame[y].fg),
            bg = table.concat(frame[y].bg)
        }

        local old = previousRows[y]

        if not old
            or old.text ~= row.text
            or old.fg ~= row.fg
            or old.bg ~= row.bg then
            screen.setCursorPos(1, y)
            screen.blit(row.text, row.fg, row.bg)
            previousRows[y] = row
        end
    end
end

draw()

while true do
    local deadline = os.epoch("utc") + 1000

    repeat
        local remaining = math.max(
            0,
            deadline - os.epoch("utc")
        ) / 1000

        local sender, message = rednet.receive(
            PROTOCOL,
            remaining
        )

        if sender
            and type(message) == "table"
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
                if a.name == b.name then
                    return a.sender < b.sender
                end

                return a.name < b.name
            end)

            cores = valid
            dashboardId = sender
            receivedAt = os.epoch("utc")
        end
    until os.epoch("utc") >= deadline

    draw()
end
