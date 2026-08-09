-- Prompt construction for the story-so-far recap.
local Prompts = {}

Prompts.lengths = {
    short    = { words = 150 },
    standard = { words = 400 },
    detailed = { words = 800 },
}

-- Returns { system = ..., user = ... }.
function Prompts.build(meta, text, recap_length)
    local len = Prompts.lengths[recap_length] or Prompts.lengths.standard
    local system = table.concat({
        "You are generating a 'story so far' recap for a reader returning to a book.",
        "Summarize ONLY the text provided by the user; it ends at the reader's current position in the book.",
        "Never reveal, predict, or speculate about anything beyond the provided text.",
        "No foreshadowing, no hints about what may happen next, no knowledge from outside the provided text.",
        "The provided text may be only the most recent portion of a longer book;",
        "if so, recap what is there without inventing earlier events.",
        "Cover the main characters, their situations, and the key plot developments in narrative order.",
        "Write in the same language as the book text.",
        "Target length: about " .. len.words .. " words.",
    }, " ")

    local header = {}
    if meta and meta.title and meta.title ~= "" then
        header[#header + 1] = "Book: " .. meta.title
    end
    if meta and meta.authors and meta.authors ~= "" then
        header[#header + 1] = "Author: " .. meta.authors
    end
    if meta and meta.chapter and meta.chapter ~= "" then
        header[#header + 1] = "Reader's current chapter: " .. meta.chapter
    end

    local user = ""
    if #header > 0 then
        user = table.concat(header, "\n") .. "\n\n"
    end
    user = user .. "Text read so far:\n\n" .. (text or "")
        .. "\n\nWrite the story-so-far recap now."

    return { system = system, user = user }
end

return Prompts
