--[[--
Base translation engine handler.

Provides HTTP request helpers using subprocess for non-blocking API calls
(pattern from koassistant). All engine implementations inherit from this.

@module translator_engines.base
]]

local json = require("json")
local logger = require("logger")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

local BaseEngine = {}
BaseEngine.__index = BaseEngine

function BaseEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Get display name (override in subclass).
function BaseEngine:getName()
    error("getName() must be overridden")
end

--- Get engine key (override in subclass).
function BaseEngine:getKey()
    error("getKey() must be overridden")
end

--- Translate an array of paragraphs (override in subclass).
-- @param paragraphs table Array of strings
-- @param source_lang string Source language code
-- @param target_lang string Target language code
-- @param api_key string API key
-- @param callback function(success, translations_or_error) Called with results
function BaseEngine:translate(paragraphs, source_lang, target_lang, api_key, callback)
    error("translate() must be overridden")
end

--- Make an HTTP POST request in a subprocess (non-blocking).
-- @param url string Request URL
-- @param headers table Request headers
-- @param body string Request body (JSON-encoded)
-- @param callback function(success, response_body_string, error_msg)
function BaseEngine:httpPost(url, headers, body, callback)
    local UIManager = require("ui/uimanager")
    local chunksize = 1024 * 64
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local response_data = {}
    local completed = false

    local bg_fn = function(pid, child_write_fd)
        if not pid or not child_write_fd then return end

        local subprocess_ok, subprocess_err = pcall(function()
            local subprocess_http = require("socket.http")
            local subprocess_https = require("ssl.https")
            local ltn12 = require("ltn12")

            local resp_body = {}
            local request = {
                url = url,
                method = "POST",
                headers = headers,
                source = ltn12.source.string(body),
                sink = ltn12.sink.table(resp_body),
            }

            local request_func
            if url:sub(1, 8) == "https://" then
                subprocess_https.TIMEOUT = 120
                request_func = subprocess_https.request
            else
                request_func = subprocess_http.request
            end

            local ok, code = pcall(function()
                local socket = require("socket")
                return socket.skip(1, request_func(request))
            end)

            if not ok then
                ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(code))
            elseif code ~= 200 then
                local resp_text = table.concat(resp_body)
                ffiutil.writeToFD(child_write_fd,
                    string.format("HTTP_ERROR:%d:%s", code, resp_text:sub(1, 500)))
            else
                ffiutil.writeToFD(child_write_fd, table.concat(resp_body))
            end
        end)

        if not subprocess_ok then
            ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(subprocess_err))
        end
        ffi.C.close(child_write_fd)
    end

    -- Warmup TCP on macOS (from koassistant pattern)
    if ffi.os == "OSX" and url:sub(1, 8) == "https://" then
        local socket = require("socket")
        local host = url:match("https://([^/:]+)")
        if host then
            pcall(function()
                local sock = socket.tcp()
                sock:settimeout(0.5)
                sock:connect(host, 443)
                sock:close()
            end)
        end
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(bg_fn, true)
    if not pid then
        callback(false, nil, "Failed to start subprocess")
        return
    end

    -- Poll for completion
    local poll_task
    local function pollForData()
        if completed then return end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read and bytes_read > 0 then
                table.insert(response_data, ffi.string(buffer, bytes_read))
            end
        end

        if ffiutil.isSubProcessDone(pid) then
            -- Read remaining
            local remaining = ffiutil.getNonBlockingReadSize(parent_read_fd)
            while remaining and remaining > 0 do
                local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
                if bytes_read and bytes_read > 0 then
                    table.insert(response_data, ffi.string(buffer, bytes_read))
                else
                    break
                end
                remaining = ffiutil.getNonBlockingReadSize(parent_read_fd)
            end

            completed = true
            local full_response = table.concat(response_data)

            if full_response:sub(1, 6) == "ERROR:" then
                callback(false, nil, full_response:sub(7))
            elseif full_response:sub(1, 10) == "HTTP_ERROR" then
                local code, msg = full_response:match("HTTP_ERROR:(%d+):(.*)")
                callback(false, nil, string.format("HTTP %s: %s", code or "?", msg or "Unknown"))
            else
                callback(true, full_response, nil)
            end
            return
        end

        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    poll_task = UIManager:scheduleIn(0.1, pollForData)
end

--- Helper to make a JSON POST and parse the response.
-- @param url string
-- @param headers table
-- @param body_table table Will be JSON-encoded
-- @param callback function(success, parsed_response_or_error)
function BaseEngine:jsonPost(url, headers, body_table, callback)
    local body = json.encode(body_table)
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body)

    self:httpPost(url, headers, body, function(ok, response, err)
        if not ok then
            callback(false, err)
            return
        end
        local parse_ok, parsed = pcall(json.decode, response)
        if not parse_ok then
            callback(false, "Invalid JSON response: " .. (response or ""):sub(1, 200))
            return
        end
        callback(true, parsed)
    end)
end

return BaseEngine
