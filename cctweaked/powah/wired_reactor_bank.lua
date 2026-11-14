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

local screen = peripheral.find("monitor") or term.current()

if screen.setTextScale then
    screen.setTextScale(0.5)
end

local function read(device, methods)
    for _, method in ipairs(methods) do
        if type(device[method]) == "function" then
            local ok, value = pcall(device[method])
            if ok and value ~= nil then
                return value
            end
        end
    end
    return nil
end

local function formatEnergy(value)
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

local function formatValue(value)
    if type(value) == "number" then
        return string.format("%.1f", value)
    elseif value == nil then
        return "N/A"
    end

    return tostring(value)
end

while true do
    local TYPES = {
        "uraninite_reactor",
        "thermo_generator",
    }

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

    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()

    local width, height = screen.getSize()
    local row = 1

    local function line(text, color)
        if row > height then return end

        screen.setCursorPos(1, row)
        screen.setTextColor(color or colors.white)
        screen.write(tostring(text):sub(1, width))
        row = row + 1
    end

    line(BANK_NAME, colors.cyan)
    line("Connected reactors: " .. #names)
    line("")

    local totalStored = 0
    local totalCapacity = 0
    local storedCount = 0
    local capacityCount = 0

    for index, name in ipairs(names) do
        local reactor = peripheral.wrap(name)

        line("Reactor " .. index .. " - " .. name, colors.yellow)

        if reactor then
            local stored = read(reactor, {"getStoredEnergy"})

            local capacity = read(reactor, {
                "getMaxEnergy",
                "getEnergyCapacity",
                "getMaxStoredEnergy",
                "getEnergyStorage"
            })

            local running = read(reactor, {"isRunning"})
            local fuel = read(reactor, {"getFuel"})
            local carbon = read(reactor, {"getCarbon"})
            local redstone = read(reactor, {"getRedstone"})
            local temperature = read(reactor, {"getTemperature"})

            -- Broadcast this reactor to the wireless dashboard.
            -- Name is assigned here, on the wired computer.
            if wirelessModem then
                rednet.broadcast({
                    name        = BANK_NAME .. " R" .. index,
                    stored      = stored,
                    capacity    = capacity,
                    running     = running,
                    fuel        = fuel,
                    carbon      = carbon,
                    redstone    = redstone,
                    temperature = temperature,
                }, PROTOCOL)
            end

            if type(running) == "boolean" then
                line(
                    "Status: " .. (running and "RUNNING" or "IDLE"),
                    running and colors.lime or colors.orange
                )
            else
                line("Status: N/A", colors.gray)
            end

            if type(stored) == "number"
                and type(capacity) == "number"
                and capacity > 0
            then
                line(string.format(
                    "Energy: %s / %s (%.1f%%)",
                    formatEnergy(stored),
                    formatEnergy(capacity),
                    stored / capacity * 100
                ))
            else
                line("Stored energy: " .. formatEnergy(stored))
            end

            line(
                "Fuel: " .. formatValue(fuel)
                .. " | Carbon: " .. formatValue(carbon)
            )

            line(
                "Redstone: " .. formatValue(redstone)
                .. " | Temp: " .. formatValue(temperature)
            )

            if type(stored) == "number" then
                totalStored = totalStored + stored
                storedCount = storedCount + 1

                if type(capacity) == "number" and capacity > 0 then
                    totalCapacity = totalCapacity + capacity
                    capacityCount = capacityCount + 1
                end
            end
        else
            line("Disconnected", colors.red)
        end

        line("")
    end

    if #names == 0 then
        line("No reactors found.", colors.red)
        line("Check wired modems and cable connections.")
    else
        line(
            "TOTAL STORED: " .. formatEnergy(totalStored),
            colors.cyan
        )

        if storedCount > 0 and capacityCount == storedCount then
            line(string.format(
                "Total buffer: %.1f%% of %s",
                totalStored / totalCapacity * 100,
                formatEnergy(totalCapacity)
            ))
        end
    end

    sleep(REFRESH_SECONDS)
end
