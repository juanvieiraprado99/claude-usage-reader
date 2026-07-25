--[[
SHA-256 for KOReader's LuaJIT (uses the `bit` module). Standard FIPS-180-4
algorithm. Self-tested against known vectors at load; `sha256.ok` is false if a
vector mismatches (callers must fail closed and never fall back to plaintext).

    sha256.bytes(str) -> 32-byte binary digest
    sha256.hex(str)   -> 64-char lowercase hex
]]--

local bit = require("bit")
local band, bxor = bit.band, bit.bxor
local rshift, lshift = bit.rshift, bit.lshift
local ror = bit.ror

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function add32(a, b, c, d, e)
    local s = a + b
    if c then s = s + c end
    if d then s = s + d end
    if e then s = s + e end
    return band(s, 0xffffffff)
end

local sha256 = {}

local function digest_words(msg)
    -- padding
    local len = #msg
    local bitlen = len * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do msg = msg .. "\0" end
    -- 64-bit length, big-endian (bitlen < 2^53, high word from float math)
    local hi = math.floor(bitlen / 0x100000000)
    local lo = bitlen % 0x100000000
    local function w2b(w)
        return string.char(band(rshift(w, 24), 0xff), band(rshift(w, 16), 0xff),
                           band(rshift(w, 8), 0xff), band(w, 0xff))
    end
    msg = msg .. w2b(band(hi, 0xffffffff)) .. w2b(band(lo, 0xffffffff))

    local h0,h1,h2,h3 = 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a
    local h4,h5,h6,h7 = 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

    local W = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local p = chunk + i * 4
            local b1,b2,b3,b4 = msg:byte(p, p + 3)
            W[i] = band(lshift(b1,24), 0xffffffff) + lshift(b2,16) + lshift(b3,8) + b4
            W[i] = band(W[i], 0xffffffff)
        end
        for i = 16, 63 do
            local w15, w2 = W[i-15], W[i-2]
            local s0 = bxor(ror(w15,7), ror(w15,18), rshift(w15,3))
            local s1 = bxor(ror(w2,17), ror(w2,19), rshift(w2,10))
            W[i] = add32(W[i-16], s0, W[i-7], s1)
        end
        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 0, 63 do
            local S1 = bxor(ror(e,6), ror(e,11), ror(e,25))
            local ch = bxor(band(e,f), band(bit.bnot(e), g))
            local t1 = add32(h, S1, ch, K[i+1], W[i])
            local S0 = bxor(ror(a,2), ror(a,13), ror(a,22))
            local maj = bxor(band(a,b), band(a,c), band(b,c))
            local t2 = add32(S0, maj)
            h=g; g=f; f=e; e=add32(d,t1); d=c; c=b; b=a; a=add32(t1,t2)
        end
        h0=add32(h0,a); h1=add32(h1,b); h2=add32(h2,c); h3=add32(h3,d)
        h4=add32(h4,e); h5=add32(h5,f); h6=add32(h6,g); h7=add32(h7,h)
    end
    return { h0,h1,h2,h3,h4,h5,h6,h7 }
end

function sha256.bytes(msg)
    local w = digest_words(msg)
    local out = {}
    for i = 1, 8 do
        local x = w[i]
        out[i] = string.char(band(rshift(x,24),0xff), band(rshift(x,16),0xff),
                             band(rshift(x,8),0xff), band(x,0xff))
    end
    return table.concat(out)
end

function sha256.hex(msg)
    return (sha256.bytes(msg):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Self-test against FIPS-180 vectors.
sha256.ok = (sha256.hex("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    and (sha256.hex("")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

return sha256
