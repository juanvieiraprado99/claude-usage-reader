--[[
Accounts — the list of Claude accounts whose quota the app can show.

One record per account, each with its OWN encrypted token, its OWN PIN and its
OWN history file:

  { id = "a1", name = "Work", enc = <crypto blob>, pin_fail = 0,
    hist = "claudeusage_history.lua" }

Persisted in the app's settings file under `accounts`, alongside
`active_account` (an id) and `account_seq` (the id counter).

Why each field is the way it is:

  name      may be nil. It renders as T("Account %d") at build time, never at
            store time: a translated string written to disk would freeze the
            language, the same trap navLabels() documents in screenbase.lua.
  hist      is STORED, not derived from the id. The account migrated from a
            single-account install has to keep pointing at the existing
            claudeusage_history.lua, and an explicit field beats a special case
            in a path rule that every future reader would have to remember.
  pin_fail  is per account, so 8 wrong PINs wipe the account under attack and
            leave the others alone.
  seq       only ever grows; ids are never reused. That is what guarantees a
            deleted account's leftover history file can never be adopted by a
            later one.

:remove() deletes the record only — the history file stays on disk. Deleting it
would mean logging out silently destroys days of collected samples, and since
ids are never reused an orphan file can never contaminate anything. It is dead
weight measured in kilobytes; losing the data is not recoverable.

This module owns the list and nothing else: no UI, no crypto. crypto.lua is
already blob-agnostic (encrypt/decrypt take and return one blob), so multiple
accounts cost it nothing.
]]--

local i18n = require("i18n")
local T = i18n.t

local Accounts = {}
Accounts.__index = Accounts

-- Enough for work + personal + a couple of clients. The cap exists so the
-- switcher dialog stays a glanceable list on a 6" screen.
local MAX_ACCOUNTS = 5
Accounts.MAX_ACCOUNTS = MAX_ACCOUNTS

-- The history file a single-account install already has. The migrated account
-- keeps it, so nobody loses their week of samples on upgrade.
local LEGACY_HIST = "claudeusage_history.lua"
Accounts.LEGACY_HIST = LEGACY_HIST

-- Build the list from settings, migrating a single-account install on the way.
-- `settings` is the app's LuaSettings handle; `data_dir` is where history files
-- live (both come from controller.lua).
function Accounts.new(settings, data_dir)
    local self = setmetatable({}, Accounts)
    self.settings = settings
    self.data_dir = data_dir
    self.accounts = settings:readSetting("accounts")
    self.active_id = settings:readSetting("active_account")
    self.seq = settings:readSetting("account_seq") or 0
    if not self.accounts then self:_migrate() end
    -- A stale active id (record removed by hand, half-written file) must not
    -- leave the app with no account at all when one is right there.
    if not self:byId(self.active_id) then
        self.active_id = self.accounts[1] and self.accounts[1].id or nil
    end
    return self
end

-- One-time upgrade from the single-token layout: settings held `enc` and
-- `pin_fail` at the top level. Older still: a plaintext `token`, which the
-- encrypted store already refused to read and which is dropped here for good.
function Accounts:_migrate()
    local enc = self.settings:readSetting("enc")
    self.accounts = {}
    if enc then
        self.seq = 1
        self.accounts[1] = {
            id = "a1",
            name = nil,   -- shown as "Account 1" until the user renames it
            enc = enc,
            pin_fail = self.settings:readSetting("pin_fail") or 0,
            hist = LEGACY_HIST,
        }
        self.active_id = "a1"
    end
    self.settings:delSetting("enc")
    self.settings:delSetting("pin_fail")
    self.settings:delSetting("token")
    self:_save()
end

function Accounts:_save()
    self.settings:saveSetting("accounts", self.accounts)
    self.settings:saveSetting("active_account", self.active_id)
    self.settings:saveSetting("account_seq", self.seq)
    self.settings:flush()
end

function Accounts:list()
    return self.accounts
end

function Accounts:count()
    return #self.accounts
end

function Accounts:byId(id)
    if not id then return nil end
    for _, a in ipairs(self.accounts) do
        if a.id == id then return a end
    end
    return nil
end

-- Position in the list, used for the "Account %d" fallback label.
function Accounts:indexOf(id)
    for i, a in ipairs(self.accounts) do
        if a.id == id then return i end
    end
    return nil
end

function Accounts:active()
    return self:byId(self.active_id)
end

-- Display name. T() is called HERE and not at store time, so switching the
-- language relabels an unnamed account instead of leaving the old wording.
function Accounts:label(acct)
    if not acct then return "" end
    if acct.name and acct.name ~= "" then return acct.name end
    return string.format(T("Account %d"), self:indexOf(acct.id) or 1)
end

-- Append an account holding an already-encrypted blob and make it active.
-- Returns the record, or nil when the cap is reached.
function Accounts:add(name, blob)
    if #self.accounts >= MAX_ACCOUNTS then return nil end
    self.seq = self.seq + 1
    local id = "a" .. self.seq
    local acct = {
        id = id,
        name = (name and name ~= "") and name or nil,
        enc = blob,
        pin_fail = 0,
        -- The first account ever created lands on the legacy filename, so a
        -- fresh install and a migrated one end up with the same layout.
        hist = (self.seq == 1) and LEGACY_HIST
               or ("claudeusage_history_" .. id .. ".lua"),
    }
    table.insert(self.accounts, acct)
    self.active_id = id
    self:_save()
    return acct
end

function Accounts:setActive(id)
    if not self:byId(id) then return false end
    self.active_id = id
    self:_save()
    return true
end

-- Replace an account's token blob, keeping its name, its history and its place
-- in the list. This is the re-login path (token expired), not a new account.
function Accounts:setEnc(id, blob)
    local acct = self:byId(id)
    if not acct then return false end
    acct.enc = blob
    acct.pin_fail = 0
    self:_save()
    return true
end

function Accounts:setPinFail(id, n)
    local acct = self:byId(id)
    if not acct then return false end
    acct.pin_fail = n
    self:_save()
    return true
end

-- Drop the record. The history file is deliberately left behind (see header).
-- If the removed account was active, the first remaining one takes over.
function Accounts:remove(id)
    local idx = self:indexOf(id)
    if not idx then return false end
    table.remove(self.accounts, idx)
    if self.active_id == id then
        self.active_id = self.accounts[1] and self.accounts[1].id or nil
    end
    self:_save()
    return true
end

-- Where this account's samples live. Falls back to the legacy filename when
-- there is no account yet, so History always has a path to open.
function Accounts:histPath(acct)
    local name = (acct and acct.hist) or LEGACY_HIST
    return self.data_dir .. "/" .. name
end

return Accounts
