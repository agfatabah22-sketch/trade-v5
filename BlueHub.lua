-- Blue Hub Trade Only: public engine; configuration stays in the caller.


local makeExternalConfig = (function()
-- Validate and snapshot a caller-owned BlueHubConfig before any runtime work.
-- This module has no Roblox, HTTP, filesystem, logging, or getgenv dependencies.
-- Errors contain fixed schema descriptions only; never interpolate input values.
return function(raw)
    local function fail(message) error(message, 0) end
    local function plain(value, message)
        if type(value) ~= "table" or getmetatable(value) ~= nil then fail(message) end
    end
    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end
    local function nonblank(value)
        return type(value) == "string" and value:find("%S") ~= nil
    end
    local function receiver(value)
        if type(value) ~= "string" then return false end
        local name = value:match("^%s*(.-)%s*$")
        return #name > 0 and #name <= 32 and name:match("^[A-Za-z0-9_]+$") ~= nil
    end
    local function list(value, validate, message)
        plain(value, message)
        local count, maximum = 0, 0
        for index, item in next, value do
            if not finite(index) or index < 1 or index % 1 ~= 0 or not validate(item) then
                fail(message)
            end
            count = count + 1
            maximum = math.max(maximum, index)
        end
        if count ~= maximum then fail(message) end
        local copied = {}
        for index = 1, count do copied[index] = rawget(value, index) end
        return copied
    end
    local allowed = {
        Username = true, Pets = true, Accessories = true, Keep = true, Excluded = true,
        AutoStart = true, IncludeEquipped = true, IncludePetPen = true, FastConfirm = true,
        BatchAddItems = true, AutoRetryTradeRequest = true, RecipientSwitchSeconds = true,
        TradeRequestRetrySeconds = true, WaitForRecipientSeconds = true, FarmersV5 = true,
    }
    plain(raw, "BlueHubConfig must be a plain table supplied before the loader.")
    for key in next, raw do
        if allowed[key] ~= true then fail("BlueHubConfig contains an unsupported field.") end
    end

    local config = {}
    local usernames = rawget(raw, "Username")
    local usernameError = "BlueHubConfig.Username must contain exact receiver usernames."
    if type(usernames) == "string" then
        if not receiver(usernames) then fail(usernameError) end
        config.Username = usernames
    else
        config.Username = list(usernames, receiver, usernameError)
        if #config.Username == 0 then fail(usernameError) end
    end
    for _, field in ipairs({"Pets", "Accessories", "Excluded"}) do
        local value = rawget(raw, field)
        config[field] = value == nil and {} or list(value, nonblank,
            "BlueHubConfig." .. field .. " must be a dense list of item names.")
    end
    if #config.Pets == 0 and #config.Accessories == 0 then
        fail("BlueHubConfig requires at least one Pets or Accessories selection.")
    end

    local keep = rawget(raw, "Keep")
    config.Keep = {}
    if keep ~= nil then
        local keepError = "BlueHubConfig.Keep must map item names to nonnegative whole counts."
        plain(keep, keepError)
        for name, count in next, keep do
            if not nonblank(name) or not finite(count) or count < 0 or count % 1 ~= 0 then
                fail(keepError)
            end
            config.Keep[name] = count
        end
    end
    for _, field in ipairs({"AutoStart", "IncludeEquipped", "IncludePetPen", "FastConfirm",
            "BatchAddItems", "AutoRetryTradeRequest"}) do
        local value = rawget(raw, field)
        if value == nil then value = true end
        if type(value) ~= "boolean" then
            fail("BlueHubConfig." .. field .. " must be true or false.")
        end
        config[field] = value
    end
    local function seconds(field, default, minimum, maximum)
        local value = rawget(raw, field)
        if value == nil then value = default end
        if not finite(value) or value < minimum or (maximum and value > maximum) then
            fail("BlueHubConfig." .. field .. " is outside its allowed seconds range.")
        end
        config[field] = value
    end
    seconds("RecipientSwitchSeconds", 3, 1, 300)
    seconds("TradeRequestRetrySeconds", 15, 10, 300)
    seconds("WaitForRecipientSeconds", 120, 0)

    config.FarmersV5 = {DisableAccount = false, APIKey = ""}
    local farmers = rawget(raw, "FarmersV5")
    if farmers ~= nil then
        plain(farmers, "BlueHubConfig.FarmersV5 must be a plain table.")
        for key in next, farmers do
            if key ~= "DisableAccount" and key ~= "APIKey" then
                fail("BlueHubConfig.FarmersV5 contains an unsupported field.")
            end
        end
        local disabled = rawget(farmers, "DisableAccount")
        local apiKey = rawget(farmers, "APIKey")
        if disabled == nil then disabled = false end
        if apiKey == nil then apiKey = "" end
        if type(disabled) ~= "boolean" then
            fail("BlueHubConfig.FarmersV5.DisableAccount must be true or false.")
        end
        if type(apiKey) ~= "string" or #apiKey > 2048 or apiKey:find("[^!-~]")
            or (disabled and #apiKey == 0) then
            fail("BlueHubConfig.FarmersV5.APIKey must be a valid key when disabling is enabled.")
        end
        config.FarmersV5.DisableAccount = disabled
        config.FarmersV5.APIKey = apiKey
    end
    return config
end
end)()


local externalEnvironment = type(getgenv) == "function" and getgenv() or _G
local externalOK, externalSnapshot = pcall(makeExternalConfig,
    type(externalEnvironment) == "table" and rawget(externalEnvironment, "BlueHubConfig") or nil)
if not externalOK then
    warn("[Blue Hub] Config eksternal tidak valid. Periksa getgenv().BlueHubConfig sebelum loader.")
    return
end
local Config = externalSnapshot


local makeNameResolver = (function()
-- Pure catalog-backed names. IDs remain authoritative; ambiguous names never pick an item.
-- factory(InventoryDB) -> resolver.Resolve(value, categories?, {egg?, suffix?})
-- Returns canonical ID (plus validated suffix), or nil and a diagnostic string.
return function(inventoryDB)
    local exact,ids,names,knownCategories={},{},{},{}
    local function trim(value) return (value:gsub('^%s+',''):gsub('%s+$','')) end
    local function normalize(value)
        return trim(value):lower():gsub('[_%-%s]+',' ')
    end
    local function add(index,key,record)
        if type(key)~='string' or key=='' then return end
        local list=index[key]
        if not list then list={};index[key]=list end
        list[#list+1]=record
    end
    for category,items in pairs(inventoryDB or {}) do
        if type(category)=='string' and type(items)=='table' then
            knownCategories[category]=true
            for key,item in pairs(items) do
                if type(key)=='string' and type(item)=='table' then
                    local id=type(item.id)=='string' and item.id
                        or type(item.kind)=='string' and item.kind or key
                    if id~='' then
                        local record={id=id,category=category,egg=item.is_egg==true}
                        local aliases={[key]=true,[id]=true}
                        if type(item.kind)=='string' then aliases[item.kind]=true end
                        for alias in pairs(aliases) do
                            add(exact,alias,record);add(ids,normalize(alias),record)
                        end
                        if type(item.name)=='string' and trim(item.name)~='' then
                            add(names,normalize(item.name),record)
                        end
                    end
                end
            end
        end
    end
    local function scope(categories)
        if categories==nil then return nil end
        if type(categories)=='string' then categories={categories} end
        if type(categories)~='table' then return nil,'Item categories must be a name or list' end
        local selected,count={},0
        for _,category in ipairs(categories) do
            if type(category)~='string' or not knownCategories[category] then
                return nil,'Unknown item category: '..tostring(category)
            end
            if not selected[category] then selected[category]=true;count=count+1 end
        end
        if count==0 then return nil,'No item categories selected' end
        return selected
    end
    local function choose(list,selected,options,value)
        if not list then return nil,nil,false end
        local matches={}
        for _,record in ipairs(list) do
            if (not selected or selected[record.category])
                and (options.egg~=true or record.egg) then matches[record.id]=true end
        end
        local candidates={};for id in pairs(matches) do candidates[#candidates+1]=id end
        table.sort(candidates)
        if #candidates==1 then return candidates[1],nil,true end
        if #candidates>1 then
            return nil,'Ambiguous item name "'..value..'"; use one ID: '..table.concat(candidates,', '),true
        end
        return nil,nil,false
    end
    local function base(value,selected,options)
        local id,err,matched=choose(exact[value],selected,options,value)
        if matched then return id,err,true end
        local normalized=normalize(value)
        -- A complete display name wins over a merely normalized ID. For
        -- example a new "Trike Stroller" must not silently become an older
        -- trike_stroller item. Exact IDs above remain backward compatible.
        id,err,matched=choose(names[normalized],selected,options,value)
        if matched then return id,err,true end
        return choose(ids[normalized],selected,options,value)
    end
    local function parseSuffix(value,at)
        -- Try the complete display name first, so a real catalog name containing
        -- a colon is never mistaken for a variant expression.
        at=at or value:find(':',1,true)
        if not at then return end
        local first=trim(value:sub(1,at-1))
        if first=='' then return nil,nil,'Missing item name before suffix' end
        local parts={}
        local rest=value:sub(at+1)
        for part in (rest..':'):gmatch('(.-):') do parts[#parts+1]=trim(part):lower() end
        local i,seenVersion,seenAge=1,false,false
        while i<=#parts do
            local part=parts[i]
            if part=='regular' or part=='neon' or part=='mega' then
                if seenVersion then return nil,nil,'Duplicate variant suffix' end
                seenVersion=true;i=i+1
            elseif part=='age' then
                if seenAge or not parts[i+1] or not parts[i+1]:match('^[1-6]$') then
                    return nil,nil,'Age suffix must appear once with a number from 1 to 6'
                end
                seenAge=true;i=i+2
            else return nil,nil,'Unknown item suffix: '..tostring(part) end
        end
        return first,':'..table.concat(parts,':')
    end
    local resolver={}
    function resolver.Resolve(value,categories,options)
        if type(value)~='string' then return nil,'Item name must be a string' end
        value=trim(value)
        if value=='' then return nil,'Item name cannot be empty' end
        options=options or {}
        local selected,scopeError=scope(categories)
        if scopeError then return nil,scopeError end
        local id,err,matched=base(value,selected,options)
        if matched then return id,err end
        if options.suffix and value:find(':',1,true) then
            local positions={}
            for at in value:gmatch('():') do positions[#positions+1]=at end
            -- Prefer the longest known name, including names with literal
            -- colons, then validate the complete remaining suffix grammar.
            for i=#positions,1,-1 do
                local at=positions[i]
                id,err,matched=base(trim(value:sub(1,at-1)),selected,options)
                if matched then
                    local _,suffix,suffixError=parseSuffix(value,at)
                    if suffixError then return nil,suffixError..' in "'..value..'"' end
                    return id and (id..suffix) or nil,err
                end
            end
        end
        return nil,'Unknown '..(options.egg and 'egg' or 'item')..' name "'..value..'"'
    end
    return resolver
end
end)()


local normalizeTradeRecipients = (function()
-- Copy and validate the user's exact receiver usernames; never accept display names.
return function(raw)
    local values
    if type(raw)=="string" then values={raw}
    elseif type(raw)=="table" then
        values=raw
        local count,maximum=0,0
        for index in pairs(values) do
            assert(type(index)=="number" and index==index and index>0 and index<math.huge
                and index%1==0,"Config.Username harus berupa daftar nama berurutan.")
            count=count+1;maximum=math.max(maximum,index)
        end
        assert(count>0 and count==maximum,"Isi minimal satu Username penerima; daftar tidak boleh berlubang.")
    else error("Config.Username harus berupa username atau daftar username penerima.") end
    local names,seen={},{}
    for _,value in ipairs(values) do
        assert(type(value)=="string","Setiap Username penerima harus berupa teks.")
        local name=value:match("^%s*(.-)%s*$")
        assert(name~="" and #name<=32 and name:match("^[A-Za-z0-9_]+$"),
            "Isi username Roblox yang tepat, bukan display name, pada Config.Username.")
        local key=name:lower()
        if not seen[key] then names[#names+1]=name;seen[key]=true end
    end
    assert(#names>0,"Isi minimal satu Username penerima.")
    return names
end
end)()


local makeTradePreparation = (function()
-- Exact native calls for one selected pet. This module never predicts inventory,
-- commits Pen progression, retries a request, or treats an ACK as replication.
return function(d)
    local api={}
    local function request(unique,authorize,unequip)
        local token={done=false,ok=false,dispatched=false}
        local function authorized()
            assert(type(authorize)=='function' and authorize()==true,'Pet preparation stopped or changed.')
        end
        local function freshPet()
            local inventory=d.CD.get('inventory')
            authorized()
            assert(type(inventory)=='table' and type(inventory.pets)=='table','Pet inventory is not ready.')
            local item=inventory.pets[unique]
            assert(type(item)=='table' and item.unique==unique,'Selected pet is no longer in inventory.')
            local clone={}
            for key,value in pairs(item) do clone[key]=value end
            clone.category='pets'
            return clone
        end
        local function work()
            local ok,result,detail=pcall(function()
                assert(type(unique)=='string' and unique:match('%S'),'A single pet unique ID is required.')
                authorized()
                freshPet()
                authorized()
                local path=unequip and 'ToolAPI/Unequip' or 'IdleProgressionAPI/RemovePet'
                local remote=d.Router.get(path)
                authorized()
                assert(remote and remote:IsA(unequip and 'RemoteFunction' or 'RemoteEvent'),
                    'Native pet preparation remote is unavailable: '..path)
                local item=freshPet()
                if unequip then
                    assert(d.EquipPermissions and type(d.EquipPermissions.can_unequip_client)=='function',
                        'Native unequip permissions are not ready.')
                    local permitted,why=d.EquipPermissions.can_unequip_client(item)
                    authorized()
                    assert(permitted==true,type(why)=='table' and why.message or 'Native pet unequip is not permitted.')
                    -- Permissions can yield. Confirm the selected ID still exists.
                    freshPet()
                end
                authorized()
                token.dispatched=true
                if unequip then return remote:InvokeServer(unique,{}) end
                remote:FireServer(unique)
                return true
            end)
            token.ok=ok and result==true
            if not token.ok then
                token.error=not ok and tostring(result)
                    or (type(detail)=='table' and type(detail.message)=='string' and detail.message)
                    or 'Native pet preparation did not confirm success.'
            end
            token.done=true
        end
        local spawned,why=pcall(d.spawn,work)
        if not spawned then token.error=tostring(why);token.ok=false;token.done=true end
        return token
    end
    function api.unequipTradePet(unique,authorize)return request(unique,authorize,true)end
    function api.removeTradePetFromPen(unique,authorize)return request(unique,authorize,false)end
    return api
end
end)()


local makeTradeAdapter = (function()
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
end)()


local makeNativeUI = (function()
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
end)()


local makeStartupPopups = (function()
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
end)()


local makeStartupMenu = (function()
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
        {action='spawn_no',text='Kamu sering memilih opsi ini! Mau ke sana terus?',
            labels={'No','Yes'},response='No'},
        {action='spawn_okay',text='Anda dapat mengubah pilihan ini kapan saja di pengaturan Anda.',
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
end)()


local makeStartupGate = (function()
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
end)()


local makeStartup = (function()
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
end)()


local makeTradeWarnings = (function()
-- Exact native trade-warning messages only. DialogApp translates its message
-- with Translator:Translate(workspace, text), but assigns the original button
-- strings to Face.TextLabel.Text. Their visual auto-localization does not change
-- the button strings used here or the native DialogApp continuation callback.
return function(d)
    local sources={
        {action='trade_warning_next',text='This trade seems unbalanced. Be careful - you could be getting scammed.',response='Next'},
        {action='trade_warning_understand',text='Any items lost to scams WILL NOT be returned. Be sure before you accept!',response='I understand'},
        {action='trade_warning_next',text='This trade seems unbalanced. Remember, scamming and real world trading are BANNABLE!',response='Next'},
    }
    local function rule(source,message)
        return {action=source.action,text=message,labels={source.response},response=source.response}
    end
    local function english()
        local result={}
        for _,source in ipairs(sources)do result[#result+1]=rule(source,source.text)end
        return result
    end
    local function allowed(authorize)
        if type(authorize)~='function' then return false end
        local ok,value=pcall(authorize)
        return ok and value==true
    end
    local function validText(value)
        return type(value)=='string' and #value>0 and #value<=4096 and not value:find('%z')
    end
    local function validTradeKey(value)
        return type(value)=='string' and value~='' or type(value)=='number'
            and value==value and value~=math.huge and value~=-math.huge and value%1==0
    end
    local function combined(messages)
        local result,byText,ambiguous={},{},{}
        local function add(source,message)
            local prior=byText[message]
            if prior and (prior.action~=source.action or prior.response~=source.response)then
                ambiguous[message]=true
            elseif not prior then
                local nextRule=rule(source,message)
                byText[message]=nextRule;result[#result+1]=nextRule
            end
        end
        for _,source in ipairs(sources)do add(source,source.text)end
        for index,source in ipairs(sources)do add(source,messages[index])end
        local safe={}
        for _,entry in ipairs(result)do
            if not ambiguous[entry.text]then safe[#safe+1]=entry end
        end
        return safe
    end
    local clock=type(d.clock)=='function' and d.clock or os.clock
    local maxAttempts,retrySeconds=3,1
    local currentKey,attempts,nextAttempt,busy,ready=nil,0,0,false,false
    local currentRules=english()
    local api={}
    function api.GetRules(authorize,tradeKey,refresh)
        if not allowed(authorize)then return nil,'cancelled',false end
        if not validTradeKey(tradeKey)then return nil,'invalid_trade',false end
        if currentKey~=tradeKey then
            if busy then return nil,'pending',true end
            currentKey,attempts,nextAttempt,ready=tradeKey,0,0,false
            currentRules=english()
        end
        if busy then return nil,'pending',true end
        if ready and refresh~=true then return currentRules,'ready',attempts<maxAttempts end
        if attempts>=maxAttempts then return currentRules,ready and 'ready' or 'unavailable',false end
        if clock()<nextAttempt then return currentRules,ready and 'ready' or 'pending',true end
        busy=true;attempts=attempts+1;nextAttempt=clock()+retrySeconds
        local activeKey=currentKey
        local ok,messages=pcall(function()
            assert(type(d.getTranslator)=='function','Native translator unavailable')
            local translator=d.getTranslator()
            assert(allowed(authorize) and currentKey==activeKey,'Trade changed during translator lookup')
            assert(translator and type(translator.Translate)=='function','Native translator unavailable')
            local result={}
            for index,source in ipairs(sources)do
                assert(allowed(authorize) and currentKey==activeKey,'Trade changed before translation')
                local translated=translator:Translate(d.context,source.text)
                assert(allowed(authorize) and currentKey==activeKey,'Trade changed during translation')
                assert(validText(translated),'Native translation unavailable')
                result[index]=translated
            end
            return result
        end)
        busy=false
        if not allowed(authorize) or currentKey~=activeKey then return nil,'cancelled',false end
        if ok then
            currentRules,ready=combined(messages),true
            return currentRules,'ready',attempts<maxAttempts
        end
        -- Never publish a partially translated warning set. English remains
        -- exact-match only while a bounded later attempt waits for native locale.
        return currentRules,ready and 'ready' or (attempts<maxAttempts and 'pending' or 'unavailable'),attempts<maxAttempts
    end
    return api
end
end)()


local makeBindings = (function()
-- Connect the trade-only adapter to the same native trade APIs as Utility Blue Hub.
return function(context, env, config, factories)
    local player, modules = context.player, context.modules
    local Players, RS = game:GetService("Players"), game:GetService("ReplicatedStorage")
    local CD, DB, UIManager = modules.ClientData, modules.InventoryDB, modules.UIManager
    local resolver = factories.makeNameResolver(DB)
    local preparation = factories.makeTradePreparation({CD=CD, Router=modules.RouterClient,
        spawn=task.spawn, EquipPermissions=modules.EquipPermissions})
    local function conflict()
        local old=env.UtilityBlueHub
        local state=type(old)=="table" and old.Engine and old.Engine.State
        if type(state)=="table" and (state.enabled or state.pending) then
            return "Utility Blue Hub lama masih berjalan. Hentikan prosesnya sebelum trade-only."
        end
        local aax=env.AAXKaitun
        if type(aax)=="table" and aax.Running then
            if aax.Stopping or aax.EventReservation or aax.ActiveThread or aax.EventCleanupThread then
                return "Menunggu pekerjaan script lain selesai."
            end
            if aax.Config and aax.Config.AutoRecycle and aax.Config.AutoRecycle.Enabled then
                return "Proses inventory script lain masih aktif."
            end
        end
    end
    local warnings=factories.makeTradeWarnings({context=workspace,clock=os.clock,
        getTranslator=function()
            return game:GetService("LocalizationService"):GetTranslatorForPlayer(player)
        end})
    local adapter=factories.makeTradeAdapter({CD=CD,DB=DB,Locks=modules.BackpackLockTracker,
        ItemHider=modules.ItemHider,License=modules.TradeLicenseHelper,Policy=modules.PolicyHelper,
        Constants=modules.SharedConstants,Router=modules.RouterClient,RS=RS,player=player,
        Players=Players,game=game,spawn=task.spawn,wait=task.wait,clock=os.clock,
        resolver=resolver,conflict=conflict,
        unequipTradePet=preparation.unequipTradePet,removeTradePetFromPen=preparation.removeTradePetFromPen,
        isAccessoryEquipped=function(item)
            assert(type(item)=="table" and type(item.unique)=="string","Accessory identity is unavailable.")
            local worn,equipment=CD.get("pet_saved_worn_items"),CD.get("equip_manager")
            assert(type(worn)=="table" and type(equipment)=="table","Accessory assignment data is not ready.")
            local lists,held=worn.wearing_lists or {},equipment.pet_accessories or {}
            assert(type(lists)=="table" and type(held)=="table","Invalid accessory assignment data.")
            local assigned=false
            for _,groups in pairs(lists) do
                assert(type(groups)=="table","Invalid pet accessory groups.")
                for _,group in pairs(groups) do
                    assert(type(group)=="table","Invalid pet accessory list.")
                    for _,unique in pairs(group) do
                        assert(type(unique)=="string" and unique~="","Invalid worn accessory identity.")
                        if unique==item.unique then assigned=true end
                    end
                end
            end
            for _,equipped in pairs(held) do
                assert(type(equipped)=="table" and type(equipped.unique)=="string" and equipped.unique~="",
                    "Invalid held accessory identity.")
                if equipped.unique==item.unique then assigned=true end
            end
            return assigned
        end,
        handleTradeWarning=function(expected,authorize)
            if not expected or type(authorize)~="function" or not authorize() then return "blocked" end
            local function matches()
                if not authorize() then return false end
                local ui=UIManager.apps and UIManager.apps.TradeApp
                if not ui or type(ui._get_local_trade_state)~="function" then return false end
                local current=ui:_get_local_trade_state()
                return type(current)=="table" and current.trade_id==expected.tradeId
                    and current.current_stage=="confirmation" and authorize()
            end
            if not matches() then return "blocked" end
            local rules,translationState,canRetry=warnings.GetRules(matches,expected.tradeId)
            if not matches() then return "blocked","trade_changed_during_translation" end
            if not rules then return translationState=="pending" and "pending" or "blocked","trade_warning_translation_unavailable" end
            local status,reason=context.nativeUI.HandleNormal(rules,matches)
            if not matches() then return "blocked","trade_changed_during_warning" end
            if status=="blocked" and reason=="unknown_dialog_text" and canRetry then
                local refreshed,nextState,retryAvailable=warnings.GetRules(matches,expected.tradeId,true)
                if not matches() then return "blocked","trade_changed_during_translation" end
                if refreshed and refreshed~=rules then
                    status,reason=context.nativeUI.HandleNormal(refreshed,matches)
                    if not matches() then return "blocked","trade_changed_during_warning" end
                end
                if status=="blocked" and reason=="unknown_dialog_text" and (retryAvailable or nextState=="pending")then
                    return "pending","trade_warning_translation_pending"
                end
            end
            if status~="none" then return status,reason end
            if not matches() then return "blocked" end
            local dialog=UIManager.apps and UIManager.apps.DialogApp
            local total,completed=dialog and dialog.ticket_count,dialog and dialog.completed_ticket
            local function counter(value)
                return type(value)=="number" and value==value and value<math.huge and value>=0 and value%1==0
            end
            if not counter(total) or not counter(completed) or completed>total then return "pending" end
            return total==completed and "none" or "pending"
        end,
        getTradeTiming=function()
            local ui=UIManager.apps and UIManager.apps.TradeApp
            if not ui or type(ui._get_local_trade_state)~="function" or not ui.lock_countdown then return end
            local current=ui:_get_local_trade_state()
            if type(current)~="table" then return end
            return {tradeId=current.trade_id,stage=current.current_stage,offerVersion=current.offer_version,
                going=ui.lock_countdown:is_going(),remaining=math.max(0,ui.lock_countdown:get_remaining_time())}
        end},config)
    return adapter,conflict
end
end)()


local makeAccountOpsDisable = (function()
-- One-shot AccountOps disable request. No Roblox globals, kicks, retries or logs.
-- The host supplies the current sender name, the protected recipient name, and
-- an HTTP transport with a bounded timeout and redirects disabled. API-key
-- permission is determined by the service; a locally valid key is not verified.
return function(d, config)
    d = type(d) == "table" and d or {}
    config = type(config) == "table" and config or {}
    local enabled, apiKey = rawget(config, "DisableAccount"), rawget(config, "APIKey")
    local URL = "https://accountops.org/api/accounts/enable"
    local attempt
    local function result(status, reason, dispatched, ambiguous, httpStatus)
        return {
            ok = status == "ready" or status == "skipped" or status == "confirmed",
            enabled = enabled == true, status = status, reason = reason,
            confirmed = status == "confirmed", dispatched = dispatched == true,
            ambiguous = ambiguous == true, httpStatus = httpStatus,
        }
    end
    local function copy(value)
        local out = {}
        for key, item in pairs(value) do out[key] = item end
        return out
    end
    local function username(value)
        return type(value) == "string" and #value >= 1 and #value <= 32
            and value:match("^[A-Za-z0-9_]+$") ~= nil
    end
    local function validate(sender, recipient)
        if enabled == nil or enabled == false then
            return result("skipped", "ACCOUNTOPS_DISABLED", false, false)
        end
        if enabled ~= true then return result("review", "ACCOUNTOPS_CONFIG_INVALID", false, false) end
        if not username(sender) then return result("review", "ACCOUNTOPS_SENDER_INVALID", false, false) end
        if not username(recipient) then return result("review", "ACCOUNTOPS_RECIPIENT_INVALID", false, false) end
        if sender:lower() == recipient:lower() then
            return result("review", "ACCOUNTOPS_RECEIVER_PROTECTED", false, false)
        end
        -- Header values cannot contain CR/LF, NUL, spaces or other controls.
        if type(apiKey) ~= "string" or #apiKey == 0 or #apiKey > 2048
            or apiKey:find("[^!-~]") then
            return result("review", "ACCOUNTOPS_API_KEY_INVALID", false, false)
        end
        if type(d.request) ~= "function" or type(d.jsonEncode) ~= "function"
            or type(d.jsonDecode) ~= "function" then
            return result("review", "ACCOUNTOPS_TRANSPORT_UNAVAILABLE", false, false)
        end
        return result("ready", "ACCOUNTOPS_READY", false, false)
    end
    local api = {}
    function api.Validate(sender, recipient)
        return validate(sender, recipient)
    end
    function api.Disable(sender, recipient)
        local valid = validate(sender, recipient)
        if valid.status ~= "ready" then return valid end
        if attempt then
            if attempt.sender ~= sender:lower() or attempt.recipient ~= recipient:lower() then
                return result("review", "ACCOUNTOPS_ATTEMPT_IDENTITY_CHANGED", true, true)
            end
            return copy(attempt.outcome or result("review", "ACCOUNTOPS_REQUEST_PENDING", true, true))
        end
        local encoded, body = pcall(d.jsonEncode, {usernames = {sender}, enabled = false})
        if not encoded or type(body) ~= "string" or body == "" then
            return result("review", "ACCOUNTOPS_REQUEST_ENCODING_FAILED", false, false)
        end
        -- A yielding encoder must not permit a second concurrent request.
        if attempt then
            if attempt.sender ~= sender:lower() or attempt.recipient ~= recipient:lower() then
                return result("review", "ACCOUNTOPS_ATTEMPT_IDENTITY_CHANGED", true, true)
            end
            return copy(attempt.outcome or result("review", "ACCOUNTOPS_REQUEST_PENDING", true, true))
        end
        attempt = {sender = sender:lower(), recipient = recipient:lower()}
        local function finish(value)
            attempt.outcome = copy(value)
            return copy(value)
        end
        -- Record the attempt before a possibly yielding/throwing transport.
        -- A throw/timeout may happen after the server already applied it.
        local called, response = pcall(d.request, {
            Url = URL, Method = "PUT", Timeout = 15,
            Redirect = false, FollowRedirects = false,
            Headers = {["Content-Type"] = "application/json", ["X-Api-Key"] = apiKey},
            Body = body,
        })
        if not called then return finish(result("review", "ACCOUNTOPS_REQUEST_UNCONFIRMED", true, true)) end
        if type(response) ~= "table" then
            return finish(result("review", "ACCOUNTOPS_RESPONSE_INVALID", true, true))
        end
        local status = rawget(response, "StatusCode")
        if type(status) ~= "number" or status ~= status or status % 1 ~= 0 or status < 100 or status > 599 then
            return finish(result("review", "ACCOUNTOPS_RESPONSE_INVALID", true, true))
        end
        if status == 401 or status == 403 then
            return finish(result("review", "ACCOUNTOPS_AUTH_DENIED", true, false, status))
        end
        if status == 429 then
            return finish(result("review", "ACCOUNTOPS_RATE_LIMITED", true, false, status))
        end
        if status >= 300 and status < 400 then
            return finish(result("review", "ACCOUNTOPS_REDIRECT_REJECTED", true, true, status))
        end
        if status < 200 or status >= 300 then
            return finish(result("review", "ACCOUNTOPS_HTTP_ERROR", true, status >= 500, status))
        end
        if rawget(response, "Success") == false then
            return finish(result("review", "ACCOUNTOPS_RESPONSE_INVALID", true, true, status))
        end
        local responseURL = rawget(response, "Url") or rawget(response, "URL")
        if responseURL ~= nil and responseURL ~= URL then
            return finish(result("review", "ACCOUNTOPS_REDIRECT_REJECTED", true, true, status))
        end
        local raw = rawget(response, "Body")
        if type(raw) ~= "string" or #raw == 0 or #raw > 1024 then
            return finish(result("review", "ACCOUNTOPS_RESPONSE_INVALID", true, true, status))
        end
        local decoded, count = pcall(d.jsonDecode, raw)
        if not decoded or type(count) ~= "number" or count ~= 1 then
            return finish(result("review", "ACCOUNTOPS_DISABLE_UNCONFIRMED", true, true, status))
        end
        return finish(result("confirmed", "ACCOUNTOPS_DISABLED_CONFIRMED", true, false, status))
    end
    return api
end
end)()


local makeController = (function()
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
end)()


local makeOverlay = (function()
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
end)()


local makeDiagnostics = (function()
-- Passive bounded recorder. Only injected reads are called; no gameplay actions.
return function(d)
    d = type(d) == "table" and d or {}
    local records, sequence, previous, lastTime = {}, 0, nil, 0
    local capacity = type(d.capacity) == "number" and d.capacity == d.capacity
        and d.capacity > 0 and d.capacity < math.huge and math.floor(d.capacity) or 60
    capacity = math.max(1, math.min(60, capacity))
    local fields = {
        "app_phase", "app_detail", "trade_present", "trade_owned", "trade_id", "trade_stage", "offer_version",
        "own_count", "partner_count", "own_negotiated", "partner_negotiated", "own_confirmed", "partner_confirmed",
        "countdown_trade_id", "countdown_stage", "countdown_offer_version", "countdown_going", "countdown_remaining",
        "dialog_visible", "dialog_text", "dialog_buttons", "dialog_source",
        "trade_read_error", "countdown_read_error", "dialog_read_error", "clock_error", "diagnostic_error",
    }
    local function finite(value)
        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    end
    local function text(value, limit)
        if type(value) ~= "string" then return nil end
        local clipped = value:sub(1, limit):gsub("[%z\1-\31\127]", " ")
        -- Truncation never returns a partial UTF-8 character to JSON consumers.
        if type(utf8) == "table" and type(utf8.len) == "function" then
            while #clipped > 0 do
                local ok, count = pcall(utf8.len, clipped)
                if ok and count then break end
                clipped = clipped:sub(1, #clipped - 1)
            end
        end
        return clipped
    end
    local function identifier(value)
        if type(value) == "string" then return text(value, 96) end
        if finite(value) and value >= 0 and value % 1 == 0 and value < 9007199254740992 then return value end
    end
    local function boolean(value) if type(value) == "boolean" then return value end end
    local function count(value)
        if finite(value) and value >= 0 and value % 1 == 0 and value <= 100000 then return value end
    end
    local function sanitize(raw)
        if type(raw) ~= "table" then return {diagnostic_error = "snapshot_unavailable"} end
        local out = {
            app_phase = text(rawget(raw, "app_phase"), 48), app_detail = text(rawget(raw, "app_detail"), 250),
            trade_present = boolean(rawget(raw, "trade_present")), trade_owned = boolean(rawget(raw, "trade_owned")),
            trade_id = identifier(rawget(raw, "trade_id")), trade_stage = text(rawget(raw, "trade_stage"), 48),
            offer_version = identifier(rawget(raw, "offer_version")),
            own_count = count(rawget(raw, "own_count")), partner_count = count(rawget(raw, "partner_count")),
            own_negotiated = boolean(rawget(raw, "own_negotiated")), partner_negotiated = boolean(rawget(raw, "partner_negotiated")),
            own_confirmed = boolean(rawget(raw, "own_confirmed")), partner_confirmed = boolean(rawget(raw, "partner_confirmed")),
            dialog_visible = boolean(rawget(raw, "dialog_visible")),
            trade_read_error = boolean(rawget(raw, "trade_read_error")),
            countdown_read_error = boolean(rawget(raw, "countdown_read_error")),
            dialog_read_error = boolean(rawget(raw, "dialog_read_error")),
        }
        if out.dialog_visible == true then
            out.dialog_text = text(rawget(raw, "dialog_text"), 400)
            out.dialog_buttons = text(rawget(raw, "dialog_buttons"), 250)
            out.dialog_source = text(rawget(raw, "dialog_source"), 120)
        end
        local countdownId = identifier(rawget(raw, "countdown_trade_id"))
        local countdownStage = text(rawget(raw, "countdown_stage"), 48)
        local countdownVersion = identifier(rawget(raw, "countdown_offer_version"))
        if out.trade_id ~= nil and countdownId == out.trade_id and countdownStage == out.trade_stage
            and out.offer_version ~= nil and countdownVersion == out.offer_version then
            out.countdown_trade_id, out.countdown_stage, out.countdown_offer_version = countdownId, countdownStage, countdownVersion
            out.countdown_going = boolean(rawget(raw, "countdown_going"))
            local remaining = rawget(raw, "countdown_remaining")
            -- Whole seconds keep frequent polling from evicting useful transitions.
            if finite(remaining) and remaining >= 0 and remaining <= 86400 then out.countdown_remaining = math.ceil(remaining) end
        end
        return out
    end
    local function fingerprint(record)
        local parts = {}
        for _, name in ipairs(fields) do
            local value = record[name]
            if value == nil then parts[#parts + 1] = "nil;"
            else
                local encoded = tostring(value)
                parts[#parts + 1] = type(value) .. ":" .. #encoded .. ":" .. encoded .. ";"
            end
        end
        return table.concat(parts)
    end
    local function append(record)
        local signature = fingerprint(record)
        if signature == previous then return false, "unchanged" end
        previous, sequence = signature, sequence + 1
        record.sequence, record.at = sequence, lastTime
        records[#records + 1] = record
        if #records > capacity then table.remove(records, 1) end
        return true, "recorded"
    end
    local api = {}
    function api.Sample()
        local ok, added, why = pcall(function()
            local clockOK, now = pcall(type(d.clock) == "function" and d.clock or os.clock)
            local clockError = not clockOK or not finite(now) or now < 0
            if not clockError then lastTime = math.max(lastTime, now) end
            local record
            if type(d.readSnapshot) ~= "function" then
                record = {diagnostic_error = "snapshot_reader_unavailable"}
            else
                local readOK, raw = pcall(d.readSnapshot)
                record = readOK and sanitize(raw) or {diagnostic_error = "snapshot_read_failed"}
            end
            if clockError then record.clock_error = true end
            return append(record)
        end)
        if ok then return added, why end
        -- Do not preserve exception strings: they may contain unrelated data.
        local saved, result = pcall(append, {diagnostic_error = "sample_failed"})
        return saved and result or false, "sample_failed"
    end
    function api.Read()
        local out = {}
        for index, record in ipairs(records) do
            local copy = {}
            for key, value in pairs(record) do copy[key] = value end
            out[index] = copy
        end
        return out
    end
    return api
end
end)()


local makeDiagnosticSnapshot = (function()
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
end)()

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
