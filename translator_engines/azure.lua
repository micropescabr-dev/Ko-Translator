--[[--
Microsoft Azure Translator engine.

Uses the Azure Cognitive Services Translator Text API v3.0.

@module translator_engines.azure
]]

local BaseEngine = require("translator_engines/base")
local logger = require("logger")

local AzureEngine = BaseEngine:new()

function AzureEngine:getName() return "Microsoft Azure" end
function AzureEngine:getKey() return "azure" end

--- Translate paragraphs using Azure Translator API.
-- Azure accepts an array of {"Text": "..."} objects and returns translations in order.
function AzureEngine:translate(paragraphs, source_lang, target_lang, api_key, callback)
    if not api_key or api_key == "" then
        callback(false, "Azure Translator API key is required")
        return
    end

    -- Azure endpoint
    local url = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0"
    url = url .. "&to=" .. target_lang
    if source_lang and source_lang ~= "" and source_lang ~= "auto" then
        url = url .. "&from=" .. source_lang
    end

    -- Azure accepts array of { Text = "..." }
    -- Max 100 elements per request, max 10000 chars total
    local BATCH_SIZE = 25  -- conservative batch size
    local all_translations = {}
    local total_batches = math.ceil(#paragraphs / BATCH_SIZE)
    local batches_done = 0

    local function processBatch(batch_idx)
        local start_i = (batch_idx - 1) * BATCH_SIZE + 1
        local end_i = math.min(batch_idx * BATCH_SIZE, #paragraphs)

        local body = {}
        for i = start_i, end_i do
            table.insert(body, { Text = paragraphs[i] })
        end

        local headers = {
            ["Ocp-Apim-Subscription-Key"] = api_key,
            ["Ocp-Apim-Subscription-Region"] = "global",
        }

        self:jsonPost(url, headers, body, function(ok, result)
            if not ok then
                callback(false, "Azure error: " .. tostring(result))
                return
            end

            if type(result) ~= "table" then
                callback(false, "Azure: unexpected response format")
                return
            end

            for _, item in ipairs(result) do
                if item.translations and item.translations[1] then
                    table.insert(all_translations, item.translations[1].text or "")
                else
                    table.insert(all_translations, "")
                end
            end

            batches_done = batches_done + 1
            if batches_done >= total_batches then
                callback(true, all_translations)
            else
                processBatch(batch_idx + 1)
            end
        end)
    end

    processBatch(1)
end

return AzureEngine
