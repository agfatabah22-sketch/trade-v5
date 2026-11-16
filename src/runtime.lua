-- Auto-start host. Only this new script's runtime and overlay are owned here.
local env=type(getgenv)=="function" and getgenv() or _G
local Players=game:GetService("Players")
local previous=env.BlueHubTradeOnly
if type(previous)=="table" then
    local state=previous.Engine and previous.Engine.State
    if state and (state.pending or state.finalizationPending) then
        warn("[Blue Hub Trade Only] Trade/finalisasi sebelumnya belum pasti. Tidak menjalankan ulang.")
        return previous
    end
    if type(previous.Close)=="function" and previous.Close()==false then return previous end
end
local player=Players.LocalPlayer
local waitStarted=os.clock()
while not player and os.clock()-waitStarted<60 do task.wait(.1);player=Players.LocalPlayer end
if not player then warn("[Blue Hub Trade Only] Player belum siap.");return end
if game.PlaceId~=0 and game.PlaceId~=920587237 then warn("[Blue Hub Trade Only] Khusus Adopt Me.");return end
local recipientsOK,recipients=pcall(normalizeTradeRecipients,Config.Username)
local receiver=recipientsOK and recipients[1] or ""
-- A manual receiver can share autoexec with the sender. It never runs outbound actions.
if recipientsOK then
    for _,name in ipairs(recipients) do
        if player.Name:lower()==name:lower() then
            warn("[Blue Hub Trade Only] Ini akun penerima; pengirim otomatis dilewati.")
            return
        end
    end
end
local parent=player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui",60)
if not parent then warn("[Blue Hub Trade Only] PlayerGui belum siap.");return end
local app={Version="1.0.6-trade-only",Alive=true,Config=Config,Connections={}}
env.BlueHubTradeOnly=app
local overlay=makeOverlay({parent=parent,clock=os.clock,completionHoldSeconds=4})
app.Gui,app.Overlay=overlay.Gui,overlay
local stopped=false
function app.Stop(reason)
    stopped=true
    if app.Engine then app.Engine.Stop(reason) end
    local boot=env.__BlueHubTradeOnlyStartup
    if type(boot)=="table" and (boot.app==app or app.StartupPending and env.BlueHubTradeOnly==app)
        and boot.status=="waiting" then boot.status="stopped" end
    overlay.Set(app.Engine and app.Engine.State or {phase="blocked",detail=reason or "Dihentikan dengan F8.",recipient=receiver})
end
function app.Close()
    app.Stop("UI ditutup.")
    if app.Engine and (app.Engine.State.pending or app.Engine.State.finalizationPending) then return false end
    app.Alive=false
    for _,connection in ipairs(app.Connections) do connection:Disconnect() end
    overlay.Destroy()
    if env.BlueHubTradeOnly==app then env.BlueHubTradeOnly=nil end
    return true
end
local Input=game:GetService("UserInputService")
app.Connections[#app.Connections+1]=Input.InputBegan:Connect(function(input)
    if input.KeyCode==Enum.KeyCode.F8 then app.Stop("Dihentikan dengan F8. Periksa hasil trade sebelum menjalankan ulang.") end
end)
if Config.AutoStart==false then
    overlay.Set({phase="blocked",detail="AutoStart OFF di Config.",recipient=receiver})
    return app
