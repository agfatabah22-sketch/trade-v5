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
