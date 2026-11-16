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
