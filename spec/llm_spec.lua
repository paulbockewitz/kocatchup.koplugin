local H = require("helper")
local Llm = require("kocatchup_llm")
local OpenAI = require("kocatchup_llm_openai")
local Anthropic = require("kocatchup_llm_anthropic")
local Json = require("kocatchup_json")
local Settings = require("kocatchup_settings")

local prompt = { system = "SYS", user = "USER" }

describe("kocatchup_llm_openai", function()
    before_each(function() H.reset() end)

    it("builds a chat-completions request with auth header", function()
        local req = OpenAI.build_request(
            { provider = "openai", base_url = "", model = "gpt-4o-mini", api_key = "sk-test" },
            prompt)
        assert.are.equal("https://api.openai.com/v1/chat/completions", req.url)
        assert.are.equal("Bearer sk-test", req.headers["Authorization"])
        local body = Json.decode(req.body)
        assert.are.equal("gpt-4o-mini", body.model)
        assert.are.equal("system", body.messages[1].role)
        assert.are.equal("SYS", body.messages[1].content)
        assert.are.equal("USER", body.messages[2].content)
    end)

    it("handles trailing slashes in custom base URLs and omits empty auth", function()
        local req = OpenAI.build_request(
            { base_url = "http://localhost:11434/v1/", model = "llama3", api_key = "" },
            prompt)
        assert.are.equal("http://localhost:11434/v1/chat/completions", req.url)
        assert.is_nil(req.headers["Authorization"])
    end)

    it("requires a key for the default endpoint but not for custom endpoints", function()
        assert.are.equal("no_api_key",
            OpenAI.check_config({ api_key = "", base_url = "" }))
        assert.are.equal("no_api_key",
            OpenAI.check_config({ api_key = "", base_url = OpenAI.DEFAULT_BASE_URL }))
        assert.is_nil(OpenAI.check_config({ api_key = "", base_url = "http://localhost:11434/v1" }))
        assert.is_nil(OpenAI.check_config({ api_key = "sk", base_url = "" }))
    end)

    it("parses the recap from choices[1].message.content", function()
        local decoded = Json.decode('{"choices":[{"message":{"content":"Recap!"}}]}')
        assert.are.equal("Recap!", OpenAI.parse_response(decoded))
        assert.is_nil(OpenAI.parse_response({ choices = {} }))
        assert.is_nil(OpenAI.parse_response({}))
    end)
end)

describe("kocatchup_llm_anthropic", function()
    before_each(function() H.reset() end)

    it("builds a messages request with anthropic headers", function()
        local req = Anthropic.build_request(
            { model = "claude-haiku-4-5", api_key = "ak-test", base_url = "" },
            prompt)
        assert.are.equal("https://api.anthropic.com/v1/messages", req.url)
        assert.are.equal("ak-test", req.headers["x-api-key"])
        assert.is_not_nil(req.headers["anthropic-version"])
        local body = Json.decode(req.body)
        assert.are.equal("SYS", body.system)
        assert.are.equal("USER", body.messages[1].content)
        assert.truthy(body.max_tokens > 0)
    end)

    it("always requires an API key", function()
        assert.are.equal("no_api_key", Anthropic.check_config({ api_key = "" }))
        assert.is_nil(Anthropic.check_config({ api_key = "ak" }))
    end)

    it("parses the recap from content[1].text", function()
        local decoded = Json.decode('{"content":[{"type":"text","text":"Recap!"}]}')
        assert.are.equal("Recap!", Anthropic.parse_response(decoded))
        assert.is_nil(Anthropic.parse_response({ content = {} }))
    end)
end)

describe("kocatchup_llm.complete", function()
    local cfg_ok = { provider = "openai", base_url = "http://localhost:11434/v1",
        model = "llama3", api_key = "" }

    before_each(function()
        H.reset()
        Llm.transport = nil
    end)

    it("returns no_api_key without calling the transport", function()
        local called = false
        Llm.transport = function() called = true return "{}", 200 end
        local result = Llm.complete(
            { provider = "openai", base_url = "", api_key = "", model = "m" }, prompt)
        assert.is_false(result.ok)
        assert.are.equal("no_api_key", result.err)
        assert.is_false(called)
    end)

    it("maps HTTP status codes to http_error with the code", function()
        for _, code in ipairs({ 401, 429, 500 }) do
            Llm.transport = function() return '{"error":"nope"}', code end
            local result = Llm.complete(cfg_ok, prompt)
            assert.is_false(result.ok)
            assert.are.equal("http_error", result.err)
            assert.are.equal(code, result.code)
        end
    end)

    it("maps malformed JSON to bad_response", function()
        Llm.transport = function() return "not json {", 200 end
        local result = Llm.complete(cfg_ok, prompt)
        assert.are.equal("bad_response", result.err)
    end)

    it("maps an unexpected-but-valid JSON shape to bad_response", function()
        Llm.transport = function() return '{"unexpected":true}', 200 end
        local result = Llm.complete(cfg_ok, prompt)
        assert.are.equal("bad_response", result.err)
    end)

    it("maps transport timeouts and TLS failures to typed errors", function()
        Llm.transport = function() return nil, "timeout" end
        assert.are.equal("timeout", Llm.complete(cfg_ok, prompt).err)
        Llm.transport = function() return nil, "certificate verify failed" end
        assert.are.equal("tls_error", Llm.complete(cfg_ok, prompt).err)
    end)

    it("returns the recap on success", function()
        Llm.transport = function(req)
            assert.are.equal("http://localhost:11434/v1/chat/completions", req.url)
            return '{"choices":[{"message":{"content":"A recap"}}]}', 200
        end
        local result = Llm.complete(cfg_ok, prompt)
        assert.is_true(result.ok)
        assert.are.equal("A recap", result.recap)
    end)
end)

describe("kocatchup_settings", function()
    before_each(function() H.reset() end)

    it("returns defaults when nothing is saved", function()
        local cfg = Settings.load()
        assert.are.equal("openai", cfg.provider)
        assert.are.equal("standard", cfg.recap_length)
        assert.are.equal(100000, cfg.max_input_chars)
        assert.is_false(cfg.auto_offer)
        assert.are.equal(3, cfg.auto_offer_days)
    end)

    it("round-trips saved values merged over defaults", function()
        local cfg = Settings.load()
        cfg.provider = "anthropic"
        cfg.api_key = "ak"
        Settings.save(cfg)
        local reloaded = Settings.load()
        assert.are.equal("anthropic", reloaded.provider)
        assert.are.equal("ak", reloaded.api_key)
        assert.are.equal("standard", reloaded.recap_length)
    end)

    it("flags plain HTTP to remote hosts as insecure, but not localhost or HTTPS", function()
        assert.is_true(Settings.is_insecure_url("http://example.com/v1"))
        assert.is_true(Settings.is_insecure_url("HTTP://api.example.com"))
        assert.is_false(Settings.is_insecure_url("http://localhost:11434/v1"))
        assert.is_false(Settings.is_insecure_url("http://127.0.0.1:8080"))
        assert.is_false(Settings.is_insecure_url("https://example.com"))
        assert.is_false(Settings.is_insecure_url(""))
        assert.is_false(Settings.is_insecure_url(nil))
    end)
end)
