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

local function meta_header(meta)
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
    if #header > 0 then
        return table.concat(header, "\n") .. "\n\n"
    end
    return ""
end

-- Rolling update: merge only the newly-read text into the previous recap.
function Prompts.build_update(meta, prev_recap, delta_text, recap_length)
    local len = Prompts.lengths[recap_length] or Prompts.lengths.standard
    local system = table.concat({
        "You are updating an existing 'story so far' recap for a reader who has read further in a book.",
        "You will receive the previous recap and ONLY the text the reader has read since that recap;",
        "the new text ends at the reader's current position.",
        "Integrate the new text's events into the recap, preserving the earlier events' coverage",
        "from the previous recap, in narrative order.",
        "Never reveal, predict, or speculate about anything beyond the provided material.",
        "No foreshadowing, no hints about what may happen next.",
        "Write in the same language as the book text.",
        "Target length: about " .. len.words .. " words.",
    }, " ")
    local user = meta_header(meta)
        .. "Previous recap (covers the story up to where the new text begins):\n\n"
        .. (prev_recap or "")
        .. "\n\nText read since that recap:\n\n"
        .. (delta_text or "")
        .. "\n\nWrite the updated story-so-far recap now."
    return { system = system, user = user }
end

-- Drift-guard refresh: re-ground against real recent text without discarding
-- the coverage the previous recap accumulated for earlier parts of the book.
function Prompts.build_reground(meta, tail_text, prev_recap, recap_length)
    local len = Prompts.lengths[recap_length] or Prompts.lengths.standard
    local system = table.concat({
        "You are writing a fresh 'story so far' recap for a reader returning to a book.",
        "You will receive the most recent portion of the book text, ending at the reader's",
        "current position, and a previous recap that is authoritative for events BEFORE",
        "the provided text begins.",
        "Preserve that earlier coverage; ground recent events in the provided text,",
        "which takes precedence where the two overlap.",
        "Never invent beyond either source.",
        "Never reveal, predict, or speculate about anything beyond the provided material.",
        "Write in the same language as the book text.",
        "Target length: about " .. len.words .. " words.",
    }, " ")
    local user = meta_header(meta)
        .. "Previous recap (authoritative for events before the text below):\n\n"
        .. (prev_recap or "")
        .. "\n\nMost recent book text, ending at the reader's current position:\n\n"
        .. (tail_text or "")
        .. "\n\nWrite the full story-so-far recap now."
    return { system = system, user = user }
end

return Prompts
