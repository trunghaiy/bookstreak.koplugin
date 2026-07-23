local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")
local logger = require("logger")

local meta = require("_meta")

local Api = {}

function Api:new(settings)
    local o = {}
    setmetatable(o, { __index = self })
    o.settings = settings
    return o
end

function Api:post(payload, timeout)
    if not self.settings:isConfigured() then
        return nil, 0, "Not configured"
    end

    local server_url = self.settings:getServerUrl()
    local username = self.settings:getUsername()
    local password = self.settings:getPassword()

    local body = rapidjson.encode(payload)
    local response_chunks = {}

    socketutil:set_timeout(timeout or 30, timeout or 30)

    local code, headers, status = socket.skip(1, https.request{
        url = server_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["x-auth-user"] = username,
            ["x-auth-key"] = password,
            ["User-Agent"] = "bookstreak.koplugin/" .. (meta.version or "0.0.0"),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_chunks),
    })

    socketutil:reset_timeout()

    if code == 200 then
        local ok, result = pcall(rapidjson.decode, table.concat(response_chunks))
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
