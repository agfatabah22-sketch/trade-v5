-- Automatic native Play/Home and spawn readiness, retained from Utility Blue Hub.
-- This composition never releases pets, buys eggs, opens boxes or travels to Nursery.
return function(config, env, factories)
    assert(type(config) == "table", "Blue Hub Trade Only config belum tersedia.")
    assert(type(env) == "table", "Blue Hub Trade Only environment belum tersedia.")
    assert(type(factories) == "table", "Blue Hub Trade Only startup factories belum tersedia.")
    for _, name in ipairs({"makeNativeUI", "makeStartupMenu", "makeStartupPopups", "makeStartupGate"}) do
        assert(type(factories[name]) == "function", name .. " belum tersedia.")
    end

    local Players = game:GetService("Players")
    local RS = game:GetService("ReplicatedStorage")
    local nativePaths = {
        DepthButton = {"ClientModules", "Core", "UIManager", "Elements", "Buttons", "DepthButton"},
        DialogApp = {"ClientModules", "Core", "UIManager", "Apps", "DialogApp"},
        NewsApp = {"ClientModules", "Core", "UIManager", "Apps", "NewsApp"},
    }
    local nativeModules = setmetatable({}, {__index = function(_, name)
        local item = RS
        for _, part in ipairs(nativePaths[name] or {}) do
            item = item and item:FindFirstChild(part)
        end
        return item ~= RS and item or nil
    end})
    local function playerGui()
        return Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    end
    local nativeUI = factories.makeNativeUI({
        playerGui = playerGui,
        nativeModules = nativeModules,
        getConnections = getconnections,
        getUpvalues = type(debug) == "table" and debug.getupvalues or getupvalues,
        getEnv = getfenv,
    })
    local function startupActive(token)
        return type(token) == "table" and env.__BlueHubTradeOnlyStartup == token
            and token.status == "waiting" and game.PlaceId == 920587237
            and (type(token.deadline) ~= "number" or os.clock() < token.deadline)
    end
    local startupMenu = factories.makeStartupMenu({
        players = Players,
        clock = os.clock,
        active = startupActive,
        identifyNormal = nativeUI.IdentifyNormal,
        isLoading = function()
            local pg = playerGui()
            local loading = pg and pg:FindFirstChild("AssetLoadUI")
            return loading and loading:IsA("ScreenGui") and loading.Enabled == true
        end,
        click = nativeUI.Press,
    })
    local startupPopups = factories.makeStartupPopups({
        playerGui = playerGui,
        clock = os.clock,
        active = startupActive,
        getUIManager = function()
            local module = RS:FindFirstChild("Fsys")
            if not module or not module:IsA("ModuleScript") then return nil end
            local native = require(module)
            if type(native) ~= "table" or type(native.load) ~= "function" then return nil end
            return native.load("UIManager")
        end,
    })
    local ready, startup = factories.makeStartupGate({
        env = env,
        game = game,
        players = Players,
        rs = RS,
        clock = os.clock,
        wait = task.wait,
        spawn = task.spawn,
        requireModule = require,
        warn = warn,
        advanceMenu = function(token)
            if startupMenu.IsHomePending() then
                startupMenu.Step(token)
            elseif startupPopups.IsPending() then
                startupPopups.Step(token)
            else
                startupMenu.Step(token)
            end
            token.menu = startupMenu.Status()
        end,
        isHomePending = function()
            return startupMenu.IsHomePending() or startupPopups.IsPending()
        end,
    })
    if not ready then
        local reason = startup.status == "blocked_pending"
            and "Blue Hub Trade Only masih menunggu hasil trade sebelumnya."
            or "Startup belum siap: " .. tostring(startup.status) .. " / " .. tostring(startup.stage)
        return nil, reason, startup
    end
    return {
        player = startup.player,
        guiParent = startup.guiParent,
        modules = startup.modules,
        nativeUI = nativeUI,
        startup = startup,
    }
end
