-- Startup only: the host clicks native Play/Home, then this gate waits for the
-- native spawn sequence. Module loading uses a guarded, bounded worker.
return function(d)
    local env, clock = d.env, d.clock
    local previous = env.__BlueHubTradeOnlyStartup
    if type(previous) == "table" and (previous.status == "waiting" or previous.status == "ready") then
        previous.status = "superseded"
        previous.finishedAt = clock()
    end
    local started = clock()
    local token = {status = "waiting", stage = "game_loaded", startedAt = started,
        deadline = started + 180, elapsed = 0, attempts = 0}
    env.__BlueHubTradeOnlyStartup = token
    local function current()
        return env.__BlueHubTradeOnlyStartup == token and token.status == "waiting" and clock() < token.deadline
    end
    local function finish(status, stage)
        token.status, token.stage = status, stage or token.stage
        token.finishedAt, token.elapsed = clock(), clock() - started
        if status == "timeout" and d.warn then
            d.warn("[Blue Hub Trade Only] Startup timeout: " .. token.stage ..
                (token.lastError and (" — " .. token.lastError) or "") .. ". Trade belum dimulai.")
        end
        return status == "ready", token
    end
    local function pending()
        local app = env.BlueHubTradeOnly
        if type(app) ~= "table" then return false end
        local state = type(app.Engine) == "table" and app.Engine.State or app.State
        return type(state) == "table" and state.pending == true
    end
    local function homePending()
        if not d.isHomePending then return false end
        local ok, visible = pcall(d.isHomePending)
        if not ok then token.lastError = tostring(visible); return true end
        return visible == true
    end
    local function liveRig()
        local player = d.players.LocalPlayer
        local char = player and player.Character
        if not char or not char.Parent then return end
        local human = char:FindFirstChildOfClass("Humanoid")
        local root = char:FindFirstChild("HumanoidRootPart")
        if not human or (tonumber(human.Health) or 0) <= 0 or not root or not root:IsA("BasePart") then return end
        return char, human, root
    end
    local requirements = {
        {"ClientData", "get", "function"},
        {"InventoryDB", "pets", "table"},
        {"RouterClient", "get", "function"},
        {"BackpackLockTracker", "is_locked", "function"},
        {"ItemHider", "is_item_tradeable", "function"},
        {"TradeLicenseHelper", "player_has_trade_license", "function"},
        {"PolicyHelper", "is_trading_prohibited", "function"},
        {"SharedConstants", "max_trade_offer_slots", "number"},
        {"EquipPermissions", "can_unequip_client", "function"},
        {"UIManager", "apps", "table"},
    }
    local attempt, retryAt
    local function startAttempt(fsys, helper, char, human, root)
        local work = {done = false, fsys = fsys, char = char, human = human, root = root}
        attempt = work
        token.attempts = token.attempts + 1
        d.spawn(function()
            local ok, result = pcall(function()
                local function sameRig()
                    local nextChar, nextHuman, nextRoot = liveRig()
                    assert(nextChar == char and nextHuman == human and nextRoot == root, "Karakter berubah saat startup.")
                end
                if not current() then return nil end
                token.stage = "native_spawn"
                local sequence = d.requireModule(helper)
                if not current() then return nil end
                assert(type(sequence) == "table" and type(sequence.is_sequence_finished) == "function", "SpawnSequenceHelper belum siap.")
                while current() do
                    sameRig()
                    local finished = sequence.is_sequence_finished()
                    if not current() then return nil end
                    sameRig()
                    if finished == true and not homePending() then break end
                    d.wait(.1)
                end
                if not current() then return nil end
                token.stage = "require_fsys"
                local native = d.requireModule(fsys)
                if not current() then return nil end
                sameRig()
                assert(type(native) == "table" and type(native.load) == "function", "Fsys.load belum siap.")
                local modules = {}
                for _, requirement in ipairs(requirements) do
                    if not current() then return nil end
                    local name, member, kind = requirement[1], requirement[2], requirement[3]
                    token.stage = "module_" .. name
                    local value = native.load(name)
                    if not current() then return nil end
                    sameRig()
                    assert(type(value) == "table" and type(value[member]) == kind, name .. "." .. member .. " belum siap.")
                    modules[name] = value
                end
                return modules
            end)
            -- A late completion cannot revive a timed-out or superseded boot.
            if current() then
                work.ok, work.result, work.done = ok and result ~= nil, result, true
            end
        end)
    end
    while true do
        if env.__BlueHubTradeOnlyStartup ~= token then return finish("superseded") end
        if token.status == "stopped" then return finish("stopped", "cancelled") end
        token.elapsed = clock() - started
        if clock() >= token.deadline then return finish("timeout") end
        if pending() then return finish("blocked_pending", "pending_trade") end
        if not d.game:IsLoaded() then
            token.stage = "game_loaded"
        elseif d.game.PlaceId == 0 then
            token.stage = "place_id"
        elseif d.game.PlaceId ~= 920587237 then
            return finish("skipped", "wrong_game")
        elseif not d.players.LocalPlayer then
            token.stage = "local_player"
        else
            local player = d.players.LocalPlayer
            local gui = player:FindFirstChild("PlayerGui")
            local fsys = d.rs:FindFirstChild("Fsys")
            local new = d.rs:FindFirstChild("new")
            local moduleFolder = new and new:FindFirstChild("modules")
            if not gui then token.stage = "player_gui"
            elseif not fsys or not fsys:IsA("ModuleScript") then token.stage = "fsys_module"
            elseif not moduleFolder then token.stage = "replicated_modules"
            else
                local char, human, root = liveRig()
                local spawnFolder = moduleFolder:FindFirstChild("SpawnSequenceClient")
                local helper = spawnFolder and spawnFolder:FindFirstChild("SpawnSequenceHelper")
                local function readyAttempt()
                    local currentChar, currentHuman, currentRoot = liveRig()
                    return attempt and attempt.done and attempt.ok and attempt.fsys == fsys
                        and d.rs:FindFirstChild("Fsys") == fsys and d.players.LocalPlayer == player
                        and player:FindFirstChild("PlayerGui") == gui
                        and currentChar == attempt.char and currentHuman == attempt.human and currentRoot == attempt.root
                end
                local chooserPending = homePending()
                if attempt and attempt.done then
                    if readyAttempt() then
                        if not chooserPending then
                            token.player, token.guiParent, token.modules = player, gui, attempt.result
                            return finish("ready", "modules_ready")
                        end
                    else
                        token.lastError = tostring(attempt.result)
                        attempt, retryAt = nil, clock() + .5
                    end
                end
                if chooserPending or not char then
                    token.stage = chooserPending and "home_selection" or "character"
                    if d.advanceMenu then
                        local ok, why = pcall(d.advanceMenu, token)
                        if not ok then token.lastError = tostring(why) end
                    end
                elseif not helper or not helper:IsA("ModuleScript") then
                    token.stage = "spawn_helper"
                elseif not attempt and (not retryAt or clock() >= retryAt) then
                    startAttempt(fsys, helper, char, human, root)
                end
                if env.__BlueHubTradeOnlyStartup ~= token then return finish("superseded") end
                if clock() >= token.deadline then return finish("timeout") end
                if readyAttempt() and not homePending() then
                    token.player, token.guiParent, token.modules = player, gui, attempt.result
                    return finish("ready", "modules_ready")
                end
            end
        end
        d.wait(math.min(.1, math.max(0, token.deadline - clock())))
    end
end
