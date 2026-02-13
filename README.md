# translator.koplugin

A KOReader plugin that translates books chapter by chapter, injecting the translated text directly into the EPUB alongside the original paragraphs. Read in your language without leaving the book.

## How it works

1. Open any EPUB in KOReader
2. Navigate to the chapter you want to translate
3. Go to **Tools → Book Translator → Translate Current Chapter**
4. The plugin creates a bilingual copy of your book with translated paragraphs inserted after each original paragraph
5. Keep reading — translate more chapters as you go

Translated paragraphs are visually separated by a left border so you can tell them apart at a glance.

## Supported translation engines

| Engine | Free tier | Notes |
|--------|-----------|-------|
| **DeepL** | 500k chars/month | Best quality for European languages |
| **Microsoft Azure** | 2M chars/month | Broad language support |
| **Yandex Translate** | Limited | Good for Russian/CIS languages |
| **Groq** (LLM) | Free tier available | Uses Llama for translation |

## Installation

### On Kindle / Kobo / PocketBook

1. Download or clone this repository
2. Copy the `translator.koplugin` folder to your device's KOReader `plugins/` directory
   - Kindle: `koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
3. Restart KOReader

### API key setup

You need at least one API key. Two ways to configure:

**Option A — Via the menu (recommended):**

Go to **Tools → Book Translator → Settings → API Keys** and enter your key.

**Option B — Via file:**

Copy `translator_api_keys.lua.sample` to `translator_api_keys.lua` and fill in your keys:

```lua
return {
    deepl  = "your-deepl-key-here",
    azure  = "",
    yandex = "",
    groq   = "",
}
```

Keys entered via the menu take priority over the file.

## Configuration

All settings are available under **Tools → Book Translator → Settings**:

- **Translation engine** — switch between DeepL, Azure, Yandex, or Groq
- **Target language** — the language you want to read in (default: `pt-br`)
- **Source language** — auto-detected by default, or set manually
- **API keys** — enter/update keys for each engine
- **Clear cache** — remove cached translations for the current book

## How translation works

- The plugin detects chapter boundaries from the book's table of contents
- Text is extracted page by page without freezing the UI
- Paragraphs are sent to the translation API in batches (25 per request for DeepL)
- Translations are cached per-book, so re-translating the same chapter is instant
- A bilingual EPUB copy is created (e.g., `book_bilingual_pt-br.epub`) — the original is never modified
- Subsequent chapter translations update the same bilingual copy

### Quota protection

To avoid burning through your API quota:

- Chapter detection uses actual chapter-level TOC entries (not broad "Parts")
- Extraction is capped at **30 pages** per request
- Translation is capped at **100 paragraphs** per request
- Already-translated paragraphs are served from cache

## File structure

```
translator.koplugin/
├── _meta.lua                        # Plugin metadata
├── main.lua                         # Plugin entry point, menu, translation flow
├── translator_api_keys.lua.sample   # API key template
├── translator_cache.lua             # Per-book translation cache
├── translator_chapter_extractor.lua # Chapter bounds detection + text extraction
├── translator_epub.lua              # EPUB manipulation (unzip, inject, rezip)
└── translator_engines/
    ├── base.lua                     # Base engine with async HTTP via subprocess
    ├── deepl.lua                    # DeepL API v2
    ├── azure.lua                    # Microsoft Azure Translator
    ├── yandex.lua                   # Yandex Cloud Translate
    └── groq.lua                     # Groq LLM-based translation
```

## Requirements

- KOReader (tested on Kindle, should work on Kobo/PocketBook/desktop)
- `zip` and `unzip` available on the device (standard on most KOReader-supported devices)
- An API key for at least one translation engine

## Known limitations

- Only EPUB files are supported (PDF support is partial — text extraction works but injection doesn't)
- Very short paragraphs (single words, headings) may not match between the extracted text and the HTML source
- The bilingual EPUB is a separate file — bookmarks and reading progress don't sync with the original

## License

MIT
