-- Passive bounded recorder. Only injected reads are called; no gameplay actions.
return function(d)
    d = type(d) == "table" and d or {}
    local records, sequence, previous, lastTime = {}, 0, nil, 0
    local capacity = type(d.capacity) == "number" and d.capacity == d.capacity
        and d.capacity > 0 and d.capacity < math.huge and math.floor(d.capacity) or 60
    capacity = math.max(1, math.min(60, capacity))
    local fields = {
        "app_phase", "app_detail", "trade_present", "trade_owned", "trade_id", "trade_stage", "offer_version",
        "own_count", "partner_count", "own_negotiated", "partner_negotiated", "own_confirmed", "partner_confirmed",
        "countdown_trade_id", "countdown_stage", "countdown_offer_version", "countdown_going", "countdown_remaining",
        "dialog_visible", "dialog_text", "dialog_buttons", "dialog_source",
        "trade_read_error", "countdown_read_error", "dialog_read_error", "clock_error", "diagnostic_error",
    }
    local function finite(value)
        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    end
    local function text(value, limit)
        if type(value) ~= "string" then return nil end
        local clipped = value:sub(1, limit):gsub("[%z\1-\31\127]", " ")
        -- Truncation never returns a partial UTF-8 character to JSON consumers.
        if type(utf8) == "table" and type(utf8.len) == "function" then
            while #clipped > 0 do
                local ok, count = pcall(utf8.len, clipped)
                if ok and count then break end
                clipped = clipped:sub(1, #clipped - 1)
            end
        end
        return clipped
    end
    local function identifier(value)
        if type(value) == "string" then return text(value, 96) end
        if finite(value) and value >= 0 and value % 1 == 0 and value < 9007199254740992 then return value end
    end
    local function boolean(value) if type(value) == "boolean" then return value end end
    local function count(value)
        if finite(value) and value >= 0 and value % 1 == 0 and value <= 100000 then return value end
    end
    local function sanitize(raw)
        if type(raw) ~= "table" then return {diagnostic_error = "snapshot_unavailable"} end
        local out = {
            app_phase = text(rawget(raw, "app_phase"), 48), app_detail = text(rawget(raw, "app_detail"), 250),
            trade_present = boolean(rawget(raw, "trade_present")), trade_owned = boolean(rawget(raw, "trade_owned")),
            trade_id = identifier(rawget(raw, "trade_id")), trade_stage = text(rawget(raw, "trade_stage"), 48),
            offer_version = identifier(rawget(raw, "offer_version")),
            own_count = count(rawget(raw, "own_count")), partner_count = count(rawget(raw, "partner_count")),
            own_negotiated = boolean(rawget(raw, "own_negotiated")), partner_negotiated = boolean(rawget(raw, "partner_negotiated")),
            own_confirmed = boolean(rawget(raw, "own_confirmed")), partner_confirmed = boolean(rawget(raw, "partner_confirmed")),
            dialog_visible = boolean(rawget(raw, "dialog_visible")),
            trade_read_error = boolean(rawget(raw, "trade_read_error")),
            countdown_read_error = boolean(rawget(raw, "countdown_read_error")),
            dialog_read_error = boolean(rawget(raw, "dialog_read_error")),
        }
        if out.dialog_visible == true then
            out.dialog_text = text(rawget(raw, "dialog_text"), 400)
            out.dialog_buttons = text(rawget(raw, "dialog_buttons"), 250)
            out.dialog_source = text(rawget(raw, "dialog_source"), 120)
        end
        local countdownId = identifier(rawget(raw, "countdown_trade_id"))
        local countdownStage = text(rawget(raw, "countdown_stage"), 48)
        local countdownVersion = identifier(rawget(raw, "countdown_offer_version"))
        if out.trade_id ~= nil and countdownId == out.trade_id and countdownStage == out.trade_stage
            and out.offer_version ~= nil and countdownVersion == out.offer_version then
            out.countdown_trade_id, out.countdown_stage, out.countdown_offer_version = countdownId, countdownStage, countdownVersion
            out.countdown_going = boolean(rawget(raw, "countdown_going"))
            local remaining = rawget(raw, "countdown_remaining")
            -- Whole seconds keep frequent polling from evicting useful transitions.
            if finite(remaining) and remaining >= 0 and remaining <= 86400 then out.countdown_remaining = math.ceil(remaining) end
        end
        return out
    end
    local function fingerprint(record)
        local parts = {}
        for _, name in ipairs(fields) do
            local value = record[name]
            if value == nil then parts[#parts + 1] = "nil;"
            else
                local encoded = tostring(value)
                parts[#parts + 1] = type(value) .. ":" .. #encoded .. ":" .. encoded .. ";"
            end
        end
        return table.concat(parts)
    end
    local function append(record)
        local signature = fingerprint(record)
        if signature == previous then return false, "unchanged" end
        previous, sequence = signature, sequence + 1
        record.sequence, record.at = sequence, lastTime
        records[#records + 1] = record
        if #records > capacity then table.remove(records, 1) end
        return true, "recorded"
    end
    local api = {}
    function api.Sample()
        local ok, added, why = pcall(function()
            local clockOK, now = pcall(type(d.clock) == "function" and d.clock or os.clock)
            local clockError = not clockOK or not finite(now) or now < 0
            if not clockError then lastTime = math.max(lastTime, now) end
            local record
            if type(d.readSnapshot) ~= "function" then
                record = {diagnostic_error = "snapshot_reader_unavailable"}
            else
                local readOK, raw = pcall(d.readSnapshot)
                record = readOK and sanitize(raw) or {diagnostic_error = "snapshot_read_failed"}
            end
            if clockError then record.clock_error = true end
            return append(record)
        end)
        if ok then return added, why end
        -- Do not preserve exception strings: they may contain unrelated data.
        local saved, result = pcall(append, {diagnostic_error = "sample_failed"})
        return saved and result or false, "sample_failed"
    end
    function api.Read()
        local out = {}
        for index, record in ipairs(records) do
            local copy = {}
            for key, value in pairs(record) do copy[key] = value end
            out[index] = copy
        end
        return out
    end
    return api
end
