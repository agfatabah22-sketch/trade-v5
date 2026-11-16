-- Validate and snapshot a caller-owned BlueHubConfig before any runtime work.
-- This module has no Roblox, HTTP, filesystem, logging, or getgenv dependencies.
-- Errors contain fixed schema descriptions only; never interpolate input values.
return function(raw)
    local function fail(message) error(message, 0) end
    local function plain(value, message)
        if type(value) ~= "table" or getmetatable(value) ~= nil then fail(message) end
    end
    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end
    local function nonblank(value)
        return type(value) == "string" and value:find("%S") ~= nil
    end
    local function receiver(value)
        if type(value) ~= "string" then return false end
        local name = value:match("^%s*(.-)%s*$")
        return #name > 0 and #name <= 32 and name:match("^[A-Za-z0-9_]+$") ~= nil
    end
    local function list(value, validate, message)
        plain(value, message)
        local count, maximum = 0, 0
        for index, item in next, value do
            if not finite(index) or index < 1 or index % 1 ~= 0 or not validate(item) then
                fail(message)
            end
            count = count + 1
            maximum = math.max(maximum, index)
        end
        if count ~= maximum then fail(message) end
        local copied = {}
        for index = 1, count do copied[index] = rawget(value, index) end
        return copied
    end
    local allowed = {
        Username = true, Pets = true, Accessories = true, Keep = true, Excluded = true,
        AutoStart = true, IncludeEquipped = true, IncludePetPen = true, FastConfirm = true,
        BatchAddItems = true, AutoRetryTradeRequest = true, RecipientSwitchSeconds = true,
        TradeRequestRetrySeconds = true, WaitForRecipientSeconds = true, FarmersV5 = true,
    }
    plain(raw, "BlueHubConfig must be a plain table supplied before the loader.")
    for key in next, raw do
        if allowed[key] ~= true then fail("BlueHubConfig contains an unsupported field.") end
    end

    local config = {}
    local usernames = rawget(raw, "Username")
    local usernameError = "BlueHubConfig.Username must contain exact receiver usernames."
    if type(usernames) == "string" then
        if not receiver(usernames) then fail(usernameError) end
        config.Username = usernames
    else
        config.Username = list(usernames, receiver, usernameError)
        if #config.Username == 0 then fail(usernameError) end
    end
    for _, field in ipairs({"Pets", "Accessories", "Excluded"}) do
        local value = rawget(raw, field)
        config[field] = value == nil and {} or list(value, nonblank,
            "BlueHubConfig." .. field .. " must be a dense list of item names.")
    end
    if #config.Pets == 0 and #config.Accessories == 0 then
        fail("BlueHubConfig requires at least one Pets or Accessories selection.")
    end

    local keep = rawget(raw, "Keep")
    config.Keep = {}
    if keep ~= nil then
        local keepError = "BlueHubConfig.Keep must map item names to nonnegative whole counts."
        plain(keep, keepError)
        for name, count in next, keep do
            if not nonblank(name) or not finite(count) or count < 0 or count % 1 ~= 0 then
                fail(keepError)
            end
            config.Keep[name] = count
        end
    end
    for _, field in ipairs({"AutoStart", "IncludeEquipped", "IncludePetPen", "FastConfirm",
            "BatchAddItems", "AutoRetryTradeRequest"}) do
        local value = rawget(raw, field)
        if value == nil then value = true end
        if type(value) ~= "boolean" then
            fail("BlueHubConfig." .. field .. " must be true or false.")
        end
        config[field] = value
    end
    local function seconds(field, default, minimum, maximum)
        local value = rawget(raw, field)
        if value == nil then value = default end
        if not finite(value) or value < minimum or (maximum and value > maximum) then
            fail("BlueHubConfig." .. field .. " is outside its allowed seconds range.")
        end
        config[field] = value
    end
    seconds("RecipientSwitchSeconds", 3, 1, 300)
    seconds("TradeRequestRetrySeconds", 15, 10, 300)
    seconds("WaitForRecipientSeconds", 120, 0)

    config.FarmersV5 = {DisableAccount = false, APIKey = ""}
    local farmers = rawget(raw, "FarmersV5")
    if farmers ~= nil then
        plain(farmers, "BlueHubConfig.FarmersV5 must be a plain table.")
        for key in next, farmers do
            if key ~= "DisableAccount" and key ~= "APIKey" then
                fail("BlueHubConfig.FarmersV5 contains an unsupported field.")
            end
        end
        local disabled = rawget(farmers, "DisableAccount")
        local apiKey = rawget(farmers, "APIKey")
        if disabled == nil then disabled = false end
        if apiKey == nil then apiKey = "" end
        if type(disabled) ~= "boolean" then
            fail("BlueHubConfig.FarmersV5.DisableAccount must be true or false.")
        end
        if type(apiKey) ~= "string" or #apiKey > 2048 or apiKey:find("[^!-~]")
            or (disabled and #apiKey == 0) then
            fail("BlueHubConfig.FarmersV5.APIKey must be a valid key when disabling is enabled.")
        end
        config.FarmersV5.DisableAccount = disabled
        config.FarmersV5.APIKey = apiKey
    end
    return config
end
