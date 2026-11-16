-- Close only these native startup popups. Inspection is passive; actions reuse
-- native close behavior and never purchase, open a shop/ad, or claim directly.
return function(d)
    local api={}
    local busy=false
    local records=setmetatable({},{__mode='k'})
    local names={MerchPopUpApp='merch_close',FTUEStarterPackApp='starter_close',StarRewardsApp='star_rewards_close'}
    local function gui()
        if type(d.playerGui)=='function' then return d.playerGui() end
        return d.playerGui
    end
    local function displayed(node,pg)
        if not node or not pg then return false end
        local current=node
        while current and current~=pg do
            if current:IsA('GuiObject') and not current.Visible then return false end
            if current:IsA('ScreenGui') and not current.Enabled then return false end
            current=current.Parent
        end
        return current==pg
    end
    local function candidates(pg)
        local list={}
        if not pg then return list end
        for _,screen in ipairs(pg:GetChildren()) do
            local action=names[screen.Name]
            if action and screen:IsA('ScreenGui') and screen.Parent==pg and displayed(screen,pg) then
                local view=screen
                if screen.Name=='FTUEStarterPackApp' then
                    local popups=screen:FindFirstChild('Popups')
                    view=popups and popups:FindFirstChild('Default')
                    if not view or not view:IsA('GuiObject') or not displayed(view,pg) then view=nil end
                end
                if view then list[#list+1]={name=screen.Name,screen=screen,view=view,action=action} end
            end
        end
        table.sort(list,function(a,b)
            local first,second=tonumber(a.screen.DisplayOrder) or 0,tonumber(b.screen.DisplayOrder) or 0
            if first~=second then return first>second end
            return a.name<b.name
        end)
        return list
    end
    local function dialogPending(pg)
        local app=pg and pg:FindFirstChild('DialogApp')
        local dialog=app and app:FindFirstChild('Dialog')
        if not app or not app:IsA('ScreenGui') or not dialog or not displayed(dialog,pg) then return false end
        for _,child in ipairs(dialog:GetChildren()) do
            if child:IsA('GuiObject') and child.Name~='Backing' and child.Name~='ExitButton' and displayed(child,pg) then return true end
        end
        return false
    end
    local function eligible(token)
        return type(token)=='table' and token.status=='waiting' and d.active(token)==true
            and (token.deadline==nil or d.clock()<token.deadline)
    end
    local function sameCandidate(a,b)
        return a and b and a.name==b.name and a.screen==b.screen and a.view==b.view
    end
    local function refreshRecords(list)
        local present={}
        for _,item in ipairs(list) do present[item.view]=true end
        for view in pairs(records) do if not present[view] then records[view]=nil end end
    end
    local function current(token,pg,chosen)
        if not eligible(token) or gui()~=pg or dialogPending(pg) then return false end
        local list=candidates(pg)
        if not sameCandidate(list[1],chosen) then return false end
        for i=2,#list do if list[i].name==chosen.name then return false end end
        return true
    end
    function api.IsPending()
        return #candidates(gui())>0
    end
    function api.Step(token)
        if busy then return false,'popup_busy' end
        if not eligible(token) then return false,'not_pending_startup' end
        busy=true
        local success,handled,reason=pcall(function()
            local pg=gui()
            local list=candidates(pg)
            refreshRecords(list)
            local chosen=list[1]
            if not chosen then return false,'no_known_popup' end
            if dialogPending(pg) then return false,'dialog_pending' end
            for i=2,#list do if list[i].name==chosen.name then return false,'popup_ambiguous' end end
            local record=records[chosen.view]
            if not record then record={retryAt=0};records[chosen.view]=record end
            if record.sent then return false,'popup_pending' end
            if d.clock()<record.retryAt then return false,'popup_cooldown' end
            record.retryAt=d.clock()+1
            if not current(token,pg,chosen) then return false,'popup_changed' end
            local manager=d.getUIManager()
            -- Fsys/module loading can yield. Re-read the foreground and owner.
            if not current(token,pg,chosen) then return false,'popup_changed' end
            local app=type(manager)=='table' and type(manager.apps)=='table' and manager.apps[chosen.name]
            if type(app)~='table' or app.ClassName~=chosen.name or app.UIManager~=manager then return false,'native_popup_unready' end
            local close
            if chosen.name=='FTUEStarterPackApp' then
                if app.instance~=chosen.screen or app.asset_kind~='Default' or app.splash~=chosen.view then return false,'native_popup_changed' end
                close=function()app.splash.Visible=false end
            else
                if app.visible~=true then return false,'native_popup_unready' end
                if type(manager.set_app_visibility)~='function' then return false,'native_popup_unready' end
                if chosen.name=='MerchPopUpApp' then
                    if type(app._close)~='function' or not app.onClose or type(app.onClose.Fire)~='function' then return false,'native_popup_unready' end
                    close=function()app:_close()end
                else
                    if app.executing_purchase==true then return false,'native_purchase_pending' end
                    close=function()manager.set_app_visibility('StarRewardsApp',false)end
                end
            end
            if not current(token,pg,chosen) or manager.apps[chosen.name]~=app then return false,'popup_changed' end
            -- Even an exception can occur after native hide/onClose side effects.
            -- Never dispatch the same visible activation a second time.
            record.sent=true
            close()
            refreshRecords(candidates(pg))
            return true,chosen.action
        end)
        busy=false
        if not success then return false,'popup_error:'..tostring(handled) end
        return handled,reason
    end
    return api
end
