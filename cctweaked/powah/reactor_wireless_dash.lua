local args = {...}

local DASHBOARD_HOSTNAME = args[1] or os.getComputerLabel()

if not DASHBOARD_HOSTNAME or DASHBOARD_HOSTNAME == "" then
    print("No dashboard hostname provided or computer label set.")
    print('Usage: reactor_wireless_dash "reactor_wireless_dash"')
    return
end

-- Existing reactor senders use this protocol.
local TELEMETRY_PROTOCOL = "powah_telemetry_v1"

-- The pocket viewer will listen on this separate protocol.
local POCKET_PROTOCOL = "powah_pocket_v1"

local REFRESH_SECONDS = 2
local STALE_SECONDS = 10
local PAGE_SECONDS = 10

local MIN_TEXT_SCALE = 0.5
local MAX_TEXT_SCALE = 2
local MIN_COLUMN_WIDTH = 28
local MIN_SLOT_HEIGHT = 7
local COLUMN_GAP = 2

local latest = {}
local previousRows = {}
local previousWidth, previousHeight
local currentPage = 1
local pageStarted = os.epoch("utc")
local scaleCount = nil
local scaleWidth, scaleHeight
local forwardingStatus = "Waiting"

local modem = peripheral.find("modem", function(_, device)
    return device.isWireless()
end)

assert(modem, "Attach a Wireless Modem or Ender Modem")

rednet.open(peripheral.getName(modem))
rednet.host(TELEMETRY_PROTOCOL, DASHBOARD_HOSTNAME)

local screen = peripheral.find("monitor") or term.current()

if screen.setTextScale then
    screen.setTextScale(MIN_TEXT_SCALE)
end

screen.setBackgroundColor(colors.black)
screen.setTextColor(colors.white)
screen.setCursorBlink(false)
screen.clear()

local function finite(v)
    return type(v) == "number"
        and v == v
        and v ~= math.huge
        and v ~= -math.huge
end

local function energy(v)
    if not finite(v) then
        return "N/A"
    elseif math.abs(v) >= 1e9 then
        return string.format("%.2f GFE", v / 1e9)
    elseif math.abs(v) >= 1e6 then
        return string.format("%.2f MFE", v / 1e6)
    elseif math.abs(v) >= 1e3 then
        return string.format("%.2f kFE", v / 1e3)
    end

    return string.format("%.0f FE", v)
end

local function value(v)
    if finite(v) then
        return string.format("%.1f", v)
    end

    return v == nil and "N/A" or tostring(v)
end

local function layout(width, height)
    local sideBySide = width >= 38 and height >= 18
    local leftWidth = sideBySide and math.floor(width * 0.55) or width
    local availableHeight = math.max(1, height - 4)

    local columns = math.max(
        1,
        math.floor(
            (leftWidth + COLUMN_GAP)
            / (MIN_COLUMN_WIDTH + COLUMN_GAP)
        )
    )

    local rows = math.max(
        1,
        math.floor(availableHeight / MIN_SLOT_HEIGHT)
    )

    return {
        sideBySide = sideBySide,
        leftWidth = leftWidth,
        dividerX = leftWidth + 1,
        panelX = leftWidth + 3,
        panelWidth = width - leftWidth - 2,
        top = 4,
        availableHeight = availableHeight,
        columns = columns,
        rows = rows,
        perPage = columns * rows
    }
end

local function updateScale(count)
    if not screen.setTextScale then
        return
    end

    local width, height = screen.getSize()

    if scaleCount == count
        and scaleWidth == width
        and scaleHeight == height
    then
        return
    end

    local selected = MIN_TEXT_SCALE

    for scale = MAX_TEXT_SCALE, MIN_TEXT_SCALE, -0.5 do
        screen.setTextScale(scale)

        local w, h = screen.getSize()
        local candidate = layout(w, h)

        if candidate.sideBySide
            and candidate.perPage >= math.max(1, count)
        then
            selected = scale
            break
        end
    end

    screen.setTextScale(selected)

    scaleCount = count
    scaleWidth, scaleHeight = screen.getSize()
    previousRows = {}

    screen.setBackgroundColor(colors.black)
    screen.clear()
end

