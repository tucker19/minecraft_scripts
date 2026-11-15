local args = {...}
local BANK_NAME = args[1] or os.getComputerLabel() or ("Bank " .. os.getComputerID())

-- Optional wireless link: without a wireless/ender modem this still runs
-- the local monitor display, it just doesn't broadcast.
local PROTOCOL = "powah_telemetry_v1"
local wirelessModem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if wirelessModem then
    rednet.open(peripheral.getName(wirelessModem))
end

local REFRESH_SECONDS = 2
local TEXT_SCALE = 0.5

-- Peripheral types this bank monitors.
local TYPES = {
    "uraninite_reactor",
    "thermo_generator",
}

-- Set this to the actual capacity method if automatic detection fails.
local CAPACITY_METHOD = nil

-- Optional manual capacities in FE, keyed by peripheral name.
local CAPACITY_OVERRIDES = {
    -- ["uraninite_reactor_0"] = 100000000,
}

local screen = peripheral.find("monitor") or term.current()

if screen.setTextScale then
    screen.setTextScale(TEXT_SCALE)
end

screen.setBackgroundColor(colors.black)
screen.setTextColor(colors.white)
screen.setCursorBlink(false)
screen.clear()

local previousRows = {}
local previousWidth, previousHeight = screen.getSize()

local function read(device, methods)
    for _, method in ipairs(methods) do
        if type(device[method]) == "function" then
            local ok, value = pcall(device[method])
            if ok and value ~= nil then
                return value
            end
        end
    end
end

local function getCapacity(device, name)
    local override = CAPACITY_OVERRIDES[name]

    if type(override) == "number" and override > 0 then
        return override
    end

    if CAPACITY_METHOD then
        return read(device, {CAPACITY_METHOD})
    end

    -- Candidates, not confirmed method names for your installation.
    return read(device, {
        "getMaxEnergy",
        "getEnergyCapacity",
        "getMaxStoredEnergy",
        "getMaxEnergyStored",
        "getEnergyStorage",
        "getCapacity"
    })
end

local function energy(value)
    if type(value) ~= "number" then return "N/A" end

    if value >= 1e9 then
        return string.format("%.2f GFE", value / 1e9)
    elseif value >= 1e6 then
        return string.format("%.2f MFE", value / 1e6)
    elseif value >= 1e3 then
        return string.format("%.2f kFE", value / 1e3)
    end

    return string.format("%.0f FE", value)
end

local function value(v)
    if type(v) == "number" then
        return string.format("%.1f", v)
    end
    return v == nil and "N/A" or tostring(v)
end

