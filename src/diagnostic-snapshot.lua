-- Read-only snapshots of this app and exact native trade/dialog objects.
-- No callbacks, inputs, remotes, hooks, inventory traversal or network requests.
return function(context, app)
    local function field(object, name)
        if type(object) == "table" then return rawget(object, name) end
    end
    local function child(parent, name)
        return parent and parent:FindFirstChild(name)
    end
    local function shown(node, playerGui)
        local current = node
        while current and current ~= playerGui do
            if current:IsA("GuiObject") and not current.Visible then return false end
            if current:IsA("ScreenGui") and not current.Enabled then return false end
            current = current.Parent
        end
        return current == playerGui
    end
    local function itemCount(offer)
        local items = field(offer, "items")
        if type(items) ~= "table" then return nil end
        local total = 0
        for _ in pairs(items) do
            total = total + 1
            if total > 100000 then return nil end
        end
        return total
    end
    local function sameTrade(a, b)
        return type(a) == "table" and type(b) == "table" and a.trade_id ~= nil
            and a.trade_id == b.trade_id and a.current_stage == b.current_stage
            and a.offer_version == b.offer_version
    end
    return function()
        local snapshot = {}
        local state = field(field(app, "Engine"), "State")
        snapshot.app_phase, snapshot.app_detail = field(state, "phase"), field(state, "detail")
        local modules = field(context, "modules")
        local player = field(context, "player")
        local current
        local tradeOK = pcall(function()
            local data = field(modules, "ClientData")
            if type(field(data, "get")) ~= "function" then error("trade_reader_unavailable", 0) end
            local trade = data.get("trade")
            snapshot.trade_present = type(trade) == "table" and trade.trade_id ~= nil
            if not snapshot.trade_present then return end
            snapshot.trade_owned = trade.sender == player or trade.recipient == player
            if not snapshot.trade_owned then return end
            current = trade
            snapshot.trade_id, snapshot.trade_stage, snapshot.offer_version = trade.trade_id, trade.current_stage, trade.offer_version
            local own = trade.sender == player and trade.sender_offer or trade.recipient_offer
            local other = trade.sender == player and trade.recipient_offer or trade.sender_offer
            snapshot.own_count, snapshot.partner_count = itemCount(own), itemCount(other)
            snapshot.own_negotiated, snapshot.partner_negotiated = field(own, "negotiated"), field(other, "negotiated")
            snapshot.own_confirmed, snapshot.partner_confirmed = field(own, "confirmed"), field(other, "confirmed")
        end)
        if not tradeOK then snapshot.trade_read_error = true end
        if current then
            local timingOK = pcall(function()
                local manager = field(modules, "UIManager")
                local ui = field(field(manager, "apps"), "TradeApp")
                if type(ui) ~= "table" or type(ui._get_local_trade_state) ~= "function" or not ui.lock_countdown then return end
                local before = ui:_get_local_trade_state()
                if not sameTrade(current, before) then return end
                local going = ui.lock_countdown:is_going()
                local remaining = ui.lock_countdown:get_remaining_time()
                if not sameTrade(current, ui:_get_local_trade_state()) then return end
                snapshot.countdown_trade_id, snapshot.countdown_stage, snapshot.countdown_offer_version = current.trade_id, current.current_stage, current.offer_version
                snapshot.countdown_going, snapshot.countdown_remaining = going, remaining
            end)
            if not timingOK then snapshot.countdown_read_error = true end
        end
        local dialogOK = pcall(function()
            local pg = player and player:FindFirstChildOfClass("PlayerGui") or field(context, "guiParent")
            if not pg then return end
            local screen = child(pg, "DialogApp")
            local dialog = child(child(screen, "Dialog"), "NormalDialog")
            snapshot.dialog_visible = dialog ~= nil and shown(dialog, pg)
            if not snapshot.dialog_visible then return end
            snapshot.dialog_source = "PlayerGui/DialogApp/Dialog/NormalDialog"
            local label = child(child(dialog, "Info"), "TextLabel")
            if label and label:IsA("TextLabel") and shown(label, pg) and label.TextTransparency ~= 1 then snapshot.dialog_text = label.Text end
            local buttons = child(dialog, "Buttons")
            if not buttons then return end
            local labels = {}
            for _, button in ipairs(buttons:GetChildren()) do
                if #labels >= 8 then break end
                local face = child(button, "Face")
                local text = child(face, "TextLabel")
                if text and text:IsA("TextLabel") and shown(text, pg) and text.TextTransparency ~= 1 then
                    labels[#labels + 1] = tostring(button.Name):sub(1, 40) .. "/Face/TextLabel=" .. tostring(text.Text):sub(1, 100)
                end
            end
            table.sort(labels)
            snapshot.dialog_buttons = table.concat(labels, " | ")
        end)
        if not dialogOK then snapshot.dialog_read_error = true end
        return snapshot
    end
end