end
if not recipientsOK or receiver=="" or type(Config.Pets)~="table" or type(Config.Accessories)~="table"
    or (#Config.Pets==0 and #Config.Accessories==0) then
    overlay.Set({phase="blocked",detail="Isi Username penerima dan daftar nama Pets di Config, lalu jalankan kembali.",recipient=receiver})
    return app
end
local ok,problem=pcall(function()
    local finalize
    local finalizationJobId
    local accountConfig=Config.FarmersV5
    if accountConfig~=nil and type(accountConfig)~="table" then
        error("FarmersV5 harus berupa tabel Config.",0)
    end
    if accountConfig and accountConfig.DisableAccount~=nil and type(accountConfig.DisableAccount)~="boolean" then
        error("DisableAccount harus true atau false.",0)
    end
    if accountConfig and accountConfig.DisableAccount==true then
        local http=game:GetService("HttpService")
        local synHttp=env.syn or syn
        local httpNamespace=env.http or _G.http
        local transport=type(env.request)=="function" and env.request
            or type(request)=="function" and request
            or type(env.http_request)=="function" and env.http_request
            or type(http_request)=="function" and http_request
            or type(synHttp)=="table" and type(synHttp.request)=="function" and synHttp.request
            or type(httpNamespace)=="table" and type(httpNamespace.request)=="function" and httpNamespace.request
        local accountOps=makeAccountOpsDisable({request=transport,
            jsonEncode=function(value)return http:JSONEncode(value)end,
            jsonDecode=function(value)return http:JSONDecode(value)end},accountConfig)
        local senderName,senderId=player.Name,player.UserId
        local validation=accountOps.Validate(senderName,receiver)
        if validation.ok~=true then
            error("AccountOps belum siap: "..tostring(validation.reason or "Periksa API key/request executor."),0)
        end
        app.AccountOps=accountOps
        finalize=function()
            local token={done=false}
            local finalCharacter,finalPlaceId=player.Character,game.PlaceId
            task.spawn(function()
                if stopped or not app.Alive or env.BlueHubTradeOnly~=app or Players.LocalPlayer~=player
                    or player.Name~=senderName or player.UserId~=senderId or game.JobId~=finalizationJobId
                    or player.Character~=finalCharacter or game.PlaceId~=finalPlaceId then
                    token.ok,token.reviewRequired,token.detail=false,false,"Finalisasi dibatalkan sebelum request; akun tidak dinonaktifkan."
                    token.done=true;return
                end
                local succeeded,result=pcall(accountOps.Disable,senderName,receiver)
                token.ok=succeeded and type(result)=="table" and result.confirmed==true
                token.reviewRequired=not succeeded or type(result)~="table" or result.ambiguous==true
                token.detail=token.ok and "Akun pengirim berhasil dinonaktifkan di AccountOps."
                    or succeeded and type(result)=="table" and ("AccountOps: "..tostring(result.reason or "Periksa status akun."))
                    or "Hasil request AccountOps belum pasti. Periksa status akun; request tidak diulang."
                token.done=true
            end)
            return token
        end
    end
    overlay.Set({phase="loading",detail="Menyiapkan Play/Home dan data inventory.",recipient=receiver})
    app.StartupPending=true
    local context,why,boot=makeStartup(Config,env,{
        makeNativeUI=makeNativeUI,makeStartupMenu=makeStartupMenu,
        makeStartupPopups=makeStartupPopups,makeStartupGate=makeStartupGate})
    app.StartupPending=false
    if stopped then return end
    if not context then error(why or "Startup belum siap.",0) end
    context.startup.app=app
    if stopped or not app.Alive or env.BlueHubTradeOnly~=app then return end
    finalizationJobId=game.JobId
    local adapter,conflict=makeBindings(context,env,Config,{
        makeNameResolver=makeNameResolver,makeTradePreparation=makeTradePreparation,
        makeTradeAdapter=makeTradeAdapter,makeTradeWarnings=makeTradeWarnings})
    local CD=context.modules.ClientData
    local controller=makeController({trade=adapter,clock=os.clock,localUsername=player.Name,
        completionSettleSeconds=3,conflict=conflict,finalize=finalize,finalizationTimeoutSeconds=30,
        context=function()
            return {placeId=game.PlaceId,jobId=game.JobId,userId=player.UserId,character=player.Character}
        end,
        ready=function()
            local char=player.Character
            local human=char and char:FindFirstChildOfClass("Humanoid")
            local root=char and char:FindFirstChild("HumanoidRootPart")
            return game:IsLoaded() and char~=nil and char.Parent~=nil and human~=nil and human.Health>0
                and root~=nil and root:IsA("BasePart")
        end,
        tradeBusy=function()
            local current=CD.get("trade")
            local manager=CD.get("trade_manager")
            if type(current)=="table" and current.trade_id then return true end
            return type(manager)=="table" and not not (manager.trade_id or manager.current_trade or manager.in_trade==true)
        end,
        hasRecipient=function(name)
            for _,candidate in ipairs(Players:GetPlayers()) do
                if candidate~=player and candidate.Name:lower()==name:lower() then return true end
            end
            return false
        end},Config)
    app.Engine,app.Trade=controller,adapter
    -- Passive, bounded observations only. Diagnostic failure cannot stop a trade.
    local diagnosticsOK,diagnostics=pcall(function()
        return makeDiagnostics({clock=os.clock,readSnapshot=makeDiagnosticSnapshot(context,app)})
    end)
    if diagnosticsOK and type(diagnostics)=="table" then app.Diagnostics=diagnostics end
    context.startup.status,context.startup.stage="running","trade_only"
    overlay.Set(controller.State)
    task.spawn(function()
        while app.Alive and env.BlueHubTradeOnly==app do
            if overlay.Gui.Parent==nil then
                app.Stop("Overlay dihapus. Trade dihentikan.")
                if not controller.State.pending and not controller.State.finalizationPending then app.Close();return end
            end
            if app.Diagnostics then pcall(app.Diagnostics.Sample) end
            controller.Step()
            if app.Diagnostics then pcall(app.Diagnostics.Sample) end
            if overlay.Gui.Parent~=nil then overlay.Set(controller.State) end
            task.wait(.2)
        end
    end)
end)
if not ok and app.Alive and env.BlueHubTradeOnly==app then
    stopped=true
    overlay.Set({phase="error",detail=tostring(problem),recipient=receiver})
    warn("[Blue Hub Trade Only] "..tostring(problem))
end
return app
