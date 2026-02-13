--[[--
Translation cache module.

Stores translations persistently per-book so chapters don't need re-translating.
Cache is keyed by a simple hash of paragraph text, scoped by target_lang + engine.

@module translator_cache
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local TranslatorCache = {}
TranslatorCache.__index = TranslatorCache

--- Simple string hash (djb2 algorithm) — fast and collision-resistant enough for cache keys.
local function hashString(str)
    local hash = 5381
    for i = 1, #str do
        hash = ((hash * 33) + str:byte(i)) % 0xFFFFFFFF
    end
    return string.format("%08x", hash)
end

--- Create a new cache instance for the given book.
-- @param book_path string Absolute path of the book file.
-- @return TranslatorCache instance
function TranslatorCache:new(book_path)
    local instance = setmetatable({}, self)
    -- Store cache alongside the book's sidecar directory
    local dir = book_path .. ".translator_cache"
    instance.cache_dir = dir
    instance.data = {}
    instance.dirty = false
    return instance
end

--- Build the file path for a given engine+lang combo.
function TranslatorCache:_filepath(engine, target_lang)
    return self.cache_dir .. "/" .. engine .. "_" .. target_lang:gsub("[^%w]", "_") .. ".lua"
end

--- Ensure cache directory exists.
function TranslatorCache:_ensureDir()
    lfs.mkdir(self.cache_dir)
end

--- Load cached translations for a specific engine and language.
function TranslatorCache:load(engine, target_lang)
    local path = self:_filepath(engine, target_lang)
    self.current_engine = engine
    self.current_lang = target_lang
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        self.data = data
        logger.dbg("TranslatorCache: loaded entries from", path)
    else
        self.data = {}
    end
    self.dirty = false
end

--- Generate cache key for a paragraph.
function TranslatorCache:key(text)
    return hashString(text)
end

--- Look up a translation from cache.
function TranslatorCache:get(text)
    local k = self:key(text)
    return self.data[k]
end

--- Store a translation in cache.
function TranslatorCache:set(text, translation)
    local k = self:key(text)
    self.data[k] = translation
    self.dirty = true
end

--- Save cache to disk (only if dirty).
function TranslatorCache:save()
    if not self.dirty then return end
    self:_ensureDir()
    local path = self:_filepath(self.current_engine, self.current_lang)
    local f = io.open(path, "w")
    if not f then
        logger.warn("TranslatorCache: cannot write to", path)
        return
    end
    f:write("return {\n")
    for k, v in pairs(self.data) do
        local escaped_v = v:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
        f:write(string.format('  ["%s"] = "%s",\n', k, escaped_v))
    end
    f:write("}\n")
    f:close()
    self.dirty = false
    logger.dbg("TranslatorCache: saved to", path)
end

--- Clear all cached translations for current engine/lang.
function TranslatorCache:clear()
    self.data = {}
    self.dirty = true
    self:save()
end

--- Clear ALL cached translations for this book.
function TranslatorCache:clearAll()
    if lfs.attributes(self.cache_dir, "mode") == "directory" then
        for f_name in lfs.dir(self.cache_dir) do
            if f_name ~= "." and f_name ~= ".." then
                os.remove(self.cache_dir .. "/" .. f_name)
            end
        end
        lfs.rmdir(self.cache_dir)
    end
    self.data = {}
    self.dirty = false
end

return TranslatorCache
