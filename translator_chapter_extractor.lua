--[[--
Chapter text extractor.

Extracts the plain text of the current chapter from the active document,
split into an array of paragraphs.

Works with both flowing (EPUB) and page-based (PDF) documents.
Uses page-by-page extraction to avoid blocking the UI on slow devices.

@module translator_chapter_extractor
]]

local logger = require("logger")

local ChapterExtractor = {}
ChapterExtractor.__index = ChapterExtractor

--- Create a new ChapterExtractor.
-- @param ui ReaderUI instance
-- @return ChapterExtractor
function ChapterExtractor:new(ui)
    local instance = setmetatable({}, self)
    instance.ui = ui
    return instance
end

--- Maximum pages per translation request to avoid huge API bills
local MAX_PAGES = 30

--- Find the page range of the current chapter from the TOC.
-- Prefers depth=2 entries (typical chapters) over depth=1 (Parts).
-- Falls back to depth <= 2, then all entries.
-- Caps at MAX_PAGES to protect API quota.
-- @return number start_page, number end_page, string|nil chapter_title
function ChapterExtractor:getChapterBounds()
    local document = self.ui.document
    local total_pages = document.info.number_of_pages or 0
    if total_pages == 0 then
        return nil, nil, nil
    end

    local current_page = self.ui:getCurrentPage()

    -- Try to get TOC
    local toc
    if self.ui.toc and self.ui.toc.toc then
        toc = self.ui.toc.toc
    end

    if not toc or #toc == 0 then
        logger.dbg("ChapterExtractor: No TOC found, using current page")
        return current_page, current_page, nil
    end

    -- Step 1: Try depth == 2 only (typical chapter level)
    local filtered = {}
    for _, entry in ipairs(toc) do
        if (entry.depth or 0) == 2 then
            table.insert(filtered, entry)
        end
    end

    -- Step 2: If not enough, try depth <= 2
    if #filtered < 2 then
        filtered = {}
        for _, entry in ipairs(toc) do
            if (entry.depth or 0) <= 2 then
                table.insert(filtered, entry)
            end
        end
    end

    -- Step 3: If still not enough, use all entries
    if #filtered < 2 then
        filtered = {}
        for _, entry in ipairs(toc) do
            table.insert(filtered, entry)
        end
    end

    if #filtered == 0 then
        logger.dbg("ChapterExtractor: No usable TOC entries")
        return current_page, current_page, nil
    end

    -- Find the last entry whose page <= current_page
    local chapter_start = 1
    local chapter_end = total_pages
    local chapter_title = nil

    for i, entry in ipairs(filtered) do
        local entry_page = entry.page or 0
        if entry_page <= current_page then
            chapter_start = entry_page
            chapter_title = entry.title
            if filtered[i + 1] then
                chapter_end = (filtered[i + 1].page or total_pages) - 1
            else
                chapter_end = total_pages
            end
        elseif entry_page > current_page then
            break
        end
    end

    -- Clamp
    chapter_start = math.max(1, chapter_start)
    chapter_end = math.min(total_pages, chapter_end)

    -- Cap at MAX_PAGES to protect API quota
    if chapter_end - chapter_start + 1 > MAX_PAGES then
        chapter_end = chapter_start + MAX_PAGES - 1
        logger.dbg("ChapterExtractor: capped to", MAX_PAGES, "pages")
    end

    logger.dbg("ChapterExtractor: chapter bounds =", chapter_start, "-", chapter_end,
               "(", chapter_end - chapter_start + 1, "pages)",
               "title =", chapter_title or "(untitled)")
    return chapter_start, chapter_end, chapter_title
end

--- Extract text from a single page (EPUB or PDF).
local function extractPageText(document, page, total_pages)
    if not document.info.has_pages then
        -- EPUB: extract text between this page's XPointer and the next page's
        local ok, text = pcall(function()
            local start_xp = document:getPageXPointer(page)
            local end_xp = document:getPageXPointer(math.min(page + 1, total_pages))
            if start_xp and end_xp then
                return document:getTextFromXPointers(start_xp, end_xp) or ""
            end
            return ""
        end)
        return ok and text or ""
    else
        -- PDF: use getPageText
        local ok, page_text = pcall(function()
            return document:getPageText(page)
        end)
        if ok then
            if type(page_text) == "table" then
                local words = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for j = 1, #block do
                            local span = block[j]
                            if type(span) == "table" and span.word then
                                table.insert(words, span.word)
                            end
                        end
                    end
                end
                return table.concat(words, " ")
            end
            return page_text or ""
        end
        return ""
    end
end

--- Split full text into paragraphs.
local function splitParagraphs(full_text)
    local paragraphs = {}
    local current_para = ""
    local lines = {}
    for line in full_text:gmatch("[^\n]*") do
        table.insert(lines, line)
    end

    for _, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed == "" then
            if current_para ~= "" then
                table.insert(paragraphs, current_para)
                current_para = ""
            end
        else
            if current_para ~= "" then
                current_para = current_para .. " " .. trimmed
            else
                current_para = trimmed
            end
        end
    end
    if current_para ~= "" then
        table.insert(paragraphs, current_para)
    end

    return paragraphs
end

--- Extract chapter text asynchronously, page by page, calling callback when done.
function ChapterExtractor:extractAsync(callback)
    local document = self.ui.document
    if not document then
        callback({}, nil)
        return
    end

    local start_page, end_page, chapter_title = self:getChapterBounds()
    if not start_page then
        callback({}, nil)
        return
    end

    local total_pages = document.info.number_of_pages or 0
    local collected = {}
    local current_page = start_page
    local PAGES_PER_TICK = 5

    local UIManager = require("ui/uimanager")

    local function processNextBatch()
        local batch_end = math.min(current_page + PAGES_PER_TICK - 1, end_page)

        for page = current_page, batch_end do
            local text = extractPageText(document, page, total_pages)
            if text ~= "" then
                table.insert(collected, text)
            end
        end

        current_page = batch_end + 1

        if current_page > end_page then
            local full_text = table.concat(collected, "\n")
            local paragraphs = splitParagraphs(full_text)
            logger.dbg("ChapterExtractor: extracted", #paragraphs, "paragraphs from",
                       end_page - start_page + 1, "pages")
            callback(paragraphs, chapter_title)
        else
            UIManager:scheduleIn(0.01, processNextBatch)
        end
    end

    UIManager:scheduleIn(0.01, processNextBatch)
end

--- Extract text synchronously.
function ChapterExtractor:extract()
    local document = self.ui.document
    if not document then
        return {}, nil
    end

    local start_page, end_page, chapter_title = self:getChapterBounds()
    if not start_page then
        return {}, nil
    end

    local total_pages = document.info.number_of_pages or 0
    local collected = {}

    for page = start_page, end_page do
        local text = extractPageText(document, page, total_pages)
        if text ~= "" then
            table.insert(collected, text)
        end
    end

    local full_text = table.concat(collected, "\n")
    local paragraphs = splitParagraphs(full_text)
    logger.dbg("ChapterExtractor: extracted", #paragraphs, "paragraphs")
    return paragraphs, chapter_title
end

return ChapterExtractor
