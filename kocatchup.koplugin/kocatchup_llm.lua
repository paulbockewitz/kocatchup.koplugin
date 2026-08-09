-- Provider-agnostic completion layer. Handlers build requests and parse
-- responses synchronously; the caller decides where the blocking call runs
-- (main.lua wraps it in Trapper:dismissableRunInSubprocess).
local Json = require("kocatchup_json")

local Llm = {
    MAX_RESPONSE_BYTES = 5 * 1024 * 1024, -- cap on provider response bodies
    DEFAULT_TIMEOUT = 45,                 -- seconds
    LONG_TIMEOUT = 300,                   -- seconds, for large request bodies
    LONG_BODY_BYTES = 10240,
}

Llm.handlers = {
    openai = require("kocatchup_llm_openai"),
    anthropic = require("kocatchup_llm_anthropic"),
}

local function handler_for(cfg)
    return Llm.handlers[cfg.provider] or Llm.handlers.openai
end

-- Cheap local validation, safe to call before any network prompt.
-- Returns "no_api_key" or nil.
function Llm.check_config(cfg)
    return handler_for(cfg).check_config(cfg)
end

-- Injectable transport for tests: function(req) -> body, http_code | nil, err.
Llm.transport = nil

-- KOReader ships a CA bundle in its install directory; fall back to the
-- environment override used on desktop systems.
function Llm.find_ca_bundle()
    local candidates = {
        "./data/ca-bundle.crt",
        os.getenv("SSL_CERT_FILE"),
    }
    for _, path in ipairs(candidates) do
        if path then
            local f = io.open(path, "r")
            if f then
                f:close()
                return path
            end
        end
    end
    return nil
end

function Llm.default_transport(req)
    local ltn12 = require("ltn12")
    local is_https = req.url:lower():sub(1, 6) == "https:"
    local http = is_https and require("ssl.https") or require("socket.http")

    local chunks, total = {}, 0
    local sink = function(chunk)
        if chunk then
            total = total + #chunk
            if total > Llm.MAX_RESPONSE_BYTES then
                return nil, "response too large"
            end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end

    local headers = {}
    for k, v in pairs(req.headers or {}) do headers[k] = v end
    headers["Content-Length"] = tostring(#req.body)

    local reqt = {
        url = req.url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(req.body),
        sink = sink,
    }
    if is_https then
        reqt.protocol = "any"
        reqt.options = { "all", "no_sslv2", "no_sslv3" }
        local cafile = Llm.find_ca_bundle()
        if cafile then
            reqt.verify = "peer"
            reqt.cafile = cafile
        else
            -- No CA bundle found on this platform; connection is still TLS
            -- but unverified. Documented in the README.
            reqt.verify = "none"
        end
    end

    http.TIMEOUT = #req.body > Llm.LONG_BODY_BYTES
        and Llm.LONG_TIMEOUT or Llm.DEFAULT_TIMEOUT

    local ok, code_or_err = http.request(reqt)
    if not ok then
        return nil, tostring(code_or_err)
    end
    return table.concat(chunks), code_or_err
end

-- Runs one completion. Returns a plain (subprocess-serializable) table:
--   { ok = true, recap = <string> }
--   { ok = false, err = <type>, code = <http code, for http_error> }
-- Error types: no_api_key, timeout, tls_error, http_error, bad_response.
function Llm.complete(cfg, prompt)
    local handler = handler_for(cfg)
    local cerr = handler.check_config(cfg)
    if cerr then
        return { ok = false, err = cerr }
    end
    local req = handler.build_request(cfg, prompt)
    local transport = Llm.transport or Llm.default_transport
    local body, code_or_err = transport(req)
    if not body then
        local e = tostring(code_or_err or ""):lower()
        if e:find("timeout") or e:find("wantread") then
            return { ok = false, err = "timeout" }
        end
        if e:find("certificate") or e:find("verify") then
            return { ok = false, err = "tls_error" }
        end
        return { ok = false, err = "http_error", code = tostring(code_or_err) }
    end
    if code_or_err ~= 200 then
        return { ok = false, err = "http_error", code = code_or_err }
    end
    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return { ok = false, err = "bad_response" }
    end
    local recap = handler.parse_response(decoded)
    if type(recap) ~= "string" or recap == "" then
        return { ok = false, err = "bad_response" }
    end
    return { ok = true, recap = recap }
end

return Llm
