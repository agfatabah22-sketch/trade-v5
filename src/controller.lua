-- Pure trade-only controller. The adapter owns receipt validation and native trades.
return function(d, config)
    config = config or {}
    local state = {phase="loading", detail="Menyiapkan trade otomatis.", enabled=config.AutoStart~=false,
        pending=false, finalizationPending=false, sent=0, totalRemaining=0, blocked=0, batches=0, recipient=""}
    local api = {State=state}
    local pending, baseSent, baseBatches, originalContext, emptySince, waitingSince
    local terminal, inStep = false, false
    local finalizing, finalizationStarted, finalizationAborted
    local finalizationTimeout = d.finalizationTimeoutSeconds or 30
    local recipientsValid,recipients=pcall(normalizeTradeRecipients,config.Username)
    local configuredNames={}
    if recipientsValid then
        for _,name in ipairs(recipients) do configuredNames[name:lower()]=name end
        state.recipient=recipients[1]
    end
    local retryRequests=config.AutoRetryTradeRequest~=false
    local timeout = tonumber(config.WaitForRecipientSeconds) or 120
    local settleSeconds = d.completionSettleSeconds or 3
    local function integer(value)
        return type(value)=="number" and value==value and value>=0 and value<math.huge and value%1==0
    end
    local function same(a,b)
        return type(a)=="table" and type(b)=="table" and a.placeId==b.placeId and a.jobId==b.jobId
            and a.userId==b.userId and a.character==b.character
    end
    local function say(phase,detail) state.phase,state.detail=phase,detail end
    local function halt(detail,isError)
        if finalizing then finalizationAborted=true end
        state.enabled=false;terminal=true;emptySince=nil
        state.error=isError==true
        say(isError and "error" or "blocked",detail)
    end
    function api.Stop(reason)
        halt(reason or "Dihentikan dengan F8. Periksa hasil sebelum menjalankan ulang.",false)
        return state
    end
    local function contextOK()
        local current=d.context()
        if type(current)~="table" or current.placeId~=920587237 or type(current.jobId)~="string"
            or current.jobId=="" or not integer(current.userId) or current.userId==0 or current.character==nil then
            return false
        end
        if not originalContext then originalContext=current end
        return same(current,originalContext)
    end
    d.trade.setGuard(function()
        return state.enabled and not terminal and contextOK() and d.ready()==true
            and (not d.conflict or not d.conflict())
    end)
    local function inspect()
        local selected=d.trade.preview()
        assert(type(selected)=="table" and integer(selected.intendedTotal)
            and integer(selected.blockedTotal),"Jumlah target trade belum dapat dipastikan.")
        assert(selected.intendedTotal>=#selected and selected.blockedTotal<=selected.intendedTotal,
            "Jumlah target trade tidak konsisten.")
        state.totalRemaining,state.blocked=selected.intendedTotal,selected.blockedTotal
        return selected
    end
    local function poll()
        if not pending then return end
        if type(pending.recipient)=="string" then
            local name=configuredNames[pending.recipient:lower()]
            if name then state.recipient=name end
        end
        if pending.transferred~=nil then
            assert(integer(pending.transferred),"Jumlah item terkirim tidak valid.")
            state.sent=baseSent+pending.transferred
        end
        if pending.batches~=nil then
            assert(integer(pending.batches),"Jumlah batch tidak valid.")
            state.batches=baseBatches+pending.batches
        end
        if state.enabled and pending.detail then say("trading",tostring(pending.detail)) end
        if pending.uncertain==true and pending.ok~=true then
            halt("Hasil trade belum terkonfirmasi. Akun tidak dianggap selesai.",true)
            return
        end
        if pending.done~=true then return end
        local completed=pending;pending=nil;state.pending=false
        if completed.ok~=true then
            halt(tostring(completed.error or "Trade belum berhasil. Periksa akun ini."),true)
            return
        end
        emptySince=nil
    end
    local function pollFinalization()
        if finalizing.done~=true then
            if not finalizationAborted and d.clock()-finalizationStarted>=finalizationTimeout then
                halt("Hasil disable AccountOps belum pasti. Periksa AccountOps; request tidak diulang.",true)
            end
            return
        end
        local result=finalizing
        finalizing=nil
        state.finalizationPending=result.ok~=true and result.reviewRequired==true
        if result.ok~=true then
            halt(result.detail or "Disable AccountOps belum terkonfirmasi. Periksa akun ini.",true)
            return
        end
        state.accountDisabled=true
        -- A late acknowledgement may resolve uncertainty, but cannot undo F8/timeout.
        if finalizationAborted then return end
        if not contextOK() then
            halt("Disable berhasil, tetapi konteks game berubah. Periksa akun sebelum melanjutkan.",true)
            return
        end
        state.error=false
        say("complete","Semua target selesai. Akun pengirim berhasil dinonaktifkan di AccountOps.")
    end
    local function step()
        if finalizing then pollFinalization();return end
        if pending then poll() end
        if pending or not state.enabled or terminal then return end
        if not recipientsValid then
            halt("Isi Username penerima atau daftar username yang valid di bagian Config, lalu jalankan kembali.",false);return
        end
        if config.AutoRetryTradeRequest~=nil and type(config.AutoRetryTradeRequest)~="boolean" then
            halt("AutoRetryTradeRequest harus true atau false.",false);return
        end
        if type(d.localUsername)=="string" and configuredNames[d.localUsername:lower()] then
            halt("Akun pengirim dan penerima harus berbeda.",false);return
        end
        if not contextOK() then halt("Karakter atau server berubah. Periksa akun sebelum melanjutkan.",true);return end
        if d.ready()~=true then
            emptySince=nil;say("waiting","Menunggu karakter dan data game siap.");return
        end
        local conflict=d.conflict and d.conflict()
        if conflict then emptySince=nil;say("blocked",tostring(conflict));return end
        if d.tradeBusy() then
            emptySince=nil;say("waiting","Menunggu trade yang sedang terbuka selesai.");return
        end
        local selected=inspect()
        if selected.intendedTotal==0 then
            emptySince=emptySince or d.clock()
            if d.clock()-emptySince<settleSeconds then
                say("waiting","Memastikan semua target trade sudah selesai...");return
            end
            state.enabled=false;terminal=true;state.error=false
            if type(d.finalize)=="function" then
                -- Hold the exact completion label until the external action is acknowledged.
                state.finalizationPending=true
                finalizing={done=false}
                finalizationStarted=d.clock()
                say("finalizing","Semua target selesai. Mengirim disable untuk akun pengirim ke AccountOps.")
                local called,result=pcall(d.finalize)
                if not called or type(result)~="table" then
                    halt("Finalisasi AccountOps gagal dimulai. Periksa akun; request tidak diulang.",true)
                    return
                end
                finalizing=result
                return
            end
            say("complete","Semua pet/egg pilihan selesai. Menunggu pergantian akun pengirim.")
            return
        end
        emptySince=nil
        if #selected==0 then
            halt(string.format("Masih ada %d target tertahan: terkunci, tidak bisa ditrade, atau pet terakhir. Periksa Keep/Excluded.",selected.blockedTotal),false)
            return
        end
        local onlineRecipient
        for _,name in ipairs(recipients) do
            if d.hasRecipient(name) then onlineRecipient=name;break end
        end
        if not onlineRecipient then
            waitingSince=waitingSince or d.clock()
            if not retryRequests and d.clock()-waitingSince>=timeout then
                halt("Penerima belum ada di server ini. Jalankan ulang setelah salah satu penerima masuk.",false)
            else say("waiting","Menunggu salah satu penerima dalam Config masuk ke server yang sama.") end
            return
        end
        waitingSince=nil
        state.recipient=onlineRecipient
        baseSent,baseBatches=state.sent,state.batches
        state.pending=true;say("trading","Menyiapkan request trade ke penerima yang tersedia.")
        -- The placeholder prevents re-entry while an adapter is starting.
        pending={done=false,transferred=0,batches=0}
        local result=d.trade.run(#recipients==1 and recipients[1] or recipients)
        assert(type(result)=="table","Adapter tidak memberi status trade.")
        pending=result
    end
    function api.Step()
        if inStep then return state end
        inStep=true
        local ok,problem=pcall(step)
        inStep=false
        if not ok then halt(tostring(problem),true) end
        return state
    end
    if config.AutoStart==false then halt("AutoStart OFF di Config.",false) end
    return api
end
