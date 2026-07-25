--[[
Tiny i18n for the plugin: English (canonical msgids) + Portuguese, chosen from
KOReader's language setting. Not tied to KOReader's gettext catalog (our strings
aren't in it), so we keep our own table.

    local T = require("i18n").t
    T("Show usage")            -- "Ver uso" when KOReader is in Portuguese
    T("Token received (%d chars).")  -- still a template; string.format at call site
]]--

local M = {}

-- msgid (English) -> Portuguese
local PT = {
    -- main.lua
    ["Show Claude usage"] = "Mostrar uso do Claude",
    ["Show usage"] = "Ver uso",
    ["Login (web)"] = "Login (web)",
    ["Connect the Kindle to WiFi first."] = "Conecte o Kindle ao WiFi primeiro.",
    ["No network IP. Check WiFi."] = "Sem IP de rede. Verifique o WiFi.",
    ["Token received (%d chars)."] = "Token recebido (%d chars).",
    ["No token. Use 'Login (web)'."] = "Sem token. Use 'Login (web)'.",
    ["Request failed: "] = "Falha na requisição: ",
    ["token expired"] = "token expirado",
    ["Wait %d s before changing again."] = "Aguarde %d s para mudar de novo.",
    ["Cancel"] = "Cancelar",
    ["Logout (clear token)"] = "Logout (limpar token)",
    ["Token cleared."] = "Token apagado.",
    ["Create a 4-digit PIN"] = "Crie um PIN de 4 dígitos",
    ["Locked — enter your PIN."] = "Bloqueado — digite seu PIN.",
    ["Wrong PIN."] = "PIN incorreto.",
    ["Too many attempts — token wiped."] = "Tentativas demais — token apagado.",
    ["Please log in first."] = "Faça login primeiro.",
    ["Invalid token (rejected)."] = "Token inválido (rejeitado).",
    ["Encryption unavailable — cannot store."] = "Criptografia indisponível — não dá para salvar.",
    -- usagescreen.lua
    ["now"] = "agora",
    ["RESETS AT "] = "RESETA EM ",
    ["5 HOURS"] = "5 HORAS",
    ["WEEK"] = "SEMANA",
    ["updated now"] = "atualizado agora",
    ["loading..."] = "carregando...",
    ["failed"] = "falha",
    ["network error"] = "erro de rede",
    ["LIMITED"] = "LIMITADO",
    ["WARNING"] = "ATENÇÃO",
    ["auto: off"] = "auto: off",
    ["auto: %ds"] = "auto: %ds",
    ["X Close"] = "X Fechar",
    [" (tap)"] = " (toque)",
    ["Rotate"] = "Girar",
    -- loginmodal.lua
    ["Login — scan on your phone"] = "Login — escaneie no celular",
    ["paste the 'claude setup-token' value"] = "cole o token do 'claude setup-token'",
    ["expires in 5 min • tap to cancel"] = "expira em 5 min • toque para cancelar",
    -- tokenserver.lua (served form)
    ["Claude Usage — send token"] = "Claude Usage — enviar token",
    ["On your PC run <code>claude setup-token</code>, copy the <code>sk-ant-oat01-...</code>, paste it below and enter the PIN shown on the Kindle."]
        = "No PC rode <code>claude setup-token</code>, copie o <code>sk-ant-oat01-...</code>, cole abaixo e digite o PIN mostrado no Kindle.",
    ["Token"] = "Token",
    ["PIN (4 digits)"] = "PIN (4 dígitos)",
    ["Submit"] = "Enviar",
    ["Wrong PIN."] = "PIN incorreto.",
    ["Empty token."] = "Token vazio.",
    ["Token received. Return to the Kindle; you can close this page."]
        = "Token recebido. Volte ao Kindle; pode fechar esta página.",
}

local function detect_pt()
    local lang
    local grs = rawget(_G, "G_reader_settings")
    if grs and grs.readSetting then lang = grs:readSetting("language") end
    lang = lang or os.getenv("LANGUAGE") or os.getenv("LANG") or "en"
    return tostring(lang):lower():sub(1, 2) == "pt"
end

local is_pt = detect_pt()

-- Re-check the language (KOReader can change it at runtime).
function M.refresh() is_pt = detect_pt() end

function M.t(s)
    if is_pt then return PT[s] or s end
    return s
end

return M
