local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local VERSION = "0.1.0"

local Api = {}

function Api:new(settings)
    local o = {}
    setmetatable(o, { __index = self })
    o.settings = settings
    return o
end

function Api:post(payload)
    if not self.settings:isConfigured() then
        return nil, 0, "Not configured"
    end

    local server_url = self.settings:getServerUrl()
    local username = self.settings:getUsername()
    local password = self.settings:getPassword()

    local body = json.encode(payload)
    local response_chunks = {}

    socketutil:set_timeout(10, 30)

    local code, headers, status = https.request{
        url = server_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["x-auth-user"] = username,
            ["x-auth-key"] = password,
            ["User-Agent"] = "bookstreak.koplugin/" .. VERSION,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_chunks),
    }

    socketutil:reset_timeout()

    if code == 200 then
        local ok, result = pcall(json.decode, table.concat(response_chunks))
        if ok then
            return result
        else
            logger.warn("BookStreak: Failed to parse response JSON")
            return nil, code, "Invalid JSON response"
        end
    else
        local err_body = table.concat(response_chunks)
        logger.warn("BookStreak: Sync failed with code", code, err_body)
        return nil, code or 0, err_body
    end
end

return Api
