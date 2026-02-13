--[[--
EPUB manipulation module for the Translator plugin.

Creates a bilingual copy of an EPUB with translated paragraphs
injected directly into the HTML alongside the originals.

@module translator_epub
]]

local logger = require("logger")

local TranslatorEpub = {}

--- Normalize text for matching: strip HTML tags, entities, whitespace, lowercase.
-- Returns first 40 alphanumeric chars as a matching key.
local function matchKey(text)
    if not text then return "" end
    local clean = text:gsub("<[^>]+>", "")       -- strip tags
    clean = clean:gsub("&[%w#]+;", " ")           -- strip entities
    local key = clean:gsub("[^%w]", ""):lower()   -- alphanumeric only
    return key:sub(1, 40)
end

--- Get the bilingual EPUB path from the original.
function TranslatorEpub.getBilingualPath(original_path, target_lang)
    local base = original_path:match("(.+)%.[^.]+$") or original_path
    local ext = original_path:match("%.([^.]+)$") or "epub"
    return base .. "_bilingual_" .. target_lang .. "." .. ext
end

--- Check if a path is already a bilingual copy.
function TranslatorEpub.isBilingual(file_path)
    return file_path:find("_bilingual_") ~= nil
end

--- Inject translations into an EPUB, creating a bilingual copy.
-- @param original_path string Original EPUB path
-- @param paragraphs table Array of original paragraph texts
-- @param translations table Array of translated texts
-- @param target_lang string Target language code
-- @return string|nil path to bilingual EPUB, or nil
-- @return string|nil error message
function TranslatorEpub.injectTranslations(original_path, paragraphs, translations, target_lang)
    local bilingual_path = TranslatorEpub.getBilingualPath(original_path, target_lang)
    local tmp_dir = "/tmp/translator_epub_" .. os.time() .. "_" .. math.random(1000, 9999)

    -- Build lookup: matchKey -> translation
    local lookup = {}
    local count = 0
    for i, para in ipairs(paragraphs) do
        local key = matchKey(para)
        if key ~= "" and translations[i] and translations[i] ~= "" then
            lookup[key] = translations[i]
            count = count + 1
        end
    end
    if count == 0 then
        return nil, "No translations to inject"
    end

    -- Copy original if bilingual doesn't exist yet
    local existing = io.open(bilingual_path, "r")
    if existing then
        existing:close()
    else
        local ret = os.execute(string.format('cp %q %q', original_path, bilingual_path))
        if ret ~= 0 and ret ~= true then
            return nil, "Failed to copy EPUB"
        end
    end

    -- Unzip
    os.execute(string.format('rm -rf %q', tmp_dir))
    os.execute(string.format('mkdir -p %q', tmp_dir))
    local ret = os.execute(string.format('unzip -o -q %q -d %q', bilingual_path, tmp_dir))
    if ret ~= 0 and ret ~= true then
        os.execute(string.format('rm -rf %q', tmp_dir))
        return nil, "Failed to unzip EPUB"
    end

    -- Find and process all XHTML/HTML files
    local handle = io.popen(string.format(
        'find %q \\( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \\) -type f', tmp_dir))
    local injected_total = 0
    if handle then
        for file_path in handle:lines() do
            local n = TranslatorEpub._processHtmlFile(file_path, lookup, target_lang)
            injected_total = injected_total + n
        end
        handle:close()
    end
    logger.dbg("TranslatorEpub: injected", injected_total, "translations total")

    -- Inject CSS
    TranslatorEpub._injectCSS(tmp_dir)

    -- Rezip
    os.execute(string.format('rm -f %q', bilingual_path))
    ret = os.execute(string.format('cd %q && zip -r -q %q .', tmp_dir, bilingual_path))

    -- Cleanup
    os.execute(string.format('rm -rf %q', tmp_dir))

    if ret ~= 0 and ret ~= true then
        return nil, "Failed to create bilingual EPUB"
    end

    return bilingual_path
