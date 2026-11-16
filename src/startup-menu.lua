-- Native startup callbacks only. Construction and readiness checks are inert.
-- Plain methods: controller.Step(startupToken), controller.Status().
-- Does not import modules, fire remotes, edit menus, or choose unknown dialogs.
return function(d)
    local api={}
    local token,attempts,nextClickAt,errors=nil,{},0,{}
    local busy=false
    local status={stage='idle',attempts=attempts}
    local paths={
        play={'NewsApp','EnclosingFrame','MainFrame','Buttons','PlayButton'},
        home={'DialogApp','Dialog','SpawnChooserDialog','UpperCardContainer','ChoicesContent','Choices','Home','Button'},
        chooser={'DialogApp','Dialog','SpawnChooserDialog'},
        dialog={'DialogApp','Dialog'},
    }
    local normalRules={
        {action='spawn_no',text="You've chosen this option a lot! Do you want to go there every time?",
            labels={'No','Yes'},response='No'},
        {action='spawn_okay',text='You can change this option any time in your settings.',
            labels={'Okay'},response='Okay'},
    }
    local function path(root,names)
        local value=root
        for _,name in ipairs(names) do
            value=value and value:FindFirstChild(name)
            if not value then return end
        end
        return value
    end
    local function eligible(t,action)
        return type(t)=='table' and t.status=='waiting' and d.active(t)==true
            and d.players.LocalPlayer~=nil
            and (action~='play' or d.players.LocalPlayer.Character==nil)
    end
    local function displayed(button,playerGui)
        if not button then return false end
        local size=button.AbsoluteSize
        if not size or size.X<=0 or size.Y<=0 then return false end
        local ancestor=button
        while ancestor and ancestor~=playerGui do
            if ancestor:IsA('GuiObject') and not ancestor.Visible then return false end
            if ancestor:IsA('ScreenGui') and not ancestor.Enabled then return false end
            ancestor=ancestor.Parent
        end
        return ancestor==playerGui
    end
    local function visible(button,playerGui)
        return button and button:IsA('GuiButton') and button.Active and displayed(button,playerGui)
    end
    local function modal(playerGui)
        local dialog=path(playerGui,paths.dialog)
        if not displayed(dialog,playerGui) then return end
        local shown
        for _,child in ipairs(dialog:GetChildren()) do
            if child:IsA('GuiObject') and child.Name~='Backing' and child.Name~='ExitButton'
                and displayed(child,playerGui) then
                if shown then return 'unknown',child end
                shown=child
            end
        end
        if shown then
            if shown==path(playerGui,paths.chooser) then return 'home',shown end
            if shown.Name=='NormalDialog' then return 'normal',shown end
            return 'unknown',shown
        end
    end
    local function identify()
        if type(d.identifyNormal)~='function' then return {status='blocked',reason='native_dialog_unavailable'} end
        local ok,state=pcall(d.identifyNormal,normalRules)
        if not ok or type(state)~='table' then return {status='blocked',reason='native_dialog_unavailable'} end
        return state
    end
    function api.IsHomePending()
        local player=d.players.LocalPlayer
        local playerGui=player and player:FindFirstChildOfClass('PlayerGui')
        -- Unknown dialogs block startup too. Readiness never answers them.
        return playerGui~=nil and modal(playerGui)~=nil
    end
    function api.Status()
        local counts={play=attempts.play or 0,home=attempts.home or 0,
            spawn_no=attempts.spawn_no or 0,spawn_okay=attempts.spawn_okay or 0}
        return {stage=status.stage,action=status.action,attempts=counts,
            lastError=status.lastError,nextClickAt=nextClickAt,busy=busy}
    end
    function api.Step(current)
        if busy then return false,'input_pending' end
        if not eligible(current) then return false,'not_pending_startup' end
        if token~=current then
            token=current;attempts={};errors={};nextClickAt=0
            status={stage='waiting_menu',attempts=attempts}
        end
        if d.isLoading and d.isLoading()==true then
            status.stage='loading';return false,'loading'
        end
        if not eligible(current) then return false,'not_pending_startup' end
        local playerGui=d.players.LocalPlayer:FindFirstChildOfClass('PlayerGui')
        if not playerGui then status.stage='waiting_menu';return false,'player_gui_missing' end
        -- Resolve the foreground native dialog before any background menu.
        local button,action,normalState
        local modalKind,modalFrame=modal(playerGui)
        if modalKind=='unknown' then
            status.stage='blocked_dialog';status.action=nil;status.lastError='unknown_native_dialog'
            return false,'unknown_native_dialog'
        elseif modalKind=='normal' then
            normalState=identify()
            if normalState.status~='matched' or normalState.dialog~=modalFrame then
                status.stage=normalState.status=='pending' and 'waiting_dialog' or 'blocked_dialog'
                status.action=nil;status.lastError=normalState.reason or 'unknown_native_dialog'
                return false,status.lastError
            end
            button,action=normalState.button,normalState.action
            if action~='spawn_no' and action~='spawn_okay' then
                status.stage='blocked_dialog';return false,'unknown_native_dialog'
            end
        elseif modalKind=='home' then
            button,action=path(playerGui,paths.home),'home'
        else
            button,action=path(playerGui,paths.play),'play'
        end
        if not eligible(current,action) or not visible(button,playerGui) then
            status.stage='waiting_menu';status.action=nil;return false,'no_known_menu'
        end
        status.action=action
        if (attempts[action] or 0)>=3 then
            status.stage='input_limit';return false,'input_limit:'..action
        end
        local now=d.clock()
        if now<nextClickAt then status.stage='cooldown';return false,'input_cooldown' end
        local function authorize()
            if not eligible(current,action) or d.players.LocalPlayer:FindFirstChildOfClass('PlayerGui')~=playerGui
                or not visible(button,playerGui) then return false end
            if d.isLoading and d.isLoading()==true then return false end
            if not eligible(current,action) then return false end
            local currentKind,currentFrame=modal(playerGui)
            if normalState then
                if currentKind~='normal' or currentFrame~=normalState.dialog then return false end
                local latest=identify()
                return latest.status=='matched' and latest.dialog==normalState.dialog and latest.button==button
                    and latest.action==action and latest.text==normalState.text
            end
            if action=='home' then return currentKind=='home' and path(playerGui,paths.home)==button end
            return currentKind==nil and path(playerGui,paths.play)==button
        end
        -- Host checks the same authorization again immediately before callback.
        if not authorize() then return false,'stale_menu' end
        attempts[action]=(attempts[action] or 0)+1
        nextClickAt=now+3
        busy=true
        local ok,result,detail=pcall(d.click,button,authorize)
        busy=false
        if not eligible(current) then return false,'startup_changed_after_input' end
        if not ok or result~=true then
            local reason=ok and (detail or 'input_not_sent') or tostring(result)
            errors[action]=reason;status.stage='input_error';status.lastError=reason
            return false,reason
        end
        errors[action]=nil;status.lastError=nil;status.stage='clicked'
        return true,action
    end
    return api
end
