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
