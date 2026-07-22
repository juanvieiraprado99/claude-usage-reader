--[[
crypto.lua — token-at-rest encryption for the plugin.

Confidentiality-only (no MAC, by design — the goal is that the token can't be
READ off the device without the PIN; tampering just corrupts the blob):
  key   = iterated SHA-256 of (salt .. pin)          (slow-ish KDF)
  check = SHA-256(key .. "cu-verify")                (PIN verifier; wrong PIN -> mismatch)
  ct    = ChaCha20(key, nonce) XOR token
The PIN is never stored. All binary fields are base64 so the blob is ascii-safe
for LuaSettings.

HONEST CAVEAT: a 4-digit PIN is only 10,000 keys. The KDF slows on-device
guessing and the caller wipes after N wrong tries, but anyone who copies the blob
can brute-force 4 digits offline on a fast machine. Encryption defeats casual
file reading and anyone without the PIN — not a determined attacker with the file.
]]--

local sha256 = require("sha256")
local chacha20 = require("chacha20")

local M = {}

local DEFAULT_ITERS = 1500   -- KDF rounds (tune for ~150ms on the device)

function M.available()
    return sha256.ok == true and chacha20.ok == true
end

-- base64 -------------------------------------------------------------------
local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64enc(data)
    return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end
local function b64dec(data)
    data = data:gsub("[^" .. B .. "=]", "")
    return (data:gsub("=", ""):gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

-- randomness ---------------------------------------------------------------
function M.random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local b = f:read(n)
        f:close()
        if b and #b == n then return b end
    end
    -- fallback (weaker): seed once and draw
    math.randomseed(os.time() + os.clock() * 1000)
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

-- KDF ----------------------------------------------------------------------
local function kdf(pin, salt, iters)
    local k = sha256.bytes(salt .. pin)
    for _ = 1, iters do k = sha256.bytes(k .. pin) end
    return k
end

-- API ----------------------------------------------------------------------
-- Returns a blob table, or nil if crypto is unavailable.
function M.encrypt(plain, pin)
    if not M.available() then return nil end
    local salt = M.random_bytes(16)
    local nonce = M.random_bytes(12)
    local iters = DEFAULT_ITERS
    local key = kdf(pin, salt, iters)
    local check = sha256.bytes(key .. "cu-verify")
    local ct = chacha20.crypt(key, nonce, 1, plain)
    return {
        v = 1,
        salt = b64enc(salt),
        nonce = b64enc(nonce),
        iters = iters,
        check = b64enc(check),
        ct = b64enc(ct),
    }
end

-- Returns the plaintext token, or nil on wrong PIN / bad blob.
function M.decrypt(blob, pin)
    if not M.available() or type(blob) ~= "table" then return nil end
    local ok, salt = pcall(b64dec, blob.salt or "")
    if not ok then return nil end
    local key = kdf(pin, salt, blob.iters or DEFAULT_ITERS)
    if b64enc(sha256.bytes(key .. "cu-verify")) ~= blob.check then
        return nil   -- wrong PIN
    end
    local nonce = b64dec(blob.nonce or "")
    local ct = b64dec(blob.ct or "")
    return chacha20.crypt(key, nonce, 1, ct)
end

return M
