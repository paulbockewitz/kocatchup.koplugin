-- Anthropic messages-API handler.
local Json = require("kocatchup_json")

local Anthropic = {
    DEFAULT_BASE_URL = "https://api.anthropic.com",
    API_VERSION = "2023-06-01",
    MAX_TOKENS = 2048,
}

function Anthropic.check_config(cfg)
    if not cfg.api_key or cfg.api_key == "" then
        return "no_api_key"
    end
    return nil
end

function Anthropic.build_request(cfg, prompt)
    local base = (cfg.base_url and cfg.base_url ~= "") and cfg.base_url
        or Anthropic.DEFAULT_BASE_URL
    base = base:gsub("/+$", "")
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = cfg.api_key,
        ["anthropic-version"] = Anthropic.API_VERSION,
    }
    local body = Json.encode({
        model = cfg.model,
        max_tokens = Anthropic.MAX_TOKENS,
        system = prompt.system,
        messages = {
            { role = "user", content = prompt.user },
        },
    })
    return { url = base .. "/v1/messages", headers = headers, body = body }
end

function Anthropic.parse_response(decoded)
    local content = decoded and decoded.content
    if type(content) == "table" and type(content[1]) == "table"
        and type(content[1].text) == "string" then
        return content[1].text
    end
    return nil
end

return Anthropic
