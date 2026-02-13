--[[--
Groq (LLM) translation engine.

Uses the Groq API (OpenAI-compatible) with a system prompt instructing
the model to translate numbered paragraphs.

@module translator_engines.groq
]]

local BaseEngine = require("translator_engines/base")
local logger = require("logger")

local GroqEngine = BaseEngine:new()

function GroqEngine:getName() return "Groq (LLM)" end
function GroqEngine:getKey() return "groq" end

local DEFAULT_MODEL = "llama-3.3-70b-versatile"
local BATCH_SIZE = 20  -- paragraphs per API call to stay within context

--- Build the system prompt for translation.
local function buildSystemPrompt(source_lang, target_lang)
    return string.format(
        "You are a professional translator. Translate each numbered paragraph from %s to %s. "
        .. "Rules:\n"
        .. "1. Return ONLY the translated text, with the same numbering.\n"
        .. "2. One translated paragraph per number.\n"
        .. "3. Preserve paragraph numbering (1., 2., 3., etc.)\n"
        .. "4. Do NOT add explanations, comments, or notes.\n"
        .. "5. Preserve the original meaning, tone, and style.",
        source_lang or "the source language",
        target_lang or "the target language"
    )
end

--- Format paragraphs as numbered list for the LLM.
local function formatNumbered(paragraphs, offset)
    offset = offset or 0
    local lines = {}
    for i, p in ipairs(paragraphs) do
        table.insert(lines, string.format("%d. %s", i + offset, p))
    end
    return table.concat(lines, "\n")
end

--- Parse numbered translations from LLM response.
-- @param text string LLM response text
-- @param expected_count number Expected number of paragraphs
-- @return table Array of translated strings
local function parseNumbered(text, expected_count)
    local translations = {}
    -- Match lines like "1. translated text" or "1) translated text"
    for num, content in text:gmatch("(%d+)[.%):]%s*(.-)%s*\n") do
        translations[tonumber(num)] = content
    end
    -- Handle last line (no trailing newline)
    local last_num, last_content = text:match("(%d+)[.%):]%s*(.-)%s*$")
    if last_num then
        translations[tonumber(last_num)] = last_content
    end

    -- Convert to ordered array
    local result = {}
    for i = 1, expected_count do
        table.insert(result, translations[i] or "")
    end
    return result
end

--- Translate paragraphs using Groq LLM.
function GroqEngine:translate(paragraphs, source_lang, target_lang, api_key, callback)
    if not api_key or api_key == "" then
        callback(false, "Groq API key is required")
        return
    end

    local url = "https://api.groq.com/openai/v1/chat/completions"
    local model = self.model or DEFAULT_MODEL
    local system_prompt = buildSystemPrompt(source_lang, target_lang)

    -- Split into batches
    local total_batches = math.ceil(#paragraphs / BATCH_SIZE)
    local all_translations = {}
    local batches_done = 0

    local function processBatch(batch_idx)
        local start_i = (batch_idx - 1) * BATCH_SIZE + 1
        local end_i = math.min(batch_idx * BATCH_SIZE, #paragraphs)

        local batch = {}
        for i = start_i, end_i do
            table.insert(batch, paragraphs[i])
        end

        local user_message = formatNumbered(batch, start_i - 1)

        local body = {
            model = model,
            messages = {
                { role = "system", content = system_prompt },
                { role = "user", content = user_message },
            },
            temperature = 0.3,
            max_tokens = 8192,
        }

        local headers = {
            ["Authorization"] = "Bearer " .. api_key,
        }

        self:jsonPost(url, headers, body, function(ok, result)
            if not ok then
                callback(false, "Groq error: " .. tostring(result))
                return
            end

            -- Extract content from OpenAI-format response
            local content = ""
            if result.choices and result.choices[1] and result.choices[1].message then
                content = result.choices[1].message.content or ""
            end

            local batch_translations = parseNumbered(content, #batch)

            -- Append to all_translations
            for _, t in ipairs(batch_translations) do
                table.insert(all_translations, t)
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

return GroqEngine
