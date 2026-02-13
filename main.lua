--[[--
Book Translator Plugin for KOReader.

Translates the current chapter using an external API (DeepL, Azure, Yandex, Groq)
and displays a bilingual view with original + translated paragraphs interleaved.

@module translator
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ChapterExtractor = require("translator_chapter_extractor")
local TranslatorCache = require("translator_cache")
local TranslatorEpub = require("translator_epub")

-- Available engines (lazy-loaded)
local ENGINE_REGISTRY = {
    { key = "deepl",  name = "DeepL",            module = "translator_engines/deepl" },
    { key = "azure",  name = "Microsoft Azure",   module = "translator_engines/azure" },
    { key = "yandex", name = "Yandex",            module = "translator_engines/yandex" },
    { key = "groq",   name = "Groq (LLM)",        module = "translator_engines/groq" },
}

-- Common language choices
local LANGUAGES = {
    { code = "auto", label = _("Auto-detect") },
    { code = "pt-br", label = "Português (BR)" },
    { code = "pt",    label = "Português" },
    { code = "en",    label = "English" },
    { code = "es",    label = "Español" },
    { code = "fr",    label = "Français" },
    { code = "de",    label = "Deutsch" },
    { code = "it",    label = "Italiano" },
    { code = "ru",    label = "Русский" },
    { code = "zh",    label = "中文" },
    { code = "ja",    label = "日本語" },
    { code = "ko",    label = "한국어" },
}

local Translator = WidgetContainer:extend{
    name = "translator",
    is_doc_only = true,
}

function Translator:init()
    self.ui.menu:registerToMainMenu(self)

    -- Load saved settings
    self.settings = self.ui.doc_settings or {}
    self.engine_key = G_reader_settings:readSetting("translator_engine") or "deepl"
    self.target_lang = G_reader_settings:readSetting("translator_target_lang") or "pt-br"
    self.source_lang = G_reader_settings:readSetting("translator_source_lang") or "auto"
    self.api_keys = G_reader_settings:readSetting("translator_api_keys") or {}

    -- Load API keys from api_keys.lua file as fallback
    self.file_api_keys = {}
    local ok, keys = pcall(require, "translator_api_keys")
    if ok and type(keys) == "table" then
        self.file_api_keys = keys
        logger.dbg("Translator: loaded API keys from api_keys.lua")
    end

    -- Register dispatcher action
    Dispatcher:registerAction("translate_chapter", {
        category = "none",
        event = "TranslateChapter",
        title = _("Translate Current Chapter"),
        general = true,
    })
end

function Translator:onDispatcherRegisterActions()
    Dispatcher:registerAction("translate_chapter", {
        category = "none",
        event = "TranslateChapter",
        title = _("Translate Current Chapter"),
        general = true,
    })
end

function Translator:onTranslateChapter()
    self:translateCurrentChapter()
end

function Translator:addToMainMenu(menu_items)
    menu_items.translator = {
        text = _("Book Translator"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Translate Current Chapter"),
                keep_menu_open = false,
                callback = function()
                    self:translateCurrentChapter()
                end,
            },
            {
                text = "---",
                separator = true,
            },
            -- Engine selection
            {
                text_func = function()
                    local engine_name = self:getEngineName()
                    return T(_("Translation Engine: %1"), engine_name)
                end,
                sub_item_table = self:buildEngineMenu(),
            },
            -- API Key configuration
            {
                text = _("Configure API Key"),
                keep_menu_open = true,
                callback = function()
                    self:showApiKeyDialog()
                end,
            },
            {
                text = "---",
                separator = true,
            },
            -- Target language
            {
                text_func = function()
                    local lang_label = self:getLangLabel(self.target_lang)
                    return T(_("Target Language: %1"), lang_label)
                end,
                sub_item_table = self:buildLangMenu("target"),
            },
            -- Source language
            {
                text_func = function()
                    local lang_label = self:getLangLabel(self.source_lang)
                    return T(_("Source Language: %1"), lang_label)
                end,
                sub_item_table = self:buildLangMenu("source"),
            },
            {
                text = "---",
                separator = true,
            },
            -- Clear cache
            {
                text = _("Clear Translation Cache"),
                keep_menu_open = true,
                callback = function()
                    self:clearCache()
                end,
            },
        },
    }
end

--- Get display name for currently selected engine.
function Translator:getEngineName()
    for _, e in ipairs(ENGINE_REGISTRY) do
        if e.key == self.engine_key then return e.name end
    end
    return self.engine_key
end

--- Get display label for a language code.
function Translator:getLangLabel(code)
    for _, l in ipairs(LANGUAGES) do
        if l.code == code then return l.label end
    end
    return code
end

--- Build submenu for engine selection.
function Translator:buildEngineMenu()
    local items = {}
    for _, e in ipairs(ENGINE_REGISTRY) do
        table.insert(items, {
            text = e.name,
            checked_func = function() return self.engine_key == e.key end,
            callback = function()
                self.engine_key = e.key
                G_reader_settings:saveSetting("translator_engine", e.key)
            end,
        })
    end
    return items
end

--- Build submenu for language selection.
function Translator:buildLangMenu(which)
    local items = {}
    local lang_list = LANGUAGES
    -- Source gets "auto-detect"; target doesn't
    if which == "target" then
        lang_list = {}
        for _, l in ipairs(LANGUAGES) do
            if l.code ~= "auto" then
                table.insert(lang_list, l)
            end
        end
    end

    for _, l in ipairs(lang_list) do
        table.insert(items, {
            text = l.label,
            checked_func = function()
                if which == "target" then
                    return self.target_lang == l.code
                else
                    return self.source_lang == l.code
                end
            end,
            callback = function()
                if which == "target" then
                    self.target_lang = l.code
                    G_reader_settings:saveSetting("translator_target_lang", l.code)
                else
                    self.source_lang = l.code
                    G_reader_settings:saveSetting("translator_source_lang", l.code)
                end
            end,
        })
    end
    return items
end

--- Show API key input dialog.
function Translator:showApiKeyDialog()
    local current_key = self.api_keys[self.engine_key] or ""
    local engine_name = self:getEngineName()

    local dialog
    dialog = InputDialog:new{
        title = T(_("API Key for %1"), engine_name),
        input = current_key,
        input_hint = _("Paste your API key here"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local key = dialog:getInputText()
                        self.api_keys[self.engine_key] = key
                        G_reader_settings:saveSetting("translator_api_keys", self.api_keys)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = T(_("API key for %1 saved."), engine_name),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Load the selected translation engine.
function Translator:getEngine()
    for _, e in ipairs(ENGINE_REGISTRY) do
        if e.key == self.engine_key then
            local ok, engine = pcall(require, e.module)
            if ok then
                return engine
            else
                logger.warn("Translator: failed to load engine", e.key, ":", engine)
                return nil, tostring(engine)
            end
        end
    end
    return nil, "Unknown engine: " .. self.engine_key
end

--- Main entry point: translate the current chapter.
function Translator:translateCurrentChapter()
    -- Check API key (GUI settings take priority, then api_keys.lua file)
    local api_key = self.api_keys[self.engine_key]
    if not api_key or api_key == "" then
        api_key = self.file_api_keys[self.engine_key]
    end
    if not api_key or api_key == "" then
        UIManager:show(InfoMessage:new{
            text = T(_("No API key configured for %1.\n\nGo to:\nTools → Book Translator → Configure API Key"), self:getEngineName()),
        })
        return
    end

    -- Get engine
    local engine, err = self:getEngine()
    if not engine then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to load translation engine: %1"), err),
        })
        return
    end

    -- Show progress
    local progress = InfoMessage:new{
        text = _("Extracting chapter text..."),
        dismissable = true,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()

    -- Extract chapter ASYNC (yields to UI loop, prevents freezing on Kindle)
    local extractor = ChapterExtractor:new(self.ui)
    extractor:extractAsync(function(paragraphs, chapter_title)
        if not paragraphs or #paragraphs == 0 then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = _("Could not extract text from the current chapter."),
            })
            return
        end

        -- Check cache
        local book_path = self.ui.document.file
        local cache = TranslatorCache:new(book_path)
        cache:load(self.engine_key, self.target_lang)

        local uncached_indices = {}
        local uncached_paragraphs = {}
        local translations = {}

        for i, para in ipairs(paragraphs) do
            local cached = cache:get(para)
            if cached then
                translations[i] = cached
            else
                table.insert(uncached_indices, i)
                table.insert(uncached_paragraphs, para)
            end
        end

        local cached_count = #paragraphs - #uncached_paragraphs

        -- Cap uncached paragraphs to protect API quota
        local MAX_TRANSLATE = 100
        local skipped = 0
        if #uncached_paragraphs > MAX_TRANSLATE then
            skipped = #uncached_paragraphs - MAX_TRANSLATE
            -- Trim to first MAX_TRANSLATE uncached
            local trimmed_indices = {}
            local trimmed_paragraphs = {}
            for j = 1, MAX_TRANSLATE do
                trimmed_indices[j] = uncached_indices[j]
                trimmed_paragraphs[j] = uncached_paragraphs[j]
            end
            uncached_indices = trimmed_indices
            uncached_paragraphs = trimmed_paragraphs
            logger.dbg("Translator: capped to", MAX_TRANSLATE,
                       "paragraphs, skipped", skipped)
        end

        if #uncached_paragraphs == 0 then
            -- All cached! Build and show immediately
            UIManager:close(progress)
            self:buildAndShow(paragraphs, translations, chapter_title)
            return
        end

        -- Update progress
        UIManager:close(progress)
        progress = InfoMessage:new{
            text = T(_("Translating %1 paragraphs with %2...\n(%3 cached)"),
                     #uncached_paragraphs, self:getEngineName(), cached_count),
            dismissable = false,
        }
        UIManager:show(progress)
        UIManager:forceRePaint()

        -- Translate uncached paragraphs
        local source = self.source_lang
        if source == "auto" then source = nil end

        engine:translate(uncached_paragraphs, source, self.target_lang, api_key,
            function(success, result)
                UIManager:close(progress)

                if not success then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Translation failed:\n%1"), tostring(result)),
                    })
                    return
                end

                -- Merge translations
                for j, idx in ipairs(uncached_indices) do
                    local trans_text = result[j] or ""
                    translations[idx] = trans_text
                    cache:set(paragraphs[idx], trans_text)
                end
                cache:save()

                -- Build ordered translations array
                local ordered = {}
                for i = 1, #paragraphs do
                    table.insert(ordered, translations[i] or "")
                end

                self:buildAndShow(paragraphs, ordered, chapter_title)
            end)
    end)  -- end extractAsync callback
