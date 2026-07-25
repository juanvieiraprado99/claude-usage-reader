--[[
ChaCha20 (RFC 8439) stream cipher for KOReader's LuaJIT (`bit` module).
Self-tested against the RFC 7539 §2.3.2 keystream vector at load; `chacha20.ok`
is false on mismatch (callers must fail closed).

    chacha20.crypt(key32, nonce12, counter, data) -> string (same length as data)
]]--

local bit = require("bit")
local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift
local rol = bit.rol

local function add(x, y) return band(x + y, 0xffffffff) end

local function le_word(s, i)   -- 1-based byte index
    local b1,b2,b3,b4 = s:byte(i, i + 3)
    return band(b1 + lshift(b2,8) + lshift(b3,16) + lshift(b4,24), 0xffffffff)
end

local function word_le(w)
    return string.char(band(w,0xff), band(rshift(w,8),0xff),
                       band(rshift(w,16),0xff), band(rshift(w,24),0xff))
end

local chacha20 = {}

local function qr(s, a, b, c, d)
    s[a] = add(s[a], s[b]); s[d] = rol(bxor(s[d], s[a]), 16)
    s[c] = add(s[c], s[d]); s[b] = rol(bxor(s[b], s[c]), 12)
    s[a] = add(s[a], s[b]); s[d] = rol(bxor(s[d], s[a]), 8)
    s[c] = add(s[c], s[d]); s[b] = rol(bxor(s[b], s[c]), 7)
end

local function block(key, nonce, counter)
    local s = {
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        le_word(key,1),  le_word(key,5),  le_word(key,9),  le_word(key,13),
        le_word(key,17), le_word(key,21), le_word(key,25), le_word(key,29),
        band(counter, 0xffffffff),
        le_word(nonce,1), le_word(nonce,5), le_word(nonce,9),
    }
    local w = {}
    for i = 1, 16 do w[i] = s[i] end
    for _ = 1, 10 do
        qr(w,1,5,9,13);  qr(w,2,6,10,14); qr(w,3,7,11,15); qr(w,4,8,12,16)
        qr(w,1,6,11,16); qr(w,2,7,12,13); qr(w,3,8,9,14);  qr(w,4,5,10,15)
    end
    local out = {}
    for i = 1, 16 do out[i] = word_le(add(w[i], s[i])) end
    return table.concat(out)
end

function chacha20.crypt(key, nonce, counter, data)
    local out = {}
    local pos = 1
    local n = #data
    while pos <= n do
        local ks = block(key, nonce, counter)
        counter = counter + 1
        local chunk = data:sub(pos, pos + 63)
        local t = {}
        for i = 1, #chunk do
            t[i] = string.char(bxor(chunk:byte(i), ks:byte(i)))
        end
        out[#out + 1] = table.concat(t)
        pos = pos + 64
    end
    return table.concat(out)
end

-- Self-test: RFC 7539 §2.3.2 keystream (key=00..1f, nonce=00 00 00 09 00 00 00 4a
-- 00 00 00 00, counter=1). First 16 keystream bytes are known.
local function selftest()
    local key = {}
    for i = 0, 31 do key[i + 1] = string.char(i) end
    key = table.concat(key)
    local nonce = string.char(0,0,0,9, 0,0,0,0x4a, 0,0,0,0)
    local ks = chacha20.crypt(key, nonce, 1, string.rep("\0", 16))
    local hex = ks:gsub(".", function(c) return string.format("%02x", c:byte()) end)
    return hex == "10f1e7e4d13b5915500fdd1fa32071c4"
end

chacha20.ok = selftest()

return chacha20
