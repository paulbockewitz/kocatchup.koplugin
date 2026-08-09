-- Real-provider integration check (DoD gate): generates an actual recap
-- against a live Ollama server through the plugin's real provider layer
-- (kocatchup_prompts prompt build, kocatchup_llm_openai request build, kocatchup_llm.complete
-- response parsing). Only the socket layer is swapped for curl, since
-- luasocket ships inside KOReader, not with stock LuaJIT.
--
-- Usage:  luajit spec/integration_ollama.lua [model]
-- Requires: an Ollama server on http://localhost:11434 with the model pulled.
package.path = "./kocatchup.koplugin/?.lua;" .. package.path

local Llm = require("kocatchup_llm")
local Prompts = require("kocatchup_prompts")

-- Defaults target local Ollama; override via env to hit a cloud endpoint:
--   KOC_PROVIDER=openai|anthropic  KOC_BASE_URL=...  KOC_MODEL=...  KOC_API_KEY=...
-- e.g. Groq:  KOC_BASE_URL=https://api.groq.com/openai/v1  KOC_MODEL=llama-3.1-8b-instant  KOC_API_KEY=$GROQ_API_KEY
local model = os.getenv("KOC_MODEL") or select(1, ...) or "qwen2.5:0.5b"

-- curl-backed transport with the same contract as Llm.default_transport:
-- (req) -> body, http_code | nil, err
local function curl_transport(req)
    local body_file = os.tmpname()
    local resp_file = os.tmpname()
    local f = io.open(body_file, "wb")
    f:write(req.body)
    f:close()
    local header_args = {}
    for k, v in pairs(req.headers or {}) do
        header_args[#header_args + 1] = string.format('-H "%s: %s"', k, v)
    end
    local cmd = string.format(
        'curl -s -o "%s" -w "%%{http_code}" -X POST %s --data-binary "@%s" --max-time 300 "%s"',
        resp_file, table.concat(header_args, " "), body_file, req.url)
    local pipe = io.popen(cmd)
    local status = pipe:read("*a")
    pipe:close()
    local rf = io.open(resp_file, "rb")
    local body = rf and rf:read("*a") or nil
    if rf then rf:close() end
    os.remove(body_file)
    os.remove(resp_file)
    local code = tonumber((status or ""):match("%d+"))
    if not code or code == 0 then
        return nil, "timeout"
    end
    return body, code
end

local sample_text = [[
Marta Kowalski had spent eleven years as the lighthouse keeper on Graywater
Island, and in all that time the light had never once failed. That changed on
the night the cargo ship Andromeda ran aground on the northern shoals. Marta
found a single survivor on the beach: a young engineer named Tomas, clutching
a waterproof case he refused to open. Over the following week, Marta nursed
Tomas back to health while winter storms cut the island off from the mainland.
Tomas eventually confessed that the case held navigation logs proving the
Andromeda's owners had ordered the captain to falsify the ship's route to
dodge an insurance inspection. Someone had disabled the lighthouse beacon
remotely that night, he said, and the wreck was no accident. Marta discovered
her radio transmitter had been sabotaged too, its crystal removed. The only
other person on the island was Henrik, the taciturn supply-boat pilot who had
arrived the morning after the wreck, claiming engine trouble. Marta began
keeping a knife in her boot. Last night she caught Henrik searching the
infirmary while Tomas slept, and now she is standing in the lamp room,
watching Henrik's silhouette climb the spiral stairs toward her.
]]

local cfg = {
    provider = os.getenv("KOC_PROVIDER") or "openai",
    base_url = os.getenv("KOC_BASE_URL") or "http://localhost:11434/v1",
    model = model,
    api_key = os.getenv("KOC_API_KEY") or "",
    recap_length = "short",
}

print("Model: " .. model)
local prompt = Prompts.build(
    { title = "The Graywater Light", authors = "Test Fixture", chapter = "Chapter 9" },
    sample_text, cfg.recap_length)

Llm.transport = curl_transport
local started = os.time()
local result = Llm.complete(cfg, prompt)
local elapsed = os.time() - started

if not result.ok then
    print(string.format("FAILED: err=%s code=%s (%ds)",
        tostring(result.err), tostring(result.code), elapsed))
    os.exit(1)
end
assert(type(result.recap) == "string" and #result.recap > 50,
    "recap implausibly short: " .. tostring(result.recap))
print(string.format("OK: real recap generated in %ds (%d chars)", elapsed, #result.recap))
print("---- recap ----")
print(result.recap)
os.exit(0)
