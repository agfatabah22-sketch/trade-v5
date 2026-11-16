-- Native outbound trade workflow. Construction/selection are read-only.
-- run() is admitted by the trade-only host after selection and native startup readiness.
return function(d, settings)
    settings = settings or {}
    local api, guard, active = {}, function() return false end, nil
    local function text(v) return type(v)=='string' and v:match('%S')~=nil end
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
    local retryRequests=settings.AutoRetryTradeRequest~=false
    local retrySeconds=settings.TradeRequestRetrySeconds==nil and 15 or settings.TradeRequestRetrySeconds
    local switchSeconds=settings.RecipientSwitchSeconds==nil and 3 or settings.RecipientSwitchSeconds
    local batchAddItems=settings.BatchAddItems~=false
    local function marked(t,k) return type(t)=='table' and t[k]~=nil and t[k]~=false end
    local function variant(item)
        local p=item.properties or {}
        return p.mega_neon==true and 'mega' or p.neon==true and 'neon' or 'regular'
    end
    local function flags(item)
        for _,v in ipairs({item,item.properties or {}}) do
            for _,k in ipairs({'locked','is_locked','favorite','favourite','favorited','favourited','is_favorite','is_favourite','temporary'}) do
                if v[k]~=nil and v[k]~=false then return true end
            end
        end
        return false
    end
    local function activeSet(raw)
        local out={}
        for k,v in pairs(type(raw)=='table' and raw or {}) do
            if text(k) and v~=nil and v~=false then out[k]=true end
            if text(v) then out[v]=true
            elseif type(v)=='table' then
                if text(v.unique) then out[v.unique]=true end
                if text(v.pet_unique) then out[v.pet_unique]=true end
            end
        end
        return out
    end
    local function match(item, rule)
        return (item.kind or item.id)==rule.id and item.category==rule.category
            and (not rule.version or variant(item)==rule.version)
            and (not rule.age or tonumber((item.properties or {}).age)==rule.age)
    end
    local function resolve(raw,categories)
        assert(text(raw),'Isi daftar nama pet, egg, atau aksesori yang ingin dikirim.')
        if categories==nil then categories={'pets'};if type(d.DB.pet_accessories)=='table' then categories[2]='pet_accessories' end end
        local canonical=raw
        if d.resolver then canonical=assert(d.resolver.Resolve(raw,categories,{suffix=true})) end
        local parts={};for part in canonical:gmatch('[^:]+') do parts[#parts+1]=part end
        local id,v,age=parts[1],nil,nil
        assert(text(id) and canonical:sub(-1)~=':' and not canonical:find('::',1,true),'Invalid Config selector: '..raw)
        local index=2
        while index<=#parts do
            local suffix=parts[index]
            if suffix=='regular' or suffix=='neon' or suffix=='mega' then
                assert(v==nil,'Duplicate Config variant: '..raw);v=suffix;index=index+1
            elseif suffix=='age' then
                local value=tonumber(parts[index+1])
                assert(age==nil and finite(value) and value%1==0 and value>=1 and value<=6,'Invalid Config age: '..raw)
                age=value;index=index+2
            else error('Invalid Config selector suffix: '..raw) end
        end
        local category
        for _,scope in ipairs(categories)do
            if type(d.DB[scope])=='table' and type(d.DB[scope][id])=='table' then
                assert(category==nil,'Ambiguous Config item: '..raw);category=scope
            end
        end
        assert(category,'Unknown Config item: '..raw)
        assert((v==nil and age==nil) or category=='pets','Accessories cannot use pet variants or ages: '..raw)
        return {id=id,category=category,version=v,age=age}
    end
    local excluded,keeps,selectedPets,selectedAccessories={}, {}, {}, {}
    local function list(value,label)
        if value==nil then return {} end
        assert(type(value)=='table',label..' must be a list.')
        local count,maximum=0,0
        for index in pairs(value)do
            assert(finite(index) and index>=1 and index%1==0,label..' must use consecutive list indexes.')
            count=count+1;maximum=math.max(maximum,index)
        end
        assert(count==maximum,label..' has missing list entries.')
        return value
    end
    local valid,configError=pcall(function()
        assert(settings.AutoRetryTradeRequest==nil or type(settings.AutoRetryTradeRequest)=='boolean',
            'Config.AutoRetryTradeRequest must be true or false.')
        assert(settings.BatchAddItems==nil or type(settings.BatchAddItems)=='boolean',
            'Config.BatchAddItems must be true or false.')
        assert(finite(retrySeconds) and retrySeconds>=10 and retrySeconds<=300,
            'Config.TradeRequestRetrySeconds must be between 10 and 300 seconds.')
        assert(finite(switchSeconds) and switchSeconds>=1 and switchSeconds<=300,
            'Config.RecipientSwitchSeconds must be between 1 and 300 seconds.')
        assert(settings.AllPets==nil or type(settings.AllPets)=='boolean','Config.AllPets must be true or false.')
        assert(settings.Keep==nil or type(settings.Keep)=='table','Config.Keep must be a name-to-count table.')
        for _,raw in ipairs(list(settings.Excluded,'Config.Excluded')) do excluded[#excluded+1]=resolve(raw) end
        for raw,n in pairs(settings.Keep or {}) do
            assert(finite(n) and n>=0 and n%1==0,'Config.Keep must use nonnegative whole counts.')
            local rule=resolve(raw);rule.minimum=n;keeps[#keeps+1]=rule
        end
        for _,raw in ipairs(list(settings.Pets,'Config.Pets')) do
            selectedPets[#selectedPets+1]=resolve(raw,{'pets'})
        end
        for _,raw in ipairs(list(settings.Accessories,'Config.Accessories'))do
            local rule=resolve(raw,{'pet_accessories'})
            selectedAccessories[rule.id]=true
        end
        assert(settings.AllPets==true or #selectedPets>0 or next(selectedAccessories)~=nil,
            'Isi Config.Pets dengan nama pet atau egg yang ingin dikirim terlebih dahulu.')
    end)
    local function inventory()
        local inv=d.CD.get('inventory')
        assert(type(inv)=='table' and type(inv.pets)=='table','Trade inventory is not ready.')
        local merged={}
        local categories={'pets'};if next(selectedAccessories)then categories[2]='pet_accessories' end
        for _,category in ipairs(categories)do
            assert(type(inv[category])=='table','Trade '..category..' inventory is not ready.')
            for id,item in pairs(inv[category])do
                assert(text(id) and type(item)=='table' and item.unique==id and text(item.kind or item.id),'Malformed trade inventory.')
                assert(item.category==nil or item.category==category,'Trade inventory category changed.')
                assert(not merged[id],'Duplicate unique ID across trade inventory categories.')
                local copied={};for k,v in pairs(item)do copied[k]=v end;copied.category=category
                merged[id]=copied
            end
        end
        return merged
    end
    local function assignments()
        local equip,pen=d.CD.get('equip_manager'),d.CD.get('idle_progression_manager')
        assert(type(equip)=='table' and type(pen)=='table','Pet assignment data is not ready.')
        assert(equip.pets==nil or type(equip.pets)=='table','Equipped pet data is not ready.')
        assert(pen.active_pets==nil or type(pen.active_pets)=='table','Pet Pen data is not ready.')
        local wrappers=d.CD.get('pet_char_wrappers')
        assert(wrappers==nil or type(wrappers)=='table','Equipped pet wrappers are not ready.')
        local equipped,inPen=activeSet(equip.pets),activeSet(pen.active_pets)
        for _,wrapper in pairs(wrappers or {}) do
            if type(wrapper)=='table' and text(wrapper.pet_unique) then equipped[wrapper.pet_unique]=true end
        end
        return equipped,inPen
    end
    local function selection(allowed,strictAssignments)
        assert(valid,tostring(configError))
        local pets=inventory()
        local equip,pen,locks=d.CD.get('equip_manager'),d.CD.get('idle_progression_manager'),d.CD.get('backpack_locks') or {}
        assert(type(equip)=='table' and type(pen)=='table' and type(locks)=='table','Trade protection data is not ready.')
        local equipped,inPen=assignments()
        local all,permanent={},0
        for id,item in pairs(pets) do
            assert(text(id) and type(item)=='table' and item.unique==id and text(item.kind or item.id),'Malformed trade inventory.')
            assert(item.properties==nil or type(item.properties)=='table','Malformed pet properties.')
            local meta=d.DB[item.category][item.kind or item.id]
            if item.category=='pets' and type(meta)=='table' and not marked(meta,'temporary')
                and not marked(item,'temporary') and not marked(item.properties,'temporary') then permanent=permanent+1 end
            all[#all+1]=item
        end
        table.sort(all,function(a,b)return a.unique<b.unique end)
        local counts={}
        for i,rule in ipairs(keeps) do
            counts[i]=0
            for _,item in ipairs(all) do if match(item,rule) then counts[i]=counts[i]+1 end end
        end
        local selected={intendedTotal=0,blockedTotal=0,blockedReasons={}}
        for _,item in ipairs(all) do
            local id=item.kind or item.id
            local meta=d.DB[item.category][id]
            local isPet=item.category=='pets'
            local intended=not isPet and selectedAccessories[id]==true or isPet and settings.AllPets==true
            if isPet and not intended then
                for _,rule in ipairs(selectedPets)do if match(item,rule) then intended=true;break end end
            end
            intended=intended and (allowed==nil or allowed[item.unique])
            for _,rule in ipairs(excluded) do if match(item,rule) then intended=false end end
            for i,rule in ipairs(keeps) do if match(item,rule) and counts[i]<=rule.minimum then intended=false end end
            if intended then
                selected.intendedTotal=selected.intendedTotal+1
                local reason
                if type(meta)~='table' then reason='unknown_item'
                elseif flags(item) or marked(locks,item.unique) or marked(locks[item.category],item.unique) then reason='locked_or_favorite'
                elseif meta.progression_locked==true then reason='progression_locked'
                elseif meta.temporary==true then reason='temporary'
                elseif isPet and equipped[item.unique] and (strictAssignments or settings.IncludeEquipped~=true) then reason='equipped'
                elseif isPet and inPen[item.unique] and (strictAssignments or settings.IncludePetPen~=true) then reason='pet_pen'
                elseif isPet and permanent<=1 then reason='last_permanent_pet' end
                if not reason then
                local nativeItem={};for k,v in pairs(item) do nativeItem[k]=v end
                assert(type(d.Locks.is_locked)=='function' and type(d.ItemHider.is_item_tradeable)=='function','Native trade protections are unavailable.')
                local accessoryEquipped=false
                if not isPet then
                    assert(type(d.isAccessoryEquipped)=='function','Accessory assignment protection is unavailable.')
                    accessoryEquipped=d.isAccessoryEquipped(nativeItem)
                    assert(type(accessoryEquipped)=='boolean','Accessory assignment state is unknown.')
                end
                local locked=d.Locks.is_locked(nativeItem)
                local tradeable=d.ItemHider.is_item_tradeable(meta,nativeItem)
                assert(type(locked)=='boolean' and type(tradeable)=='boolean','Native trade eligibility is unknown.')
                if locked then reason='native_locked'
                elseif not tradeable then reason='not_tradeable'
                elseif accessoryEquipped then reason='worn_accessory'
                else
                    selected[#selected+1]=item.unique;if isPet then permanent=permanent-1 end
                    for i,rule in ipairs(keeps) do if match(item,rule) then counts[i]=counts[i]-1 end end
                end
                end
                if reason then
                    selected.blockedTotal=selected.blockedTotal+1
                    selected.blockedReasons[reason]=(selected.blockedReasons[reason] or 0)+1
                end
            end
        end
        selected.eligibleTotal=#selected
        return selected
    end
    function api.setGuard(fn) guard=fn end
    function api.preview() return selection() end
    function api.run(username)
        if active and not active.done then return active end
        local token={done=false,ok=false,dispatched=false,transferred=0,batches=0,detail='Checking trade recipient.'}
        active=token
        d.spawn(function()
            local partner,partnerName,job,character,ownedID,committed,planned,requested,added,offered,preparing,lastAddAt
            local recipientNames,recipientSet,requestedPlayers={}, {}, {}
            local lastRequestAt,lastRequestByName=nil,{}
            local nextRecipientIndex=1
            local acceptAcknowledged,confirmAcknowledged=false,false
            local function alive()
                assert(guard()==true,'Trade stopped.')
                assert(d.game.PlaceId==920587237 and d.game.JobId==job and d.player.Character==character,'Trade context changed.')
                -- An unavailable candidate is retryable only before any trade opens.
                -- Once pinned, keep the original party identity for every item/receipt.
                if ownedID then
                    assert(partner and partner.Parent==d.Players and partner.UserId~=d.player.UserId
                        and partner.Name:lower()==partnerName and recipientSet[partnerName]
                        and d.Players:GetPlayerByUserId(partner.UserId)==partner,'Trade recipient left or changed.')
                end
                if d.conflict then assert(not d.conflict(),'Another activity is active.') end
            end
            local function state()
                local t=d.CD.get('trade')
                if t==nil then return end
                assert(type(t)=='table' and t.trade_id~=nil,'Native trade state is invalid.')
                return t
            end
            local function ours(t)
                return t and ((t.sender==d.player and t.recipient==partner) or (t.recipient==d.player and t.sender==partner))
            end
            local function onlineIdentity(candidate)
                return candidate and candidate.Parent==d.Players and candidate.UserId~=d.player.UserId
                    and recipientSet[candidate.Name:lower()]
                    and d.Players:GetPlayerByUserId(candidate.UserId)==candidate
            end
            local function requestReadyAt(name)
                if not retryRequests then return -math.huge end
                return math.max(lastRequestAt and lastRequestAt+switchSeconds or -math.huge,
                    lastRequestByName[name] and lastRequestByName[name]+retrySeconds or -math.huge)
            end
            local function chooseOnline(eligibleOnly)
                local hasOnline,earliest=false,nil
                for offset=0,#recipientNames-1 do
                    local index=(nextRecipientIndex+offset-1)%#recipientNames+1
                    local name=recipientNames[index]:lower()
                    local found
                    for _,candidate in ipairs(d.Players:GetPlayers()) do
                        if candidate.Name:lower()==name then
                            assert(not found,'Ambiguous trade username.');found=candidate
                        end
                    end
                    if onlineIdentity(found) then
                        hasOnline=true
                        local readyAt=requestReadyAt(name)
                        if not eligibleOnly or d.clock()>=readyAt then
                            return found,index%#recipientNames+1,true
                        end
                        earliest=earliest and math.min(earliest,readyAt) or readyAt
                    end
                end
                return nil,nil,hasOnline,earliest
            end
            local function requestedPartner(t)
                if not t then return end
                local candidate=t.sender==d.player and t.recipient or t.recipient==d.player and t.sender
                local sent=candidate and requestedPlayers[candidate.UserId]
                if sent and sent.player==candidate and sent.name==candidate.Name:lower()
                    and onlineIdentity(candidate) then return candidate end
            end
            local function adoptRequestedTrade(current)
                local candidate=requestedPartner(current)
                assert(candidate,'A different or unrequested trade appeared.')
                assert(not ownedID or ownedID==current.trade_id,'Trade changed before dispatch.')
                partner,partnerName,ownedID=candidate,candidate.Name:lower(),current.trade_id
                token.recipient=partner.Name
                return current
            end
            local function offer(t)
                assert(ours(t) and (not ownedID or t.trade_id==ownedID),'Unexpected trade or recipient.')
                local mine=t.sender==d.player and t.sender_offer or t.recipient_offer
                local theirs=t.sender==d.player and t.recipient_offer or t.sender_offer
                assert(type(mine)=='table' and type(mine.items)=='table' and type(theirs)=='table' and type(theirs.items)=='table','Trade offers are unavailable.')
                if ownedID and t.trade_id==ownedID then
                    -- Once observed, acknowledgement cannot be undone by a later
                    -- flag reset or by a yielding helper reading a newer version.
                    acceptAcknowledged=acceptAcknowledged or mine.negotiated==true
                    confirmAcknowledged=confirmAcknowledged or mine.confirmed==true
                end
                return mine,theirs
            end
            local sameItems,stillSelected,stillPrepared,fingerprint,nativeTimerReady,handleWarning
            local function sameReview(current,review)
                local _,other=offer(current)
                return current.trade_id==review.tradeId and current.current_stage==review.stage
                    and current.offer_version==review.offerVersion
                    and fingerprint(other.items)==review.partnerFingerprint
            end
            local function reviewReady(current,review)
                if not sameReview(current,review) then return false end
                -- FastConfirm is a bounded early attempt after a stable review,
                -- not a claim that this delay is the server's minimum.
                if review.early then return d.clock()>=review.readyAt end
                local ready=nativeTimerReady(current)
                if ready==nil then return not review.nativeOnly and d.clock()>=review.readyAt end
                return ready
            end
            local function send(name,argument,review)
                alive()
                local remote=d.Router.get('TradeAPI/'..name)
                -- Router lookup may yield; commit only after another identity check.
                alive()
                assert(remote and remote:IsA('RemoteEvent'),'Native trade event unavailable: '..name)
                if name=='SendTradeRequest' then
                    local current=state()
                    if current then adoptRequestedTrade(current);return false end
                    assert(d.License.player_has_trade_license(d.player)==true,'Trading License belum tersedia untuk akun ini.')
                    assert(d.Policy.is_trading_prohibited(d.player)==false,'Native policy does not permit trading.')
                    stillSelected(planned)
                    stillPrepared(planned)
                    alive()
                    -- Eligibility/Router helpers can yield. A late acceptance wins
                    -- over rotating/sending another request, including older targets.
                    current=state()
                    if current then adoptRequestedTrade(current);return false end
                    if not onlineIdentity(argument) then return false end
                    local requestName=argument.Name:lower()
                    local dispatchedAt=d.clock()
                    if dispatchedAt<requestReadyAt(requestName) then return false end
                    -- Stamp the actual dispatch, not the earlier candidate lookup
                    -- or a possibly delayed return from FireServer.
                    lastRequestAt,lastRequestByName[requestName]=dispatchedAt,dispatchedAt
                    requestedPlayers[argument.UserId]={player=argument,name=argument.Name:lower()}
                    requested=true
                    token.recipient=argument.Name
                    token.requestAttempts=(token.requestAttempts or 0)+1
                else
                    local id=name=='AddItemToOffer' and argument or nil
                    if name=='AcceptNegotiation' or name=='ConfirmTrade' then
                        assert(type(review)=='table','Trade review is unavailable before dispatch.')
                    end
                    local function validateOffer()
                        local current=state();local mine=offer(current)
                        assert(current.trade_id==ownedID,'Trade changed before dispatch.')
                        assert(sameItems(mine.items,planned,name=='AddItemToOffer'),'Trade items changed before dispatch.')
                        assert(current.current_stage==(name=='ConfirmTrade' and 'confirmation' or 'negotiation'),'Trade stage changed before dispatch.')
                        if name=='AcceptNegotiation' and acceptAcknowledged
                            or name=='ConfirmTrade' and confirmAcknowledged then return false end
                        if name=='AddItemToOffer' then
                            assert(text(id) and added and added[id]==false,'Trade item was already sent or was not planned.')
                            assert(not mine.negotiated,'Trade was accepted while filling the offer.')
                            if batchAddItems then
                                local dispatched={}
                                for _,plannedID in ipairs(planned) do
                                    if added[plannedID] then dispatched[#dispatched+1]=plannedID end
                                end
                                assert(sameItems(mine.items,dispatched,true),'Trade offer contains items not yet dispatched.')
                            else
                                assert(sameItems(mine.items,offered,false),'Previously acknowledged trade items changed.')
                            end
                            for _,item in pairs(mine.items) do
                                assert(added[item.unique]==true,'An unrequested item appeared while filling the offer.')
                            end
                        end
                        if review and not sameReview(current,review) then return false end
                        return current
                    end
                    if not validateOffer() then return false end
                    stillSelected(planned)
                    alive()
                    if name=='ConfirmTrade' and not handleWarning(review) then return false end
                    -- Eligibility/native helpers may yield. Revalidate the exact
                    -- current offer immediately before this individual dispatch.
                    local current=validateOffer()
                    if not current then return false end
                    if review and name~='AddItemToOffer' then
                        -- Recheck the chosen stable-review/native-clock gate after
                        -- yielding helpers, then validate the exact offer and guard.
                        local ready=reviewReady(current,review)
                        alive()
                        if not validateOffer() or not ready then return false end
                    end
                    -- Native eligibility/timing/warning helpers above may yield.
                    -- Refresh local assignment/protection state after those calls;
                    -- this last check invokes no potentially yielding native helper.
                    stillPrepared(planned)
                    alive()
                    if not validateOffer() then return false end
                    if name=='AddItemToOffer' then added[id]=true end
                end
                if name=='ConfirmTrade' then committed=true end
                token.dispatched=true
                if name=='AddItemToOffer' then lastAddAt=d.clock() end
                if argument~=nil then remote:FireServer(argument) else remote:FireServer() end
                return true
            end
            sameItems=function(items,ids,allowSubset,history)
                local set={};for _,id in ipairs(ids) do set[id]=true end
                local count,seen=0,{}
                for _,item in pairs(items) do
                    if type(item)~='table' then return false end
                    -- Live offers use unique; server history serializes unique_id.
                    -- Keep the two schemas separate so offer admission stays strict.
                    local id=item.unique
                    if history then id=item.unique_id end
                    if history and item.unique~=nil and item.unique~=id then return false end
                    if not text(id) or not set[id] or seen[id] then return false end
                    seen[id]=true;count=count+1
                end
                return allowSubset or count==#ids
            end
            fingerprint=function(items)
                local ids={}
                for _,item in pairs(items) do
                    assert(type(item)=='table' and text(item.unique),'Malformed partner offer.')
                    ids[#ids+1]=item.unique
                end
                table.sort(ids)
                return table.concat(ids,'\0')
            end
            local function waitFor(test,seconds,label,pollInterval)
                local deadline=d.clock()+seconds
                while true do
                    alive()
                    local result=test()
                    alive()
                    if result then return result end
                    assert(d.clock()<deadline,label..' timed out.')
                    d.wait(pollInterval or .2)
                end
            end
            stillSelected=function(ids)
                local allowed={};for _,id in ipairs(ids) do allowed[id]=true end
                local current=selection(allowed,true)
                assert(#current==#ids,'Trade items or protections changed.')
            end
            stillPrepared=function(ids)
                local pets=inventory()
                local equipped,inPen=assignments()
                local locks=d.CD.get('backpack_locks') or {}
                assert(type(locks)=='table','Trade protection data is not ready.')
                local permanent,sentPermanent=0,0
                for _,item in pairs(pets) do
                    local meta=d.DB[item.category][item.kind or item.id]
                    if item.category=='pets' and type(meta)=='table' and not marked(meta,'temporary')
                        and not marked(item,'temporary') and not marked(item.properties,'temporary') then
                        permanent=permanent+1
                    end
                end
                for _,id in ipairs(ids) do
                    local item=pets[id]
                    assert(item,'Trade item disappeared before dispatch.')
                    local meta=d.DB[item.category][item.kind or item.id]
                    assert(type(meta)=='table' and not flags(item) and not marked(locks,id)
                        and not marked(locks[item.category],id) and not meta.temporary and not meta.progression_locked,
                        'Trade item protection changed before dispatch.')
                    if item.category=='pets' then
                        assert(not equipped[id] and not inPen[id],'Selected pet assignment changed before dispatch.')
                        sentPermanent=sentPermanent+1
                    end
                end
                assert(sentPermanent==0 or permanent>sentPermanent,'Last permanent pet protection changed before dispatch.')
            end
            local function waitForRequestedTrade()
                local firstRequestAt
                while true do
                    alive()
                    local current=state()
                    if current then return adoptRequestedTrade(current) end
                    if not retryRequests and firstRequestAt then
                        assert(d.clock()-firstRequestAt<60,'Waiting for recipient timed out.')
                    end
                    if retryRequests or not firstRequestAt then
                        local candidate,nextIndex,hasOnline,readyAt=chooseOnline(true)
                        if candidate then
                            partner=candidate
                            token.recipient=candidate.Name
                            token.detail='Mengirim request trade ke @'..candidate.Name..'.'
                            local sent=send('SendTradeRequest',candidate)
                            if sent then
                                firstRequestAt=firstRequestAt or lastRequestAt
                                nextRecipientIndex=nextIndex
                                token.detail='Menunggu @'..candidate.Name..' menerima trade'
                                    ..(retryRequests and '; akan mencoba penerima berikutnya bila belum terbuka.' or '.')
                            end
                            current=state()
                            if current then return adoptRequestedTrade(current) end
                        else
                            assert(retryRequests,'Recipient must be in the same server.')
                            if hasOnline then
                                token.detail='Belum ada trade terbuka; menunggu jeda request '
                                    ..math.max(0,math.ceil((readyAt or d.clock())-d.clock()))..' detik.'
                            else
                                token.recipient=''
                                token.detail='Menunggu salah satu penerima di daftar masuk ke server. F8 untuk berhenti.'
                            end
                        end
                    end
                    d.wait(.2)
                end
            end
            local function prepCleared(record)
                if d.game.JobId~=job or d.player.Character~=character then return false end
                local equipped,inPen=assignments()
                return not (record.kind=='unequip' and equipped[record.id] or record.kind=='pen' and inPen[record.id])
            end
            local function prepareAssignments(initial,allowed)
                if settings.IncludePetPen~=true and settings.IncludeEquipped~=true then return end
                local sent={}
                for _,id in ipairs(initial) do
                    local initialItem=inventory()[id]
                    if initialItem and initialItem.category=='pets' then
                    for _,kind in ipairs({'pen','unequip'}) do
                        alive()
                        assert(state()==nil,'Another trade started during pet preparation.')
                        local function authorized()
                            local ok,value=pcall(function()
                                alive();assert(state()==nil,'Another trade started during pet preparation.')
                                local equipped,inPen=assignments()
                                local needs=kind=='pen' and settings.IncludePetPen==true and inPen[id]
                                    or kind=='unequip' and settings.IncludeEquipped==true and equipped[id]
                                if needs~=true then return false end
                                local eligible=false
                                for _,candidate in ipairs(selection(allowed)) do if candidate==id then eligible=true;break end end
                                if not eligible then return false end
                                alive();assert(state()==nil,'Another trade started during pet preparation.')
                                return needs==true
                            end)
                            return ok and value==true
                        end
                        if authorized() then
                            local key=kind..'\0'..id
                            assert(not sent[key],'Pet preparation was already dispatched.')
                            local callback=kind=='pen' and d.removeTradePetFromPen or d.unequipTradePet
                            assert(type(callback)=='function','Native pet preparation is unavailable: '..kind)
                            token.detail=kind=='pen' and 'Removing selected pet from Pet Pen before trade.'
                                or 'Unequipping selected pet before trade.'
                            preparing={kind=kind,id=id,token={done=false,dispatched=false}}
                            sent[key]=true
                            local preparedOk,request=pcall(callback,id,authorized)
                            if not preparedOk or type(request)~='table' then
                                -- Unknown dispatch outcome is never retried or treated as settled.
                                preparing.token={done=false,dispatched=true,error=tostring(request)}
                                error('Pet preparation outcome is unresolved: '..tostring(request))
                            end
                            preparing.token=request
                            if request.dispatched then token.dispatched=true end
                            local deadline=d.clock()+20
                            while true do
                                local native=preparing.token
                                if native.dispatched then token.dispatched=true end
                                if native.done==true and prepCleared(preparing) then preparing=nil;break end
                                if native.done==true and native.dispatched==false then
                                    preparing=nil;error(native.error or 'Pet preparation cancelled before dispatch.')
                                end
                                alive();assert(state()==nil,'Another trade started while preparing selected pets.')
                                assert(d.clock()<deadline,'Pet preparation confirmation timed out.')
                                d.wait(.2)
                            end
                            alive()
                        end
                    end
                    end
                end
                -- Every originally eligible pet still matching the protection rules
                -- must be out of the Pen and unequipped before any trade is opened.
                local expected=selection(allowed)
                local ready=selection(allowed,true)
                assert(#expected==#ready,'Selected pet assignments changed during preparation.')
                alive();assert(state()==nil,'Another trade started before prepared pets were ready.')
            end
            local function receipt()
                local remote=d.Router.get('TradeAPI/GetTradeHistory')
                assert(remote and remote:IsA('RemoteFunction'),'Trade history unavailable.')
                local history=remote:InvokeServer()
                assert(type(history)=='table','Trade history has not loaded.')
                for _,row in pairs(history) do
                    if type(row)=='table' and row.trade_id==ownedID then
                        local ownItems
                        if row.sender_user_id==d.player.UserId and row.recipient_user_id==partner.UserId then ownItems=row.sender_items
                        elseif row.recipient_user_id==d.player.UserId and row.sender_user_id==partner.UserId then ownItems=row.recipient_items end
                        assert(type(ownItems)=='table' and sameItems(ownItems,planned,false,true),'Trade receipt does not match selected items/recipient.')
                        return true
                    end
                end
                return false
            end
            local function confirmedRemoved()
                local pets=inventory()
                for _,id in ipairs(planned or {}) do if pets[id]~=nil then return false end end
                return true
            end
            local function finishTransfer()
                token.transferred=token.transferred+#planned;token.batches=token.batches+1
                -- A verified completed trade is not an unanswered invitation.
                -- Keep the established one-second inter-batch path for its partner,
                -- while outstanding invitations to other names retain their cooldown.
                lastRequestByName[partnerName]=nil
                lastRequestAt=nil
                committed,ownedID,planned,requested,added,offered=nil,nil,nil,nil,nil,nil
            end
            nativeTimerReady=function(current)
                if type(d.getTradeTiming)~='function' then return nil end
                local ok,clock=pcall(d.getTradeTiming)
                -- Once a native timing provider exists, missing/malformed/stale
                -- readings are not permission to substitute an elapsed timer.
                if not ok or type(clock)~='table' then return false end
                if clock.tradeId~=ownedID or clock.tradeId~=current.trade_id
                    or clock.stage~=current.current_stage or clock.offerVersion~=current.offer_version
                    or type(clock.going)~='boolean' or not finite(clock.remaining) or clock.remaining<0 then return false end
                return clock.going==false and clock.remaining==0
            end
            local function makeReview(current,partnerFingerprint,readyAt,early,nativeOnly)
                return {tradeId=current.trade_id,stage=current.current_stage,offerVersion=current.offer_version,
                    partnerFingerprint=partnerFingerprint,readyAt=readyAt,early=early==true,nativeOnly=nativeOnly==true}
            end
            handleWarning=function(review)
                if type(d.handleTradeWarning)~='function' then return true end
                local expected={tradeId=ownedID,recipientUserId=partner.UserId,recipientName=partner.Name,ownItemIDs={}}
                for i,id in ipairs(planned) do expected.ownItemIDs[i]=id end
                local function authorized()
                    local ok=pcall(function()
                        alive()
                        local current=state();local own=offer(current)
                        assert(current.trade_id==ownedID and current.current_stage=='confirmation'
                            and sameItems(own.items,planned,false) and sameReview(current,review),
                            'Warning does not belong to this trade review.')
                        stillSelected(planned);alive()
                        current=state();own=offer(current)
                        assert(sameItems(own.items,planned,false) and sameReview(current,review),
                            'Trade review changed during warning authorization.')
                    end)
                    return ok
                end
                assert(authorized(),'Trade changed before warning handling.')
                local status=d.handleTradeWarning(expected,authorized)
                assert(authorized(),'Trade changed during warning handling.')
                if status=='none' then return true end
                assert(status=='handled' or status=='blocked' or status=='pending','Unknown native trade dialog result.')
                token.detail=(status=='blocked') and 'Waiting for the current dialog to be handled manually.'
                    or 'Finishing the native trade warning.'
                return false
            end
            local ok,why=pcall(function()
                assert(settings.Enabled~=false,'Auto Trade is disabled.')
                assert(valid,tostring(configError))
                recipientNames=normalizeTradeRecipients(username)
                for _,name in ipairs(recipientNames) do
                    assert(name:lower()~=d.player.Name:lower(),'The sender cannot be a configured recipient.')
                    recipientSet[name:lower()]=true
                end
                job,character=d.game.JobId,d.player.Character
                assert(character,'Trade character is not ready.')
                alive()
                assert(state()==nil,'Another trade is already active.')
                assert(d.License.player_has_trade_license(d.player)==true,'Trading License belum tersedia untuk akun ini.')
                assert(d.Policy.is_trading_prohibited(d.player)==false,'Native policy does not permit trading.')
                partner=chooseOnline()
                while not partner do
                    assert(retryRequests,'Recipient must be in the same server.')
                    token.detail='Menunggu salah satu penerima di daftar masuk ke server. F8 untuk berhenti.'
                    d.wait(.2);alive()
                    assert(state()==nil,'Another trade appeared while waiting for a recipient.')
                    partner=chooseOnline()
                end
                token.recipient=partner.Name
                local capacity=d.Constants.max_trade_offer_slots
                assert(finite(capacity) and capacity>=1 and capacity%1==0,'Trade capacity is unknown.')
                capacity=math.min(18,capacity) -- User/native UI limit: never more than 18 slots per trade.
                local initial=selection()
                local allowed={};for _,id in ipairs(initial) do allowed[id]=true end
                prepareAssignments(initial,allowed)
                while true do
                    alive()
                    local ids=selection(allowed,true)
                    if #ids==0 then break end
                    if token.batches>0 then
                        -- Keep the inter-batch pause, but never delay a verified
                        -- final result. Re-read the selection after the pause.
                        d.wait(1);alive();ids=selection(allowed,true)
                        if #ids==0 then break end
                    end
                    planned={};for i=1,math.min(#ids,capacity) do planned[i]=ids[i] end
                    acceptAcknowledged,confirmAcknowledged=false,false
                    added,offered={},{};for _,id in ipairs(planned) do added[id]=false end
                    local t=waitForRequestedTrade()
                    ownedID=t.trade_id
                    local mine=offer(t)
                    assert(t.current_stage=='negotiation' and #mine.items==0 and not mine.negotiated,'Trade started with an unexpected offer.')
                    -- Native AddItemToOffer accepts one ID. Batch mode dispatches
                    -- the capped plan without per-item pacing/ack waits; every
                    -- individual dispatch still revalidates ownership/protections.
                    for i,id in ipairs(planned) do
                        token.detail='Adding trade item '..i..'/'..#planned..'.'
                        waitFor(function()
                            local now=state();local own,other=offer(now)
                            assert(now.current_stage=='negotiation' and not own.negotiated,
                                'Trade offer changed before adding the next item.')
                            if not batchAddItems then
                                assert(sameItems(own.items,offered,false),'Trade offer changed before adding the next item.')
                            end
                            local review=makeReview(now,fingerprint(other.items),0)
                            return send('AddItemToOffer',id,review)
                        end,15,'Adding trade item '..i)
                        if not batchAddItems then
                        local expected={};for j,previous in ipairs(offered) do expected[j]=previous end
                        expected[#expected+1]=id
                        token.detail='Waiting for trade item '..i..'/'..#planned..' to appear in the offer.'
                        waitFor(function()
                            local function acknowledged()
                                local now=state();local own=offer(now)
                                assert(now.current_stage=='negotiation' and not own.negotiated,
                                    'Trade changed while waiting for an added item.')
                                local previous=sameItems(own.items,offered,false)
                                local complete=sameItems(own.items,expected,false)
                                assert(previous or complete,'Trade offer lost an item or contains an unexpected item.')
                                return complete
                            end
                            acknowledged();stillSelected(planned)
                            return acknowledged()
                        end,15,'Waiting for trade item '..i,.1)
                        offered=expected
                        if i<#planned then
                            -- Native acknowledgement time counts toward pacing;
                            -- still allow at most one Add dispatch per .2 seconds.
                            local remaining=lastAddAt+.2-d.clock()
                            if remaining>0 then d.wait(remaining) end
                        end
                        end
                    end
                    token.detail='Waiting for all '..#planned..' trade items to appear in the offer.'
                    waitFor(function()
                        local now=state();local own=offer(now)
                        assert(now.current_stage=='negotiation' and not own.negotiated
                            and sameItems(own.items,planned,true),'Offer changed unexpectedly.')
                        stillSelected(planned)
                        return sameItems(own.items,planned,false)
                    end,15,'Filling complete trade offer')
                    local stableAt=d.clock()
                    local partnerFingerprint,reviewVersion
                    local negotiation=tonumber(d.Constants.negotiation_lock_time)
                    assert(finite(negotiation) and negotiation>=0,'Native negotiation timer unavailable.')
                    local fast=settings.FastConfirm==true
                    waitFor(function()
                        local now=state();local own,other=offer(now)
                        assert(now.current_stage=='negotiation' and sameItems(own.items,planned,false),'Trade offer changed before acceptance.')
                        local nextFingerprint=fingerprint(other.items)
                        if partnerFingerprint~=nextFingerprint or reviewVersion~=now.offer_version then
                            partnerFingerprint=nextFingerprint;reviewVersion=now.offer_version;stableAt=d.clock()
                        end
                        local review=makeReview(now,partnerFingerprint,stableAt+(fast and 1 or negotiation),fast)
                        stillSelected(planned)
                        if not reviewReady(now,review) then return false end
                        return send('AcceptNegotiation',nil,review)
                    end,90,'Trade review')
                    token.detail='Accepting offer; waiting for recipient.'
                    local acceptRetried,acceptSentAt=false,d.clock()
                    t=waitFor(function()
                        local now=state();local own,other=offer(now)
                        assert(sameItems(own.items,planned,false),'Trade offer changed after acceptance.')
                        if now.current_stage=='confirmation' then return now end
                        assert(now.current_stage=='negotiation','Unexpected trade stage.')
                        local nextFingerprint=fingerprint(other.items)
                        if partnerFingerprint~=nextFingerprint or reviewVersion~=now.offer_version then
                            partnerFingerprint=nextFingerprint;reviewVersion=now.offer_version;stableAt=d.clock()
                        end
                        if fast and not acceptRetried and not acceptAcknowledged and d.clock()-acceptSentAt>=.5 then
                            local review=makeReview(now,partnerFingerprint,stableAt+negotiation,false,true)
                            if reviewReady(now,review) then
                                stillSelected(planned)
                                if send('AcceptNegotiation',nil,review) then acceptRetried=true end
                            end
                        end
                    end,90,'Waiting for recipient acceptance')
                    local _,theirs=offer(t)
                    local seconds=tonumber(d.Constants.confirmation_lock_time_per_item)
                    assert(finite(seconds) and seconds>=0,'Native confirmation timer unavailable.')
                    seconds=math.max(5,math.min(15,seconds*(#planned+#theirs.items)))
                    stableAt=d.clock();partnerFingerprint=fingerprint(theirs.items);reviewVersion=t.offer_version
                    token.detail='Reviewing final trade confirmation.'
                    waitFor(function()
                        local now=state();local own,other=offer(now)
                        assert(now.current_stage=='confirmation' and sameItems(own.items,planned,false),'Final trade changed.')
                        assert(fingerprint(other.items)==partnerFingerprint,'Partner final offer changed.')
                        if reviewVersion~=now.offer_version then reviewVersion=now.offer_version;stableAt=d.clock() end
                        local review=makeReview(now,partnerFingerprint,stableAt+(fast and 1 or seconds),fast)
                        stillSelected(planned)
                        if not handleWarning(review) or not reviewReady(now,review) then return false end
                        -- send() rechecks this review after any yielding helper and
                        -- marks commitment only immediately before native dispatch.
                        return send('ConfirmTrade',nil,review)
                    end,90,'Trade confirmation')
                    local confirmRetried,confirmSentAt=false,d.clock()
                    token.detail='Waiting for trade receipt and inventory confirmation.'
                    waitFor(function()
                        local now=state()
                        if now then
                            local own,other=offer(now)
                            assert(now.current_stage=='confirmation' and sameItems(own.items,planned,false),'Final trade changed after confirmation.')
                            assert(fingerprint(other.items)==partnerFingerprint,'Partner final offer changed after confirmation.')
                            if reviewVersion~=now.offer_version then reviewVersion=now.offer_version;stableAt=d.clock() end
                            if fast and not confirmRetried and not confirmAcknowledged and d.clock()-confirmSentAt>=.5 then
                                local review=makeReview(now,partnerFingerprint,stableAt+seconds,false,true)
                                if reviewReady(now,review) and handleWarning(review) then
                                    stillSelected(planned)
                                    -- At most one fallback attempt, for this exact
                                    -- still-active review if no acknowledgement arrived.
                                    if send('ConfirmTrade',nil,review) then confirmRetried=true end
                                end
                            end
                            return false
                        end
                        return true
                    end,90,'Final trade settlement')
                    local receiptDeadline=d.clock()+30
                    repeat
                        if receipt() and confirmedRemoved() then break end
                        assert(d.clock()<receiptDeadline,'Trade receipt/inventory confirmation timed out.')
                        d.wait(2)
                    until false
                    for _,id in ipairs(planned) do allowed[id]=nil end
                    finishTransfer()
                end
                local remaining=selection()
                token.remainingIntended=remaining.intendedTotal
                token.blockedTotal=remaining.blockedTotal
                token.blockedReasons=remaining.blockedReasons
                token.allTargetsDone=remaining.intendedTotal==0
                token.ok=true
                token.detail=token.allTargetsDone and ('Trade selesai: '..token.transferred..' item.')
                    or ('Batch terkonfirmasi; '..remaining.intendedTotal..' target masih tersisa.')
                token.done=true
            end)
            if ok then return end
            token.error=tostring(why);token.detail=token.error
            -- A native prep call may still be yielding or replicating after STOP.
            -- Keep the whole workflow pending and observe only; never resend it.
            while preparing do
                token.uncertain=true
                token.detail='Pet preparation unresolved; no trade will be sent. '..token.error
                local settled,value=pcall(function()
                    local native=preparing.token
                    if native.done==true and native.dispatched==false then return true end
                    return native.done==true and prepCleared(preparing)
                end)
                if settled and value then preparing=nil;break end
                if not settled then token.preparationError=tostring(value) end
                d.wait(3)
            end
            if not ownedID then
                local readOK,current=pcall(state)
                local candidate=readOK and requestedPartner(current)
                if candidate then partner,partnerName,ownedID=candidate,candidate.Name:lower(),current.trade_id end
            end
            -- Before confirmation, cancel only this workflow's exact native trade.
            -- After confirmation, observe settlement without ever re-sending it.
            local cancelSent=false
            while ownedID do
                local settled,settleWhy=pcall(function()
                    if d.game.JobId~=job then return false end
                    local current=state()
                    if current and current.trade_id==ownedID then
                        if not committed and not cancelSent and ours(current) then
                            local remote=d.Router.get('TradeAPI/DeclineTrade')
                            local fresh=state()
                            if fresh and fresh.trade_id==ownedID and ours(fresh) then
                                cancelSent=true;remote:FireServer()
                            end
                        end
                        return false
                    end
                    if not committed then return true end
                    if receipt() and confirmedRemoved() then finishTransfer();return true end
                    -- Missing history or delayed inventory cannot prove a sent
                    -- confirmation was cancelled. Keep the unresolved gate.
                    return false
                end)
                if settled and settleWhy then break end
                token.uncertain=true
                token.detail='Trade outcome unresolved; not sending another trade. '..token.error
                if not settled then token.settlementError=tostring(settleWhy) end
                d.wait(3)
            end
            token.uncertain=nil;token.done=true;token.ok=false
        end)
        return token
    end
    return api
end

