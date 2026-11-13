local args = {...}
local CORE_NAME = args[1]
local DASHBOARD_ADDRESS = args[2]
local PYLON_NAME = args[3] or "back"

if not CORE_NAME or not DASHBOARD_ADDRESS then
    print('Usage: draconic_wireless_sender "Core Name" dashboard [side]')
    print('Example:')
    print('draconic_wireless_sender "Energy Core 0" draconic_wireless_dash back')
    return
end

local PROTOCOL = "draconic_telemetry_v1"
local SEND_INTERVAL = 1
local LOOKUP_INTERVAL = 15

local numericId = tonumber(DASHBOARD_ADDRESS)

if numericId and (
    numericId < 0
    or numericId == math.huge
    or numericId ~= numericId
    or numericId % 1 ~= 0
) then
    error("Dashboard ID must be a non-negative integer.", 0)
end

local dashboardId
local lastLookup
local previousLines = {}
local previousWidth, previousHeight

local function read(device, method)
    if not device or type(device[method]) ~= "function" then
        return nil
    end

    local ok, result = pcall(device[method])
    if ok then return result end
end

local function energy(value)
    if type(value) ~= "number" then
        return value ~= nil and tostring(value) or "N/A"
    end

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

local function draw(lines)
    local width, height = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorBlink(false)

    if width ~= previousWidth or height ~= previousHeight then
        term.clear()
        previousLines = {}
        previousWidth, previousHeight = width, height
    end

    for y = 1, height do
        local line = tostring(lines[y] or ""):sub(1, width)
        line = line .. string.rep(" ", width - #line)

        if previousLines[y] ~= line then
            term.setCursorPos(1, y)
            term.write(line)
            previousLines[y] = line
        end
    end
end

while true do
    local modem = peripheral.find("modem", function(_, device)
        return device.isWireless()
    end)

    local message = {
        name = CORE_NAME,
        connected = false
    }

    local pylon = peripheral.wrap(PYLON_NAME)

    if pylon and type(pylon.getEnergyStored) == "function" then
        message.stored = read(pylon, "getEnergyStored")
        message.capacity = read(pylon, "getMaxEnergyStored")
        message.input = read(pylon, "getInputPerTick")
        message.output = read(pylon, "getOutputPerTick")
        message.connected = message.stored ~= nil
    end

    local status = "Attach a wireless modem"

    if modem then
        rednet.open(peripheral.getName(modem))

        local now = os.epoch("utc")

        if numericId then
            dashboardId = numericId
        elseif not lastLookup
            or now - lastLookup >= LOOKUP_INTERVAL * 1000 then
            lastLookup = now

            local ok, result = pcall(
                rednet.lookup,
                PROTOCOL,
                DASHBOARD_ADDRESS
            )

            dashboardId = ok and result or nil
        end

        if dashboardId then
            local ok, sent = pcall(
                rednet.send,
                dashboardId,
                message,
                PROTOCOL
            )

            status = ok and sent
                and "Telemetry sent (not acknowledged)"
                or "Unable to send telemetry"
        else
            status = "Dashboard not found; retrying discovery"
        end
    end

    draw({
        CORE_NAME,
        "Sender computer: " .. os.getComputerID(),
        "Dashboard: " .. DASHBOARD_ADDRESS,
        "Resolved ID: " .. tostring(dashboardId or "Not found"),
        "Pylon: " .. PYLON_NAME,
        "Connected: " .. tostring(message.connected),
        "",
        "Stored: " .. energy(message.stored),
        "Capacity: " .. energy(message.capacity),
        "Input: " .. energy(message.input) .. "/t",
        "Output: " .. energy(message.output) .. "/t",
        "",
        status,
        "Hold Ctrl+T to stop"
    })

    sleep(SEND_INTERVAL)
end