end

--- Inject translations into book and open bilingual copy.
function Translator:buildAndShow(paragraphs, translations, chapter_title)
    local book_path = self.ui.document.file

    -- If already reading a bilingual copy, use original as source
    local original_path = book_path
    if TranslatorEpub.isBilingual(book_path) then
        -- Derive original path by stripping _bilingual_XX suffix
        original_path = book_path:gsub("_bilingual_[^.]+%.", ".")
    end

    local progress = InfoMessage:new{
        text = _("Injecting translations into book..."),
        dismissable = false,
    }
    UIManager:show(progress)
    UIManager:forceRePaint()

    -- Inject translations into EPUB copy
    local bilingual_path, err = TranslatorEpub.injectTranslations(
        original_path, paragraphs, translations, self.target_lang)

    UIManager:close(progress)

    if not bilingual_path then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to create bilingual book:\n%1"), err or "unknown error"),
        })
        return
    end

    -- Open the bilingual EPUB
    local ReaderUI = require("apps/reader/readerui")
    UIManager:show(InfoMessage:new{
        text = _("Opening bilingual book..."),
        timeout = 1,
    })
    UIManager:scheduleIn(0.5, function()
        ReaderUI:showReader(bilingual_path)
    end)
end

--- Clear translation cache for current book.
function Translator:clearCache()
    local book_path = self.ui.document.file
    if not book_path then return end

    local cache = TranslatorCache:new(book_path)
    cache:clearAll()

    UIManager:show(InfoMessage:new{
        text = _("Translation cache cleared for this book."),
        timeout = 2,
    })
end

return Translator
