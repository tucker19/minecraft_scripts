local args = {...}

local REACTOR_NAME = args[1]
local DASHBOARD_ADDRESS = args[2]

if not REACTOR_NAME
    or REACTOR_NAME == ""
    or not DASHBOARD_ADDRESS
    or DASHBOARD_ADDRESS == ""
then
    print(
        'Usage: reactor_wireless_sender '
        .. '"Reactor Name" "Dashboard Hostname or ID"'
    )
    print("")
    print(
        'Example: reactor_wireless_sender '
        .. '"Spirited Reactor 0" "reactor_wireless_dash"'
    )
    return
end

local PROTOCOL = "powah_telemetry_v1"
local SEND_INTERVAL = 2
local LOOKUP_INTERVAL = 15
local RETRY_INTERVAL = 5

-- Set this if automatic capacity detection fails.
local CAPACITY_METHOD = nil

-- Optional: this reactor's actual maximum capacity in FE.
local CAPACITY_OVERRIDE = nil

local numericDashboardId = tonumber(DASHBOARD_ADDRESS)

if numericDashboardId then
    if numericDashboardId < 0
        or numericDashboardId == math.huge
        or numericDashboardId ~= numericDashboardId
        or numericDashboardId % 1 ~= 0
    then
        print("Dashboard ID must be a non-negative integer.")
        return
    end
end

local dashboardId = nil
local modemName = nil
local lastLookup = nil

local previousLines = {}
local previousWidth = nil
local previousHeight = nil

local function formatEnergy(number)
    if type(number) ~= "number" then
        return "N/A"
    end

    if number >= 1e9 then
        return string.format("%.2f GFE", number / 1e9)
    elseif number >= 1e6 then
        return string.format("%.2f MFE", number / 1e6)
    elseif number >= 1e3 then
        return string.format("%.2f kFE", number / 1e3)
    end

    return string.format("%.0f FE", number)
end

local function drawStatus(status, message)
    message = message or {}

    local width, height = term.getSize()

    if width ~= previousWidth or height ~= previousHeight then
        term.setBackgroundColor(colors.black)
        term.clear()

        previousLines = {}
        previousWidth = width
        previousHeight = height
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorBlink(false)

    local lines = {
        REACTOR_NAME,
        "Sender computer: #" .. os.getComputerID(),
        "Dashboard: " .. DASHBOARD_ADDRESS,
        "Resolved ID: "
            .. (dashboardId and ("#" .. dashboardId) or "Not found"),
        "",
        status,
        "",
        "Reactor found: " .. tostring(message.connected == true),
        "Stored: " .. formatEnergy(message.stored),
        "Capacity: " .. formatEnergy(message.capacity),
        "Running: "
            .. (
                type(message.running) == "boolean"
                and tostring(message.running)
                or "N/A"
            ),
        "",
        "Send interval: " .. SEND_INTERVAL .. " seconds",
        "Hold Ctrl+T to stop"
    }

    for row = 1, height do
        local text = tostring(lines[row] or ""):sub(1, width)
        text = text .. string.rep(" ", width - #text)

        if previousLines[row] ~= text then
            term.setCursorPos(1, row)
            term.write(text)
            previousLines[row] = text
        end
    end
end

local function openWirelessModem()
    local device = peripheral.find("modem", function(_, candidate)
        return candidate.isWireless()
    end)

    if not device then
        modemName = nil
        dashboardId = nil
        lastLookup = nil
        return false
    end

    local name = peripheral.getName(device)

    if name ~= modemName then
        dashboardId = nil
        lastLookup = nil
    end

    modemName = name

    if not rednet.isOpen(modemName) then
        rednet.open(modemName)
    end

    return true
end

local function read(device, methods)
    for _, method in ipairs(methods) do
        if type(device[method]) == "function" then
            local ok, result = pcall(device[method])

            if not ok and result == "Terminated" then
                error(result, 0)
            end

            if ok and result ~= nil then
                return result
            end
        end
    end

    return nil
end

local function getCapacity(device)
    if type(CAPACITY_OVERRIDE) == "number"
        and CAPACITY_OVERRIDE > 0
    then
        return CAPACITY_OVERRIDE
    end

    if CAPACITY_METHOD then
        return read(device, {CAPACITY_METHOD})
    end

    -- Candidates only; the installed capacity method is unconfirmed.
    return read(device, {
        "getMaxEnergy",
        "getEnergyCapacity",
        "getMaxStoredEnergy",
        "getMaxEnergyStored",
        "getCapacity"
    })
end

local function readReactor()
    local reactor = peripheral.find("uraninite_reactor")

    local message = {
        name = REACTOR_NAME,
        connected = reactor ~= nil
    }

    if reactor then
        message.stored = read(reactor, {"getStoredEnergy"})
        message.capacity = getCapacity(reactor)
        message.running = read(reactor, {"isRunning"})
        message.fuel = read(reactor, {"getFuel"})
        message.carbon = read(reactor, {"getCarbon"})
        message.redstone = read(reactor, {"getRedstone"})
        message.temperature = read(reactor, {"getTemperature"})
    end

    return message
end

local function resolveDashboard(message)
    if numericDashboardId then
        dashboardId = numericDashboardId
        return
    end

    local now = os.epoch("utc")
    local interval = dashboardId
        and LOOKUP_INTERVAL
        or RETRY_INTERVAL

    if lastLookup
        and now - lastLookup < interval * 1000
    then
        return
    end

    drawStatus("Looking up dashboard hostname...", message)

    dashboardId = rednet.lookup(
        PROTOCOL,
        DASHBOARD_ADDRESS
    )

    lastLookup = os.epoch("utc")
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

while true do
    local message = readReactor()

    if not openWirelessModem() then
        drawStatus("Waiting for wireless modem...", message)
        sleep(RETRY_INTERVAL)
    else
        resolveDashboard(message)

        if dashboardId then
            local sent = rednet.send(
                dashboardId,
                message,
                PROTOCOL
            )

            if sent then
                drawStatus(
                    "Telemetry sent (not acknowledged)",
                    message
                )
            else
                drawStatus(
                    "Unable to send; retrying...",
                    message
                )

                dashboardId = nil
                lastLookup = nil
            end
        else
            drawStatus(
                "Dashboard unavailable; retrying automatically",
                message
            )
        end

        sleep(SEND_INTERVAL)
    end
end