local function receiveTelemetry(sender, message)
    if type(message) ~= "table"
        or type(message.name) ~= "string"
    then
        return
    end

    local data = {
        name = message.name,
        sender = sender,
        received = os.epoch("utc"),
        connected = message.connected == true
    }

    for _, field in ipairs({
        "stored",
        "capacity",
        "fuel",
        "carbon",
        "redstone",
        "temperature"
    }) do
        if finite(message[field]) then
            data[field] = message[field]
        end
    end

    if type(message.running) == "boolean" then
        data.running = message.running
    end

    latest[data.name] = data
end

local function makeSnapshot()
    local now = os.epoch("utc")

    local snapshot = {
        type = "reactor_snapshot",
        version = 1,
        dashboard = DASHBOARD_HOSTNAME,
        dashboardId = os.getComputerID(),
        timestamp = now,
        staleSeconds = STALE_SECONDS,
        reactors = {},
        totals = {
            count = 0,
            online = 0,
            active = 0,
            idleCharged = 0,
            inactive = 0,
            unknown = 0,
            offline = 0,
            noReactor = 0,
            stored = 0,
            capacity = 0,
            storedCount = 0,
            capacityCount = 0
        }
    }

    for _, cached in pairs(latest) do
        local age = math.max(0, (now - cached.received) / 1000)

        local data = {
            name = cached.name,
            sender = cached.sender,
            age = age,
            connected = cached.connected,
            stale = age > STALE_SECONDS
        }

        if data.stale then
            data.status = "offline"
            data.statusText = "OFFLINE"
            data.color = colors.gray
            snapshot.totals.offline = snapshot.totals.offline + 1

        elseif not cached.connected then
            data.status = "no_reactor"
            data.statusText = "NO REACTOR"
            data.color = colors.red
            snapshot.totals.noReactor = snapshot.totals.noReactor + 1

        else
            for _, field in ipairs({
                "stored",
                "capacity",
                "running",
                "fuel",
                "carbon",
                "redstone",
                "temperature"
            }) do
                data[field] = cached[field]
            end

            snapshot.totals.online = snapshot.totals.online + 1

            if cached.running == true then
                data.status = "active"
                data.statusText = "ACTIVE"
                data.color = colors.lime
                snapshot.totals.active = snapshot.totals.active + 1

            elseif cached.running == false and finite(cached.stored) then
                if cached.stored > 0 then
                    data.status = "idle_charged"
                    data.statusText = "IDLE-CHARGED"
                    data.color = colors.yellow
                    snapshot.totals.idleCharged =
                        snapshot.totals.idleCharged + 1
                else
                    data.status = "inactive"
                    data.statusText = "INACTIVE"
                    data.color = colors.red
                    snapshot.totals.inactive =
                        snapshot.totals.inactive + 1
                end

            else
                data.status = "unknown"
                data.statusText = "UNKNOWN"
                data.color = colors.gray
                snapshot.totals.unknown = snapshot.totals.unknown + 1
            end

            if finite(data.stored) then
                snapshot.totals.stored =
                    snapshot.totals.stored + data.stored

                snapshot.totals.storedCount =
                    snapshot.totals.storedCount + 1

                if finite(data.capacity) and data.capacity > 0 then
                    snapshot.totals.capacity =
                        snapshot.totals.capacity + data.capacity

                    snapshot.totals.capacityCount =
                        snapshot.totals.capacityCount + 1

                    data.fraction = math.max(
                        0,
                        math.min(1, data.stored / data.capacity)
                    )
                end
            end
        end

        snapshot.reactors[#snapshot.reactors + 1] = data
    end

    -- Natural ordering: Reactor 2 comes before Reactor 10.
    table.sort(snapshot.reactors, function(a, b)
        local prefixA, numberA = a.name:match("^(.-)(%d+)$")
        local prefixB, numberB = b.name:match("^(.-)(%d+)$")

        if prefixA and prefixA == prefixB
            and tonumber(numberA) ~= tonumber(numberB)
        then
            return tonumber(numberA) < tonumber(numberB)
        end

        if a.name ~= b.name then
            return a.name < b.name
        end

        return a.sender < b.sender
    end)

    local totals = snapshot.totals
    totals.count = #snapshot.reactors

    totals.complete = totals.count > 0
        and totals.storedCount == totals.count
        and totals.capacityCount == totals.count

    if totals.complete and totals.capacity > 0 then
        totals.fraction = math.max(
            0,
            math.min(1, totals.stored / totals.capacity)
        )
    end

    return snapshot
end

local function forwardSnapshot(snapshot)
    -- No pocket ID is needed. Any viewer using POCKET_PROTOCOL
    -- can receive this snapshot while reachable.
    local ok, err = pcall(
        rednet.broadcast,
        snapshot,
        POCKET_PROTOCOL
    )

    if not ok and tostring(err):find("Terminated", 1, true) then
        error(err, 0)
    end

    forwardingStatus = ok and "Broadcasting" or "Send error"
end

local function drawDashboard(snapshot)
    local reactors = snapshot.reactors
    local totals = snapshot.totals

    updateScale(#reactors)

    local width, height = screen.getSize()

    if width ~= previousWidth or height ~= previousHeight then
        screen.setBackgroundColor(colors.black)
        screen.clear()
        previousRows = {}
        previousWidth, previousHeight = width, height
    end

    local black = colors.toBlit(colors.black)
    local white = colors.toBlit(colors.white)
    local frame = {}

    for y = 1, height do
        frame[y] = {text = {}, fg = {}, bg = {}}

        for x = 1, width do
            frame[y].text[x] = " "
            frame[y].fg[x] = white
            frame[y].bg[x] = black
        end
    end

    local function text(x, y, message, color, limit)
        if y < 1 or y > height then
            return
        end

        message = tostring(message)
        local fg = colors.toBlit(color or colors.white)
        local length = math.min(#message, limit or #message)

        for i = 1, length do
            local px = x + i - 1

            if px >= 1 and px <= width then
                frame[y].text[px] = message:sub(i, i)
                frame[y].fg[px] = fg
                frame[y].bg[px] = black
            end
        end
    end

    local function pixel(x, y, color)
        if x >= 1 and x <= width and y >= 1 and y <= height then
            frame[y].text[x] = " "
            frame[y].bg[x] = colors.toBlit(color)
        end
    end

    local l = layout(width, height)
    local now = snapshot.timestamp
    local pageCount = math.max(1, math.ceil(#reactors / l.perPage))

    if currentPage > pageCount then
        currentPage = 1
        pageStarted = now
    end

    if now - pageStarted >= PAGE_SECONDS * 1000 then
        currentPage = currentPage % pageCount + 1
        pageStarted = now
    end

    text(1, 1, "WIRELESS POWAH DASHBOARD", colors.cyan, width)

    text(
        1, 2,
        "Online: " .. totals.online .. "/" .. totals.count
            .. " | " .. DASHBOARD_HOSTNAME
            .. " (#" .. os.getComputerID() .. ")",
        colors.gray,
        width
    )

    local first = (currentPage - 1) * l.perPage + 1
    local last = math.min(#reactors, first + l.perPage - 1)
    local visible = math.max(0, last - first + 1)

    local usedColumns = math.max(
        1,
        math.min(l.columns, math.ceil(visible / l.rows))
    )

    local usedRows = math.max(1, math.ceil(visible / usedColumns))

    local columnWidth = math.floor(
        (l.leftWidth - (usedColumns - 1) * COLUMN_GAP)
        / usedColumns
    )

    for index = first, last do
        local data = reactors[index]
        local slot = index - first
        local column = slot % usedColumns
        local gridRow = math.floor(slot / usedColumns)

        local x = 1 + column * (columnWidth + COLUMN_GAP)
        local top = l.top
            + math.floor(gridRow * l.availableHeight / usedRows)

        local bottom = l.top
            + math.floor((gridRow + 1) * l.availableHeight / usedRows)
            - 2

        local row = top

        local function line(message, color)
            if row <= bottom then
                text(x, row, message, color, columnWidth)
                row = row + 1
            end
        end

        line(data.name .. " - " .. data.statusText, data.color)
        line("Stored: " .. energy(data.stored))

        if finite(data.fraction) then
            line(string.format(
                "Max: %s (%.1f%%)",
                energy(data.capacity),
                data.fraction * 100
            ))
        else
            line("Max: " .. energy(data.capacity), colors.gray)
        end

        if columnWidth >= 36 and bottom - top + 1 >= 8 then
            line("Fuel: " .. value(data.fuel))
            line("Carbon: " .. value(data.carbon))
            line("Redstone: " .. value(data.redstone))
            line("Temperature: " .. value(data.temperature))
        else
            line("Fuel:" .. value(data.fuel) .. " C:" .. value(data.carbon))
            line(
                "RS:" .. value(data.redstone)
                    .. " T:" .. value(data.temperature)
            )
        end

        line(
            "Sender #" .. data.sender
                .. " | " .. string.format("%.0fs ago", data.age),
            colors.gray
        )
    end

    if #reactors == 0 then
        text(
            1, 4,
            "Waiting for reactor senders...",
            colors.orange,
            l.leftWidth
        )
    end

    text(
        1, height,
        "Page " .. currentPage .. "/" .. pageCount
            .. " | Pocket: " .. forwardingStatus,
        colors.gray,
        l.leftWidth
    )

    if l.sideBySide then
        for y = 3, height do
            pixel(l.dividerX, y, colors.gray)
        end

        local function centered(y, message, color)
            message = tostring(message):sub(1, l.panelWidth)

            local x = l.panelX
                + math.floor((l.panelWidth - #message) / 2)

            text(x, y, message, color, l.panelWidth)
        end

        centered(4, "COMBINED BUFFER", colors.cyan)

        local graphTop = 6
        local graphBottom = height - 8
        local graphHeight = graphBottom - graphTop + 1

        local radiusY = math.max(
            2,
            math.min(
                math.floor((graphHeight - 1) / 2),
                math.floor((l.panelWidth - 2) / 3.2)
            )
        )

        local radiusX = math.max(
            3,
            math.min(
                math.floor((l.panelWidth - 2) / 2),
                math.floor(radiusY * 1.6)
            )
        )

        local centerX = l.panelX + math.floor((l.panelWidth - 1) / 2)
        local centerY = graphTop + math.floor((graphHeight - 1) / 2)
        local fraction = totals.fraction
        local ringColor = colors.lime

        if fraction and fraction < 0.2 then
            ringColor = colors.red
        elseif fraction and fraction < 0.5 then
            ringColor = colors.orange
        end

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

                    local color = colors.gray

                    if fraction and fraction > 0
                        and angle / (2 * math.pi) <= fraction
                    then
                        color = ringColor
                    end

                    pixel(x, y, color)
                end
            end
        end

        local percentage = fraction
            and string.format("%.0f%%", fraction * 100)
            or "N/A"

        text(
            centerX - math.floor(#percentage / 2),
            centerY,
            percentage,
            fraction and ringColor or colors.orange
        )

        centered(
            height - 6,
            totals.storedCount == totals.count and totals.count > 0
                and "Total stored"
                or "Known stored",
            colors.gray
        )

        centered(
            height - 5,
            totals.storedCount > 0 and energy(totals.stored) or "N/A"
        )

        centered(
            height - 3,
            totals.complete and "Total capacity" or "Known capacity",
            colors.gray
        )

        centered(
            height - 2,
            totals.capacityCount > 0 and energy(totals.capacity) or "N/A"
        )

        centered(
            height,
            totals.active .. " active | "
                .. totals.idleCharged .. " charged | "
                .. totals.inactive .. " inactive",
            colors.gray
        )
    end

    -- Only redraw changed rows to reduce flicker.
    for y = 1, height do
        local rowText = table.concat(frame[y].text)
        local fg = table.concat(frame[y].fg)
        local bg = table.concat(frame[y].bg)
        local previous = previousRows[y]

        if not previous
            or previous.text ~= rowText
            or previous.fg ~= fg
            or previous.bg ~= bg
        then
            screen.setCursorPos(1, y)
            screen.blit(rowText, fg, bg)

            previousRows[y] = {
                text = rowText,
                fg = fg,
                bg = bg
            }
        end
    end
end

-- Draw immediately, then receive telemetry between timed updates.
drawDashboard(makeSnapshot())

local refreshTimer = os.startTimer(REFRESH_SECONDS)

while true do
    local event, a, b, c = os.pullEvent()

    if event == "rednet_message" and c == TELEMETRY_PROTOCOL then
        receiveTelemetry(a, b)

    elseif event == "timer" and a == refreshTimer then
        local snapshot = makeSnapshot()

        forwardSnapshot(snapshot)
        drawDashboard(snapshot)

        refreshTimer = os.startTimer(REFRESH_SECONDS)

    elseif event == "monitor_resize" or event == "term_resize" then
        scaleCount = nil
        previousRows = {}
        drawDashboard(makeSnapshot())
    end
end
