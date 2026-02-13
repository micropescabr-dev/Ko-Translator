--[[--
DeepL translation engine.

Uses the DeepL REST API v2. Supports both Free and Pro endpoints.
Splits large paragraph lists into batches to avoid API limits.

@module translator_engines.deepl
]]

local BaseEngine = require("translator_engines/base")
local logger = require("logger")

local DeepLEngine = BaseEngine:new()

function DeepLEngine:getName() return "DeepL" end
function DeepLEngine:getKey() return "deepl" end

--- Detect which endpoint to use based on key suffix.
-- DeepL Free keys end with ":fx"
local function getEndpoint(api_key)
    if api_key and api_key:match(":fx$") then
        return "https://api-free.deepl.com/v2/translate"
    end
    return "https://api.deepl.com/v2/translate"
end

--- Max paragraphs per request (DeepL recommends <= 50 texts per call)
local BATCH_SIZE = 25

--- Translate paragraphs using DeepL batch API with automatic splitting.
function DeepLEngine:translate(paragraphs, source_lang, target_lang, api_key, callback)
    if not api_key or api_key == "" then
        callback(false, "DeepL API key is required")
        return
    end

    local url = getEndpoint(api_key)
    local headers = {
        ["Authorization"] = "DeepL-Auth-Key " .. api_key,
    }

    -- Split paragraphs into batches
    local batches = {}
    for i = 1, #paragraphs, BATCH_SIZE do
        local batch = {}
        for j = i, math.min(i + BATCH_SIZE - 1, #paragraphs) do
            table.insert(batch, paragraphs[j])
        end
        table.insert(batches, batch)
    end

    logger.dbg("DeepL: splitting", #paragraphs, "paragraphs into", #batches, "batches")

    local all_translations = {}
    local current_batch = 1
    local UIManager = require("ui/uimanager")

    local function translateNextBatch()
        if current_batch > #batches then
            -- All batches done
            if #all_translations ~= #paragraphs then
                logger.warn("DeepL: got", #all_translations, "translations for",
                           #paragraphs, "paragraphs")
            end
            callback(true, all_translations)
            return
        end

        local batch = batches[current_batch]
        local body = {
            text = batch,
            target_lang = target_lang:upper(),
        }
        if source_lang and source_lang ~= "" and source_lang ~= "auto" then
            body.source_lang = source_lang:upper()
        end

        self:jsonPost(url, headers, body, function(ok, result)
            if not ok then
                callback(false, "DeepL error (batch " .. current_batch .. "): " .. tostring(result))
                return
            end

            if not result.translations then
                callback(false, "DeepL: unexpected response format in batch " .. current_batch)
                return
            end

            for _, item in ipairs(result.translations) do
                table.insert(all_translations, item.text or "")
            end

            logger.dbg("DeepL: batch", current_batch, "done,",
                       #result.translations, "translations received")

            current_batch = current_batch + 1

            -- Small delay between batches to respect rate limits
            if current_batch <= #batches then
                UIManager:scheduleIn(0.3, translateNextBatch)
            else
                translateNextBatch()
            end
        end)
    end

    translateNextBatch()
end

return DeepLEngine
