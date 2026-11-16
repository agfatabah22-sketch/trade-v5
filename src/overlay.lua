-- Passive presentation only. Trade, startup, and account switching belong to
-- the controller. The single completion label is also read by its file bridge.
return function(d)
    d = d or {}
    local parent = d.parent or d.playerGui or d.root
    assert(typeof(parent) == "Instance", "Blue Hub overlay requires a GUI parent.")
    local clock = type(d.clock) == "function" and d.clock or os.clock
    local delay = type(d.delay) == "function" and d.delay or task.delay
    local holdSeconds = tonumber(d.completionHoldSeconds) or 4
    if holdSeconds ~= holdSeconds or holdSeconds == math.huge or holdSeconds < 3 then
        holdSeconds = 4
    end
    holdSeconds = math.min(holdSeconds, 30)

    local alive, shown, phase, completionAt = true, true, "loading", nil
    local connections = {}
    local api = {}

    local function node(className, owner, properties)
        local object = Instance.new(className)
        for key, value in pairs(properties or {}) do object[key] = value end
        object.Parent = owner
        return object
    end
    local function text(owner, name, properties, minimum, maximum)
        local base = {
            Name = name,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            TextColor3 = Color3.fromRGB(224, 229, 236),
            TextScaled = true,
            TextWrapped = true,
            RichText = false,
            Active = false,
            ZIndex = 2,
        }
        for key, value in pairs(properties) do base[key] = value end
        local label = node("TextLabel", owner, base)
        node("UITextSizeConstraint", label, {
            MinTextSize = minimum or 12,
            MaxTextSize = maximum or 20,
        })
        return label
    end
    local function connect(signal, callback)
        local connection = signal:Connect(callback)
        connections[#connections + 1] = connection
        return connection
    end

    local gui = node("ScreenGui", parent, {
        Name = "BlueHubTradeOnlyOverlay",
        IgnoreGuiInset = true,
        ResetOnSpawn = false,
        DisplayOrder = 1000000,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Enabled = true,
    })
    local shade = node("Frame", gui, {
        Name = "Overlay",
        Position = UDim2.fromScale(0, 0),
        Size = UDim2.fromScale(1, 1),
        BorderSizePixel = 0,
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.45,
        Active = false,
        ZIndex = 1,
    })
    local detail = text(shade, "Detail", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.22),
        Size = UDim2.fromScale(0.9, 0.105),
        Text = "Menunggu game dan konfigurasi trade siap.",
        TextColor3 = Color3.fromRGB(196, 204, 215),
    }, 12, 20)
    local title = text(shade, "Status", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.65),
        Size = UDim2.fromScale(0.94, 0.105),
        Font = Enum.Font.GothamBold,
        Text = "MENYIAPKAN AKUN",
    }, 18, 44)
    local progress = text(shade, "Progress", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.735),
        Size = UDim2.fromScale(0.88, 0.065),
        Text = "",
        TextColor3 = Color3.fromRGB(202, 212, 224),
    }, 11, 16)
    text(shade, "Brand", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.82),
        Size = UDim2.fromScale(0.8, 0.045),
        Text = "BLUE HUB  /  TRADE ONLY",
        TextColor3 = Color3.fromRGB(127, 204, 255),
    }, 10, 16)
    local toggle = node("TextButton", gui, {
        Name = "OverlayVisibility",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 18),
        Size = UDim2.fromOffset(124, 34),
        BorderSizePixel = 0,
        BackgroundColor3 = Color3.fromRGB(28, 36, 50),
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = Color3.fromRGB(166, 202, 255),
        Text = "Hide overlay",
        AutoButtonColor = true,
        ZIndex = 10,
    })
    node("UICorner", toggle, {CornerRadius = UDim.new(0, 9)})

    local titles = {
        loading = "MENYIAPKAN AKUN",
        waiting = "MENUNGGU PENERIMA",
        trading = "TRANSFER BERJALAN",
        finalizing = "MENONAKTIFKAN AKUN",
        blocked = "TRANSFER TERTAHAN",
        error = "TRANSFER TERHENTI",
        complete = "TRANSFER COMPLETED",
    }
    local defaults = {
        loading = "Menunggu game dan konfigurasi trade siap.",
        waiting = "Menunggu akun penerima tersedia di server ini.",
        trading = "Mengirim item yang dipilih di config.",
        finalizing = "Target trade selesai. Menunggu hasil disable AccountOps.",
        blocked = "Ada item atau kondisi yang perlu diperiksa sebelum melanjutkan.",
        error = "Proses berhenti. Periksa pesan status sebelum mencoba lagi.",
        complete = "Semua item yang dipilih selesai dikirim. Menunggu akun berikutnya.",
    }
    local function holdRemaining()
        if phase ~= "complete" or completionAt == nil then return 0 end
        return math.max(0, holdSeconds - (clock() - completionAt))
    end
    local function paintVisibility()
        shade.Visible = shown
        local remaining = holdRemaining()
        toggle.AutoButtonColor = remaining <= 0
        toggle.Text = remaining > 0 and ("Tunggu " .. tostring(math.ceil(remaining)) .. "s")
            or (shown and "Hide overlay" or "Show overlay")
        toggle.TextTransparency = remaining > 0 and 0.2 or 0
    end
    function api.SetVisible(value)
        if not alive then return false end
        if value ~= true and holdRemaining() > 0 then return false end
        shown = value == true
        paintVisibility()
        return true
    end
    connect(toggle.Activated, function() api.SetVisible(not shown) end)

    local function bounded(value, limit)
        if type(value) ~= "string" then return "" end
        return value:gsub("[%z\1-\8\11\12\14-\31]", ""):sub(1, limit)
    end
    local function count(value)
        return type(value) == "number" and value == value and value >= 0 and value < math.huge
            and tostring(math.floor(value)) or "—"
    end
    function api.Set(state)
        if not alive then return false end
        state = type(state) == "table" and state or {}
        local nextPhase = titles[state.phase] and state.phase or "loading"
        if nextPhase == "complete" and phase ~= "complete" then
            completionAt, shown = clock(), true
            local started = completionAt
            delay(holdSeconds, function()
                if alive and phase == "complete" and completionAt == started then paintVisibility() end
            end)
        elseif nextPhase ~= "complete" then
            completionAt = nil
        end
        phase = nextPhase
        title.Text = titles[phase]
        title.TextColor3 = phase == "complete" and Color3.fromRGB(150, 241, 139)
            or phase == "error" and Color3.fromRGB(255, 159, 159)
            or phase == "blocked" and Color3.fromRGB(241, 205, 140)
            or Color3.fromRGB(231, 237, 245)
        local message = bounded(state.detail, 420)
        -- Do not accidentally create a second exact-match completion label.
        if message:lower():gsub("%s+", " "):match("^%s*(.-)%s*$") == "transfer completed" then
            message = ""
        end
        detail.Text = message ~= "" and message or defaults[phase]
        local recipient = bounded(state.recipient, 32)
        local destination = recipient ~= "" and ("Ke @" .. recipient .. "  ·  ") or ""
        progress.Text = destination .. "Terkirim: " .. count(state.sent or 0)
            .. "  ·  Tersisa: " .. count(state.totalRemaining)
        paintVisibility()
        return true
    end
    function api.Destroy()
        if not alive then return end
        alive = false
        for _, connection in ipairs(connections) do connection:Disconnect() end
        gui:Destroy()
    end
    -- The controller can inspect ownership and avoid duplicate overlays on rerun.
    api.Gui, api.StatusLabel = gui, title
    api.Set({phase = "loading", sent = 0})
    return api
end