end

--- Process a single HTML file, injecting translations after matching <p> elements.
-- @return number count of injected translations
function TranslatorEpub._processHtmlFile(file_path, lookup, target_lang)
    local f = io.open(file_path, "r")
    if not f then return 0 end
    local content = f:read("*all")
    f:close()

    local injected = 0
    local result = {}
    local pos = 1

    while true do
        local p_start = content:find("<p[%s>]", pos)
        if not p_start then
            table.insert(result, content:sub(pos))
            break
        end

        table.insert(result, content:sub(pos, p_start - 1))

        local close_start, close_end = content:find("</p>", p_start + 2)
        if not close_start then
            table.insert(result, content:sub(p_start))
            break
        end

        local full_p = content:sub(p_start, close_end)

        -- Skip already-injected translation paragraphs
        if full_p:find('class="tl%-bilingual"') then
            table.insert(result, full_p)
            pos = close_end + 1
        else
            -- Extract inner text for matching
            local tag_end_pos = content:find(">", p_start)
            local p_content = tag_end_pos and content:sub(tag_end_pos + 1, close_start - 1) or ""
            local key = matchKey(p_content)

            table.insert(result, full_p)

            if key ~= "" and lookup[key] then
                local escaped = lookup[key]
                    :gsub("&", "&amp;")
                    :gsub("<", "&lt;")
                    :gsub(">", "&gt;")
                local tl_p = string.format(
                    '\n<p class="tl-bilingual" lang="%s">%s</p>',
                    target_lang, escaped)
                table.insert(result, tl_p)
                lookup[key] = nil  -- consumed, prevent duplicates
                injected = injected + 1
            end

            pos = close_end + 1
        end
    end

    if injected > 0 then
        local f_out = io.open(file_path, "w")
        if f_out then
            f_out:write(table.concat(result))
            f_out:close()
            logger.dbg("TranslatorEpub: injected", injected, "in", file_path)
        end
    end

    return injected
end

--- Add CSS styling for translated paragraphs.
function TranslatorEpub._injectCSS(tmp_dir)
    local bilingual_css = "\n/* Translator Plugin */\n"
        .. "p.tl-bilingual {\n"
        .. "  font-style: normal;\n"
        .. "  border-left: 3px solid #888;\n"
        .. "  padding-left: 0.5em;\n"
        .. "  margin-top: 0.2em;\n"
        .. "  margin-bottom: 1em;\n"
        .. "}\n"

    local css_added = false
    local handle = io.popen(string.format('find %q -name "*.css" -type f', tmp_dir))
    if handle then
        for css_path in handle:lines() do
            local f = io.open(css_path, "r")
            if f then
                local existing = f:read("*all")
                f:close()
                if not existing:find("tl%-bilingual") then
                    f = io.open(css_path, "a")
                    if f then
                        f:write(bilingual_css)
                        f:close()
                    end
                end
                css_added = true
            end
        end
        handle:close()
    end

    -- Fallback: inject <style> into HTML files
    if not css_added then
        local style_tag = '<style type="text/css">'
            .. 'p.tl-bilingual{font-style:normal;border-left:3px solid #888;'
            .. 'padding-left:0.5em;margin-top:0.2em;margin-bottom:1em;}'
            .. '</style>'
        local h2 = io.popen(string.format(
            'find %q \\( -name "*.xhtml" -o -name "*.html" \\) -type f', tmp_dir))
        if h2 then
            for html_path in h2:lines() do
                local f = io.open(html_path, "r")
                if f then
                    local c = f:read("*all")
                    f:close()
                    if not c:find("tl%-bilingual") then
                        c = c:gsub("</head>", style_tag .. "\n</head>", 1)
                        f = io.open(html_path, "w")
                        if f then f:write(c); f:close() end
                    end
                end
            end
            h2:close()
        end
    end
end

return TranslatorEpub
