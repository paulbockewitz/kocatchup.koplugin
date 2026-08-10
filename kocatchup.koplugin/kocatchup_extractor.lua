-- Extracts the book text from the start up to the current reading position,
-- plus metadata (title, authors, current chapter). Follows the pattern proven
-- by the Assistant plugin: xpointer range extraction for crengine documents,
-- bounded page-text lookback for page-based documents.
local Extractor = {
    DEFAULT_MAX_CHARS = 100000, -- tail window sent to the model (~25k tokens)
    PAGE_LOOKBACK = 250,        -- page-based docs: how many pages back to read
    MIN_CHARS = 200,            -- below this the recap has nothing to work with
}

-- After slicing a byte tail out of UTF-8 text, the first bytes may be
-- continuation bytes (0x80-0xBF) of a character whose start was cut off.
local function fix_utf8_start(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b >= 0x80 and b <= 0xBF then
            i = i + 1
        else
            break
        end
    end
    return s:sub(i)
end

local function truncate_tail(text, max_chars)
    if #text <= max_chars then return text end
    return fix_utf8_start(text:sub(#text - max_chars + 1))
end

-- getPageText may return a plain string, or a table of blocks where each
-- block is a list of {word=...} spans (or itself a span). Flatten defensively.
local function flatten_page_text(t)
    if type(t) == "string" then return t end
    if type(t) ~= "table" then return "" end
    local words = {}
    local function add_span(span)
        if type(span) == "table" and type(span.word) == "string" then
            words[#words + 1] = span.word
        elseif type(span) == "string" then
            words[#words + 1] = span
        end
    end
    for _, block in ipairs(t) do
        if type(block) == "table" and block.word then
            add_span(block)
        elseif type(block) == "table" then
            for _, span in ipairs(block) do
                add_span(span)
            end
        elseif type(block) == "string" then
            words[#words + 1] = block
        end
    end
    return table.concat(words, " ")
end

local function get_metadata(ui, page)
    local meta = {}
    pcall(function()
        local props = ui.document:getProps()
        if type(props) == "table" then
            meta.title = props.title
            meta.authors = props.authors
        end
    end)
    if page then
        pcall(function()
            meta.chapter = ui.toc:getTocTitleByPage(page)
        end)
    end
    return meta
end

local function extract_cre(ui)
    local doc = ui.document
    local current_xp = doc:getXPointer()
    doc:gotoPos(0)
    local start_xp = doc:getXPointer()
    doc:gotoXPointer(current_xp) -- restore the reading position
    local text = doc:getTextFromXPointers(start_xp, current_xp) or ""
    local page
    pcall(function() page = doc:getPageFromXPointer(current_xp) end)
    return text, page
end

local function extract_paged(ui)
    local doc = ui.document
    local current = 1
    pcall(function() current = ui.view.state.page or 1 end)
    local first = math.max(1, current - Extractor.PAGE_LOOKBACK)
    local parts = {}
    for p = first, current do
        local ok, t = pcall(function() return doc:getPageText(p) end)
        if ok and t then
            local s = flatten_page_text(t)
            if s ~= "" then parts[#parts + 1] = s end
        end
    end
    return table.concat(parts, "\n"), current
end

-- Extracts only the text between a stored position and the current position
-- (the "delta" for rolling recap updates). `from` is { xpointer = ... } for
-- crengine documents or { page = ... } for page-based ones.
-- opts.min_delta_chars overrides the minimum (0 = roll any non-empty delta);
-- background callers keep the default so trivial deltas are skippable.
-- Returns the same shape and typed failures as Extractor.extract.
function Extractor.extract_delta(ui, from, opts)
    local max_chars = (opts and opts.max_input_chars) or Extractor.DEFAULT_MAX_CHARS
    local min_chars = (opts and opts.min_delta_chars) or Extractor.MIN_CHARS
    local doc = ui.document
    local text, page
    if doc.info and doc.info.has_pages then
        local current = 1
        pcall(function() current = ui.view.state.page or 1 end)
        local first = (tonumber(from and from.page) or 0) + 1
        local parts = {}
        for p = first, current do
            local ok, t = pcall(function() return doc:getPageText(p) end)
            if ok and t then
                local s = flatten_page_text(t)
                if s ~= "" then parts[#parts + 1] = s end
            end
        end
        text = table.concat(parts, "\n")
        page = current
    else
        if not (from and from.xpointer) then return nil, "no_text" end
        local current_xp = doc:getXPointer()
        text = doc:getTextFromXPointers(from.xpointer, current_xp) or ""
        pcall(function() page = doc:getPageFromXPointer(current_xp) end)
    end
    if not text or text == "" then
        return nil, "no_text"
    end
    if #text < min_chars then
        return nil, "too_short"
    end
    return {
        text = truncate_tail(text, max_chars),
        metadata = get_metadata(ui, page),
    }
end

-- Returns { text = ..., metadata = { title, authors, chapter } }
-- or nil, "no_text" | "too_short".
function Extractor.extract(ui, opts)
    local max_chars = (opts and opts.max_input_chars) or Extractor.DEFAULT_MAX_CHARS
    local doc = ui.document
    local text, page
    if doc.info and doc.info.has_pages then
        text, page = extract_paged(ui)
    else
        text, page = extract_cre(ui)
    end
    if not text or text == "" then
        return nil, "no_text"
    end
    if #text < Extractor.MIN_CHARS then
        return nil, "too_short"
    end
    return {
        text = truncate_tail(text, max_chars),
        metadata = get_metadata(ui, page),
    }
end

return Extractor
