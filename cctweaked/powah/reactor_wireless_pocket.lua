local args = {...}

-- Match the hostname sent by the dashboard.
local DASHBOARD_HOSTNAME = args[1] or "reactor_wireless_dash"

local PROTOCOL = "powah_pocket_v1"
local CONNECTION_TIMEOUT = 10
local REFRESH_SECONDS = 1

local modem = peripheral.find("modem", function(_, device)
    return device.isWireless()
end)

assert(
    modem,
    "Wireless modem missing. Use a wireless/Ender pocket computer."
)

rednet.open(peripheral.getName(modem))

local snapshot = nil
local receivedAt = nil
local page = 1
local previousRows = {}
local previousWidth, previousHeight

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.setCursorBlink(false)
term.clear()

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
        return string.format("%.1f kFE", v / 1e3)
    end

    return string.format("%.0f FE", v)
end

local function geometry()
    local width, height = term.getSize()

    -- Header: rows 1-4.
    -- Each reactor gets a name/status row and a storage row.
    -- Last two rows are navigation and controls.
    local perPage = math.max(1, math.floor((height - 6) / 2))

    local count = snapshot and #snapshot.reactors or 0
    local pageCount = math.max(1, math.ceil(count / perPage))

    return width, height, perPage, pageCount
end

local function changePage(direction)
    local _, _, _, pageCount = geometry()
    page = ((page - 1 + direction) % pageCount) + 1
end

local function draw()
    local width, height, perPage, pageCount = geometry()

    if width ~= previousWidth or height ~= previousHeight then
        term.setBackgroundColor(colors.black)
        term.clear()
        previousRows = {}
        previousWidth, previousHeight = width, height
    end

    page = math.max(1, math.min(page, pageCount))

    local rows = {}

    local function row(y, message, color)
        if y < 1 or y > height then
            return
        end

        rows[y] = {
            text = tostring(message):sub(1, width),
            color = color or colors.white
        }
    end

    local now = os.epoch("utc")
    local age = receivedAt and math.max(0, (now - receivedAt) / 1000)
    local lost = not age or age > CONNECTION_TIMEOUT

    row(1, "POWAH REACTORS", colors.cyan)

    if not snapshot then
        row(2, "Waiting for dashboard...", colors.yellow)
        row(4, "Host: " .. DASHBOARD_HOSTNAME, colors.gray)
        row(6, "Run the forwarding", colors.white)
        row(7, "dashboard on computer #3.", colors.white)
        row(height, "Hold Ctrl+T to stop", colors.gray)

    else
        local totals = snapshot.totals or {}

        if lost then
            row(2, "LINK LOST - readings stale", colors.red)
            row(
                3,
                string.format("Last update: %.0fs ago", age or 0),
                colors.gray
            )
            row(4, "Last stored: " .. energy(totals.stored), colors.gray)

        else
            row(
                2,
                "Online: " .. tostring(totals.online or 0)
                    .. "/" .. tostring(totals.count or 0)
                    .. " Active: " .. tostring(totals.active or 0),
                colors.white
            )

            local label = totals.storedCount == totals.count
                and (totals.count or 0) > 0
                and "Stored: "
                or "Known: "

            row(3, label .. energy(totals.stored), colors.white)

            if finite(totals.fraction) then
                row(
                    4,
                    string.format(
                        "Buffer: %.1f%% of %s",
                        totals.fraction * 100,
                        energy(totals.capacity)
                    ),
                    colors.gray
                )
            else
                row(4, "Total buffer: incomplete", colors.gray)
            end
        end

        local first = (page - 1) * perPage + 1
        local last = math.min(#snapshot.reactors, first + perPage - 1)

        if #snapshot.reactors == 0 then
            row(6, "Dashboard connected.", colors.lime)
            row(7, "Waiting for reactors...", colors.yellow)
        end

        for index = first, last do
            local data = snapshot.reactors[index]
            local y = 5 + (index - first) * 2

            local effectiveAge = (tonumber(data.age) or 0) + (age or 0)
            local stale = lost
                or effectiveAge > (snapshot.staleSeconds or 10)
                or data.stale == true

            local status
            local color

            if stale then
                status = "OFFLINE"
                color = colors.gray
            elseif data.connected ~= true then
                status = "NO REACTOR"
                color = colors.red
            elseif data.status == "active" then
                status = "ACTIVE"
                color = colors.lime
            elseif data.status == "idle_charged" then
                status = "CHARGED"
                color = colors.yellow
            elseif data.status == "inactive" then
                status = "INACTIVE"
                color = colors.red
            else
                status = "UNKNOWN"
                color = colors.gray
            end

            local name = tostring(data.name or ("Computer " .. index))
            local suffix = " " .. status
            local nameWidth = math.max(0, width - #suffix)

            row(y, name:sub(1, nameWidth) .. suffix, color)

            if stale then
                row(y + 1, "  No current reading", colors.gray)
            elseif data.connected ~= true then
                row(y + 1, "  Reactor not connected", colors.gray)
            else
                local storage = "  " .. energy(data.stored)

                if finite(data.fraction) then
                    storage = storage .. string.format(
                        " (%.0f%%)",
                        data.fraction * 100
                    )
                end

                row(y + 1, storage, colors.white)
            end
        end

        row(
            height - 1,
            "< Prev   " .. page .. "/" .. pageCount .. "   Next >",
            colors.cyan
        )

        row(height, "Arrows / scroll / tap", colors.gray)
    end

    for y = 1, height do
        local line = rows[y] or {text = "", color = colors.white}
        local text = line.text .. string.rep(" ", width - #line.text)
        local old = previousRows[y]

        if not old or old.text ~= text or old.color ~= line.color then
            term.setCursorPos(1, y)
            term.setBackgroundColor(colors.black)
            term.setTextColor(line.color)
            term.write(text)

            previousRows[y] = {
                text = text,
                color = line.color
            }
        end
    end
end

draw()

local timer = os.startTimer(REFRESH_SECONDS)

while true do
    local event, a, b, c = os.pullEvent()

    if event == "rednet_message" and c == PROTOCOL then
        local message = b

        if type(message) == "table"
            and message.type == "reactor_snapshot"
            and message.version == 1
            and message.dashboard == DASHBOARD_HOSTNAME
            and type(message.reactors) == "table"
            and type(message.totals) == "table"
        then
            snapshot = message
            receivedAt = os.epoch("utc")
            draw()
        end

    elseif event == "timer" and a == timer then
        draw()
        timer = os.startTimer(REFRESH_SECONDS)

    elseif event == "key" then
        if a == keys.right or a == keys.down or a == keys.pageDown then
            changePage(1)
            draw()
        elseif a == keys.left or a == keys.up or a == keys.pageUp then
            changePage(-1)
            draw()
        elseif a == keys.home then
            page = 1
            draw()
        end

    elseif event == "mouse_scroll" then
        changePage(a)
        draw()

    elseif event == "mouse_click" then
        local width, height = term.getSize()

        if c == height - 1 then
            changePage(b <= math.floor(width / 2) and -1 or 1)
            draw()
        end

    elseif event == "term_resize" then
        previousRows = {}
        draw()
    end
end
