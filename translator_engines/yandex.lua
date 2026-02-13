--[[--
Yandex Translate engine.

Uses the Yandex Cloud Translate API v2.

@module translator_engines.yandex
]]

local BaseEngine = require("translator_engines/base")
local logger = require("logger")

local YandexEngine = BaseEngine:new()

function YandexEngine:getName() return "Yandex" end
function YandexEngine:getKey() return "yandex" end

--- Translate paragraphs using Yandex Translate API v2.
-- Yandex accepts an array of texts and returns translations in order.
function YandexEngine:translate(paragraphs, source_lang, target_lang, api_key, callback)
    if not api_key or api_key == "" then
        callback(false, "Yandex API key is required")
        return
    end

    local url = "https://translate.api.cloud.yandex.net/translate/v2/translate"

    local body = {
        targetLanguageCode = target_lang,
        texts = paragraphs,
    }
    if source_lang and source_lang ~= "" and source_lang ~= "auto" then
        body.sourceLanguageCode = source_lang
    end

    local headers = {
        ["Authorization"] = "Api-Key " .. api_key,
    }

    self:jsonPost(url, headers, body, function(ok, result)
        if not ok then
            callback(false, "Yandex error: " .. tostring(result))
            return
        end

        if not result.translations then
            callback(false, "Yandex: unexpected response format")
            return
        end

        local translations = {}
        for _, item in ipairs(result.translations) do
            table.insert(translations, item.text or "")
        end

        callback(true, translations)
    end)
end

return YandexEngine
