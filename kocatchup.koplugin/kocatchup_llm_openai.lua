-- OpenAI-compatible chat-completions handler. Covers OpenAI, OpenRouter,
-- Groq, and self-hosted Ollama via a configurable base URL.
local Json = require("kocatchup_json")

local OpenAI = {
    DEFAULT_BASE_URL = "https://api.openai.com/v1",
}

-- Returns "no_api_key" when the config cannot make a request, else nil.
-- Self-hosted exception: a custom base URL (e.g. Ollama) may not need a key.
function OpenAI.check_config(cfg)
    local key = cfg.api_key or ""
    local base = cfg.base_url or ""
    if key == "" and (base == "" or base == OpenAI.DEFAULT_BASE_URL) then
        return "no_api_key"
    end
    return nil
end

function OpenAI.build_request(cfg, prompt)
    local base = (cfg.base_url and cfg.base_url ~= "") and cfg.base_url
        or OpenAI.DEFAULT_BASE_URL
    base = base:gsub("/+$", "")
    local headers = { ["Content-Type"] = "application/json" }
    if cfg.api_key and cfg.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. cfg.api_key
    end
    local body = Json.encode({
        model = cfg.model,
        messages = {
            { role = "system", content = prompt.system },
            { role = "user", content = prompt.user },
        },
    })
    return { url = base .. "/chat/completions", headers = headers, body = body }
end

-- Returns the recap text, or nil when the response shape is unexpected.
function OpenAI.parse_response(decoded)
    local choices = decoded and decoded.choices
    if type(choices) == "table" and type(choices[1]) == "table" then
        local msg = choices[1].message
        if type(msg) == "table" and type(msg.content) == "string" then
            return msg.content
        end
    end
    return nil
end

return OpenAI
