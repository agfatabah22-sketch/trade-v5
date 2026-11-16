-- Reuse verified native callbacks. No mouse coordinates, synthetic signals,
-- new wrappers, direct remotes, or generic dialog responses.
return function(d)
    local api={}
    local busy=false
    local sent=setmetatable({},{__mode='k'})
    local function playerGui()
        if type(d.playerGui)=='function' then return d.playerGui() end
        return d.playerGui
    end
    local function path(root,names)
        for _,name in ipairs(names) do root=root and root:FindFirstChild(name) end
        return root
    end
    local function displayed(node,pg)
        if not node or not pg then return false end
        local size=node.AbsoluteSize
        if not size or size.X<=0 or size.Y<=0 then return false end
        local current=node
        while current and current~=pg do
            if current:IsA('GuiObject') and not current.Visible then return false end
            if current:IsA('ScreenGui') and not current.Enabled then return false end
            current=current.Parent
        end
        return current==pg
    end
    local function visible(button,pg)
        return button and button:IsA('GuiButton') and button.Active and displayed(button,pg)
    end
    local function allowed(authorize)
        if type(authorize)~='function' then return false end
        local ok,value=pcall(authorize)
        return ok and value==true
    end
    local function scriptOf(fn)
        if type(d.getEnv)~='function' then return end
        local ok,env=pcall(d.getEnv,fn)
        return ok and type(env)=='table' and env.script or nil
    end
    local function connected(connection,fn)
        local ok,valid=pcall(function()
            return connection.Enabled==true and connection.LuaConnection~=false
                and connection.Function==fn
        end)
        return ok and valid==true
    end
    local function buttonKind(button,pg)
        if button==path(pg,{'NewsApp','EnclosingFrame','MainFrame','Buttons','PlayButton'}) then return 'NewsApp' end
        if button==path(pg,{'DialogApp','Dialog','SpawnChooserDialog','UpperCardContainer','ChoicesContent','Choices','Home','Button'}) then return 'home' end
        local buttons=path(pg,{'DialogApp','Dialog','NormalDialog','Buttons'})
        if buttons and button.Parent==buttons then return 'DialogApp' end
    end
    local function callbackFor(button,kind)
        if type(d.getConnections)~='function' then return nil,'connections_unavailable' end
        local modules=d.nativeModules or {}
        local expected=modules[kind=='home' and 'DialogApp' or kind]
        if not expected then return nil,'native_module_missing' end
        local ok,connections=pcall(d.getConnections,button.MouseButton1Click)
        if not ok or type(connections)~='table' then return nil,'connections_unavailable' end
        local found
        for _,connection in pairs(connections) do
            local read,fn=pcall(function()return connection.Function end)
            if read and type(fn)=='function' and connected(connection,fn) then
                local origin=scriptOf(fn)
                local candidate
                if kind=='home' and origin==expected then
                    candidate={callback=fn,connection=connection,connectionFunction=fn}
                elseif kind~='home' and modules.DepthButton and origin==modules.DepthButton and type(d.getUpvalues)=='function' then
                    local got,values=pcall(d.getUpvalues,fn)
                    if got and type(values)=='table' then
                        for _,wrapper in pairs(values) do
                            if type(wrapper)=='table' and (wrapper.instance==button or wrapper.click_box==button)
                                and type(wrapper._is_active)=='function' and type(wrapper.mouse_button1_click)=='function'
                                and scriptOf(wrapper.mouse_button1_click)==expected then
                                local nextCandidate={callback=wrapper.mouse_button1_click,wrapper=wrapper,
                                    connection=connection,connectionFunction=fn}
                                if candidate and (candidate.callback~=nextCandidate.callback or candidate.wrapper~=wrapper) then
                                    return nil,'ambiguous_native_callback'
                                end
                                candidate=nextCandidate
                            end
                        end
                    end
                end
                if candidate then
                    if found and (found.callback~=candidate.callback or found.wrapper~=candidate.wrapper) then
                        return nil,'ambiguous_native_callback'
                    end
                    found=candidate
                end
            end
        end
        return found,found and nil or 'native_callback_missing'
    end
    function api.Press(button,authorize)
        if busy then return false,'native_callback_busy' end
        if not allowed(authorize) then return false,'not_authorized' end
        local pg=playerGui()
        if not visible(button,pg) then return false,'button_not_visible' end
        local kind=buttonKind(button,pg)
        if not kind then return false,'unknown_native_button' end
        local binding,reason=callbackFor(button,kind)
        if not binding then return false,reason end
        local old=sent[button]
        if old and old.callback==binding.callback and old.wrapper==binding.wrapper then return false,'native_callback_pending' end
        local wrapper=binding.wrapper
        if wrapper then
            local ok,active=pcall(wrapper._is_active,wrapper)
            if not ok or active~=true then return false,'native_button_inactive' end
        end
        -- Introspection can yield on an executor; never invoke a stale render or token.
        if not allowed(authorize) or playerGui()~=pg or not visible(button,pg)
            or buttonKind(button,pg)~=kind or not connected(binding.connection,binding.connectionFunction)
            or (wrapper and wrapper.mouse_button1_click~=binding.callback) then
            return false,'native_button_changed'
        end
        if busy then return false,'native_callback_busy' end
        old=sent[button]
        if old and old.callback==binding.callback and old.wrapper==binding.wrapper then return false,'native_callback_pending' end
        busy=true
        -- A callback may have side effects before throwing. Do not invoke the same
        -- render again while native cleanup/replication is still pending.
        sent[button]=binding
        local ok,err=pcall(binding.callback)
        busy=false
        if not ok then return false,'native_callback_error:'..tostring(err) end
        return true,'native_callback'
    end
    function api.IdentifyNormal(rules)
        local pg=playerGui()
        local dialog=path(pg,{'DialogApp','Dialog'})
        if not displayed(dialog,pg) then return {status='none'} end
        local normal
        for _,child in ipairs(dialog:GetChildren()) do
            if child:IsA('GuiObject') and child.Name~='Backing' and child.Name~='ExitButton' and displayed(child,pg) then
                if child.Name~='NormalDialog' or normal then
                    return {status='blocked',reason='unknown_native_dialog',dialog=child}
                end
                normal=child
            end
        end
        if not normal then return {status='none'} end
        local label=path(normal,{'Info','TextLabel'})
        local message=label and label.Text
        if type(message)~='string' or message=='' then return {status='pending',reason='dialog_text_pending',dialog=normal} end
        local rule
        for _,candidate in ipairs(rules or {}) do
            if candidate.text==message then
                if rule then return {status='blocked',reason='ambiguous_dialog_rule',dialog=normal,text=message} end
                rule=candidate
            end
        end
        if not rule then return {status='blocked',reason='unknown_dialog_text',dialog=normal,text=message} end
        local buttons=normal:FindFirstChild('Buttons')
        if not buttons then return {status='pending',reason='dialog_buttons_pending',dialog=normal,text=message} end
        local labels,byLabel,count={}, {},0
        for _,button in ipairs(buttons:GetChildren()) do
            if button:IsA('GuiButton') and displayed(button,pg) then
                local textLabel=path(button,{'Face','TextLabel'})
                local text=textLabel and textLabel.Text
                if type(text)~='string' or text=='' then return {status='pending',reason='dialog_labels_pending',dialog=normal,text=message} end
                count=count+1;labels[text]=(labels[text] or 0)+1;byLabel[text]=button
            end
        end
        if count==0 then return {status='pending',reason='dialog_buttons_pending',dialog=normal,text=message} end
        local expected={}
        for _,text in ipairs(rule.labels or {}) do expected[text]=(expected[text] or 0)+1 end
        for text,n in pairs(labels) do
            if expected[text]~=n then return {status='blocked',reason='unexpected_dialog_labels',dialog=normal,text=message} end
        end
        for text,n in pairs(expected) do
            if labels[text]~=n then return {status='pending',reason='dialog_labels_pending',dialog=normal,text=message} end
        end
        local button=byLabel[rule.response]
        if not button or labels[rule.response]~=1 then return {status='blocked',reason='invalid_dialog_response',dialog=normal,text=message} end
        if not visible(button,pg) then return {status='pending',reason='dialog_button_inactive',dialog=normal,text=message} end
        return {status='matched',action=rule.action,button=button,dialog=normal,text=message}
    end
    function api.HandleNormal(rules,authorize)
        local state=api.IdentifyNormal(rules)
        if state.status~='matched' then return state.status,state.reason end
        local function current()
            if not allowed(authorize) then return false end
            local latest=api.IdentifyNormal(rules)
            return latest.status=='matched' and latest.dialog==state.dialog and latest.button==state.button
                and latest.action==state.action and latest.text==state.text
        end
        local ok,reason=api.Press(state.button,current)
        return ok and 'handled' or 'pending',ok and state.action or reason
    end
    return api
end
