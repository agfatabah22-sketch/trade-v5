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
