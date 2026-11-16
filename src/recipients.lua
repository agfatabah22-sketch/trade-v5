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
