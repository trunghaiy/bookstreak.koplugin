local DataStorage = require("datastorage")
local json = require("json")
local logger = require("logger")

local Queue = {}

function Queue:new(api)
    local o = {}
    setmetatable(o, { __index = self })
    o.api = api
    o.queue_path = DataStorage:getSettingsDir() .. "/bookstreak_queue.json"
    return o
end

function Queue:_load()
    local file = io.open(self.queue_path, "r")
    if not file then return {} end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

function Queue:_save(items)
    local file = io.open(self.queue_path, "w")
    if not file then
        logger.warn("BookStreak: Failed to write queue file")
        return
    end
    file:write(json.encode(items))
    file:close()
end

function Queue:enqueue(payload)
    local items = self:_load()
    table.insert(items, payload)
    self:_save(items)
    logger.info("BookStreak: Queued payload, queue size:", #items)
end

function Queue:flush()
    local items = self:_load()
    if #items == 0 then return 0 end

    local remaining = {}
    local sent = 0

    for _, payload in ipairs(items) do
        local result = self.api:post(payload)
        if result then
            sent = sent + 1
        else
            table.insert(remaining, payload)
        end
    end

    self:_save(remaining)
    if sent > 0 then
        logger.info("BookStreak: Flushed", sent, "queued payloads,", #remaining, "remaining")
    end
    return sent
end

function Queue:size()
    local items = self:_load()
    return #items
end

function Queue:clear()
    self:_save({})
end

return Queue
