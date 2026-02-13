local _ = require("gettext")
return {
    name = "translator",
    fullname = _("Book Translator"),
    description = _([[Translate books chapter by chapter using your own API key (DeepL, Azure, Yandex, Groq). Injects translated text after each original paragraph in a bilingual view.]]),
}