while true do
    local names = {}

    for _, name in ipairs(peripheral.getNames()) do
        for _, ptype in ipairs(TYPES) do
            if peripheral.hasType(name, ptype) then
                names[#names + 1] = name
                break
            end
        end
    end

    table.sort(names)

    local reactors = {}
    local totalStored, totalCapacity = 0, 0
    local storedCount, capacityCount = 0, 0

    for _, name in ipairs(names) do
        local device = peripheral.wrap(name)
        local data = {name = name, connected = device ~= nil}

        if device then
            data.stored = read(device, {"getStoredEnergy"})
            data.capacity = getCapacity(device, name)
            data.running = read(device, {"isRunning"})
            data.fuel = read(device, {"getFuel"})
            data.carbon = read(device, {"getCarbon"})
            data.redstone = read(device, {"getRedstone"})
            data.temperature = read(device, {"getTemperature"})
        end

        if type(data.stored) == "number" then
            totalStored = totalStored + data.stored
            storedCount = storedCount + 1

            if type(data.capacity) == "number"
                and data.capacity > 0
            then
                totalCapacity = totalCapacity + data.capacity
                capacityCount = capacityCount + 1
            end
        end

        reactors[#reactors + 1] = data
    end

    -- Broadcast each reactor to the wireless dashboard.
    -- Names are assigned here, on the wired computer.
    if wirelessModem then
        for index, data in ipairs(reactors) do
            rednet.broadcast({
                name        = BANK_NAME .. " R" .. index,
                connected   = data.connected,
                stored      = data.stored,
                capacity    = data.capacity,
                running     = data.running,
                fuel        = data.fuel,
                carbon      = data.carbon,
                redstone    = data.redstone,
                temperature = data.temperature,
            }, PROTOCOL)
        end
    end

    local fraction

    if #reactors > 0 and capacityCount == #reactors then
        fraction = math.max(
            0, math.min(1, totalStored / totalCapacity)
        )
    end

    local width, height = screen.getSize()

    if width ~= previousWidth or height ~= previousHeight then
        screen.setBackgroundColor(colors.black)
        screen.clear()
        previousRows = {}
        previousWidth, previousHeight = width, height
    end

    local frame = {}
    local black = colors.toBlit(colors.black)
    local white = colors.toBlit(colors.white)

    for y = 1, height do
        frame[y] = {text = {}, fg = {}, bg = {}}

        for x = 1, width do
            frame[y].text[x] = " "
            frame[y].fg[x] = white
            frame[y].bg[x] = black
        end
    end

    local function text(x, y, message, color, limit)
        if y < 1 or y > height then return end

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
        if x < 1 or x > width or y < 1 or y > height then
            return
        end

        frame[y].text[x] = " "
        frame[y].bg[x] = colors.toBlit(color)
    end

    text(1, 1, BANK_NAME, colors.cyan, width)
    text(
        1, 2,
        "Reactors: " .. #reactors
            .. "  |  Display: " .. width .. "x" .. height,
        colors.gray,
        width
    )

    -- Use proportional panels instead of fixed screen coordinates.
    local sideBySide = width >= 38 and height >= 18
    local leftWidth = sideBySide
        and math.floor(width * 0.55)
        or width
    local dividerX = leftWidth + 1
    local panelX = dividerX + 2
    local panelWidth = width - panelX + 1

    -- Divide available height evenly between reactors.
    local contentTop = 4
    local availableHeight = height - contentTop + 1
    local count = math.max(1, #reactors)

    for index, data in ipairs(reactors) do
        local top = contentTop
            + math.floor((index - 1) * availableHeight / count)
        local bottom = contentTop
            + math.floor(index * availableHeight / count) - 1
        local rowsAvailable = bottom - top + 1
        local row = top

        local function line(message, color)
            if row <= bottom then
                text(1, row, message, color, leftWidth)
                row = row + 1
            end
        end

        local status = "N/A"
        local statusColor = colors.gray

        if type(data.running) == "boolean" then
            status = data.running and "RUNNING" or "IDLE"
            statusColor = data.running and colors.lime or colors.orange
        end

        line("Reactor " .. index .. " - " .. status, statusColor)
        line("Stored: " .. energy(data.stored))

        if type(data.stored) == "number"
            and type(data.capacity) == "number"
            and data.capacity > 0
        then
            line(string.format(
                "Max: %s (%.1f%%)",
                energy(data.capacity),
                data.stored / data.capacity * 100
            ))
        else
            line("Max: N/A", colors.gray)
        end

        if leftWidth >= 36 and rowsAvailable >= 8 then
            line("Fuel: " .. value(data.fuel))
            line("Carbon: " .. value(data.carbon))
            line("Redstone: " .. value(data.redstone))
            line("Temperature: " .. value(data.temperature))
        else
            line(
                "Fuel:" .. value(data.fuel)
                    .. " C:" .. value(data.carbon)
            )
            line(
                "RS:" .. value(data.redstone)
                    .. " T:" .. value(data.temperature)
            )
        end

        -- Show network names only when there is spare vertical space.
        if row < bottom then
            line(data.name, colors.gray)
        end
    end

    if #reactors == 0 then
        text(1, 4, "No reactors found.", colors.red, leftWidth)
        text(1, 5, "Check wired connections.", colors.gray, leftWidth)
    end

    if sideBySide then
        for y = 3, height do
            pixel(dividerX, y, colors.gray)
        end

        local function centered(y, message, color)
            message = tostring(message):sub(1, panelWidth)
            local x = panelX
                + math.floor((panelWidth - #message) / 2)
            text(x, y, message, color, panelWidth)
        end

        centered(4, "COMBINED BUFFER", colors.cyan)

        -- Reserve the lower part of the panel for totals and warnings.
        local graphTop = 6
        local graphBottom = height - 8
        local graphHeight = graphBottom - graphTop + 1

        -- Character cells are taller than they are wide.
        local radiusY = math.max(
            2,
            math.min(
                math.floor((graphHeight - 1) / 2),
                math.floor((panelWidth - 2) / 3.2)
            )
        )
        local radiusX = math.max(
            3,
            math.min(
                math.floor((panelWidth - 2) / 2),
                math.floor(radiusY * 1.6)
            )
        )

        local centerX = panelX + math.floor((panelWidth - 1) / 2)
        local centerY = graphTop + math.floor((graphHeight - 1) / 2)
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

        centered(height - 6, "Total stored", colors.gray)
        centered(
            height - 5,
            storedCount > 0 and energy(totalStored) or "N/A"
        )
        centered(height - 3, "Total capacity", colors.gray)
        centered(
            height - 2,
            fraction and energy(totalCapacity) or "N/A"
        )

        if storedCount < #reactors then
            centered(height, "Missing readings", colors.red)
        elseif #reactors > 0 and not fraction then
            centered(height, "Set capacity API", colors.orange)
        end
    else
        -- Fallback for small terminals, not the intended monitor layout.
        text(
            1, height,
            "Combined stored: "
                .. (storedCount > 0 and energy(totalStored) or "N/A"),
            colors.cyan,
            width
        )
    end

    -- Only transmit rows that changed.
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
            previousRows[y] = {text = rowText, fg = fg, bg = bg}
        end
    end

    sleep(REFRESH_SECONDS)
end
