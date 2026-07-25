--[[
Translation, English source strings -> Portuguese.

The msgid IS the English text, so a missing entry degrades to English rather
than to a key like "screen.header.close". (An earlier attempt had this backwards
- the table was keyed on English while every call site passed Portuguese, so it
never matched and the app was simply Portuguese.)

Language is "auto", "pt" or "en", persisted by the controller and switchable in
the settings dialog. Under "auto" we read the environment and fall back to
Portuguese, which is what the device this was built for is set to.

IMPORTANT: never call t() while a module is loading. Constants built at load
time freeze the language that was active then, and switching would not take.
Call it inside the function that builds the widget.
]]--

local M = {}

local PT = {
    -- navigation / chrome
    ["Usage"] = "Uso",
    ["Models"] = "Modelos",
    ["5h"] = "5h",
    ["CLOSE"] = "FECHAR",
    ["LOGOUT"] = "SAIR",
    ["Log out and clear the stored token?"] = "Sair e apagar o token salvo?",
    ["Log out"] = "Sair",
    ["Cancel"] = "Cancelar",
    ["AUTO OFF"] = "AUTO OFF",
    ["AUTO %ds"] = "AUTO %ds",
    ["failed"] = "falhou",
    ["updated "] = "atualizado ",
    ["loading..."] = "carregando...",

    -- dashboard
    ["5 HOURS"] = "5 HORAS",
    ["WEEKLY"] = "SEMANAL",
    ["RESETS IN - "] = "RESETA EM - ",
    ["STATUS: "] = "STATUS: ",
    ["PEAK USE: %d%%"] = "MAIOR USO: %d%%",
    ["network error"] = "erro de rede",
    ["LIMITED"] = "LIMITADO",
    ["WARNING"] = "AVISO",
    ["now"] = "agora",

    -- models page
    ["N/A"] = "N/D",
    ["AUTH"] = "AUTH",
    ["NET"] = "REDE",
    ["ERROR "] = "ERRO ",
    ["OK %.1fs"] = "OK %.1fs",
    ["status.claude.com: no data"] = "status.claude.com: sem dados",
    ["Active incident - see status.claude.com"] = "Incidente ativo - veja status.claude.com",
    ["status.claude.com: OK - no incidents"] = "status.claude.com: OK - sem incidentes",
    ["Real API probe: 4 on open, 1 per cycle"] = "Sonda real na API: 4 na abertura, 1 por ciclo",

    -- trend page
    ["5H WINDOW"] = "JANELA DE 5H",
    ["real use + projection"] = "uso real + projecao",
    ["Exhausted - resets in "] = "Esgotado - reseta em ",
    ["Steady at this pace"] = "Uso estável neste ritmo",
    ["At this pace, exhausted %s (in %dm)"] = "Neste ritmo, esgota %s (em %dm)",
    ["Safe - ~%d%% at reset"] = "Seguro - ~%d%% no reset",
    ["Collecting data..."] = "Coletando dados...",

    -- settings dialog
    ["Settings"] = "Configurações",
    ["Off"] = "Off",
    ["Language"] = "Idioma",
    ["Login (web)"] = "Login (web)",
    ["Logout (clear token)"] = "Logout (apagar token)",
    ["Quit app"] = "Fechar app",

    -- messages
    ["Token cleared."] = "Token apagado.",
    ["Cancel"] = "Cancelar",
    ["Locked — enter your PIN."] = "Bloqueado — digite seu PIN.",
    ["Too many attempts — token wiped."] = "Tentativas demais — token apagado.",
    ["Wrong PIN."] = "PIN incorreto.",
    ["Encryption unavailable — cannot store."] = "Criptografia indisponível — não dá para guardar.",
    ["Create a 4-digit PIN"] = "Crie um PIN de 4 dígitos",
    ["Connect the Kindle to WiFi first."] = "Conecte o Kindle ao WiFi primeiro.",
    ["No network IP. Check WiFi."] = "Sem IP na rede. Verifique o WiFi.",
    ["Invalid token (rejected)."] = "Token inválido (recusado).",
    ["Log in first."] = "Faça login primeiro.",
    ["Wait %d s before changing again."] = "Espere %d s para mudar de novo.",
    ["no token"] = "sem token",
    ["no network"] = "sem rede",
    ["token expired"] = "token expirado",
    ["error "] = "erro ",

    -- login modal + the page it serves
    ["Login — scan on your phone"] = "Login — escaneie no celular",
    ["paste the 'claude setup-token' value"] = "cole o valor do 'claude setup-token'",
    ["expires in 5 min • tap to cancel"] = "expira em 5 min • toque para cancelar",
    ["Claude Usage — send token"] = "Claude Usage — enviar token",
    ["On your PC run <code>claude setup-token</code>, copy the <code>sk-ant-oat01-...</code>, paste it below and enter the PIN shown on the Kindle."]
        = "No PC rode <code>claude setup-token</code>, copie o <code>sk-ant-oat01-...</code>, cole abaixo e digite o PIN mostrado no Kindle.",
    ["Token"] = "Token",
    ["PIN (4 digits)"] = "PIN (4 dígitos)",
    ["Submit"] = "Enviar",
    ["Token received. Return to the Kindle; you can close this page."]
        = "Token recebido. Volte ao Kindle; pode fechar esta página.",
    ["Empty token."] = "Token vazio.",
}

local WEEKDAYS = {
    en = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" },
    pt = { "DOM", "SEG", "TER", "QUA", "QUI", "SEX", "SÁB" },
}

local current = "pt"

local function detect()
    local env = os.getenv("LANGUAGE") or os.getenv("LC_ALL") or os.getenv("LANG") or ""
    if env:lower():match("^en") then return "en" end
    return "pt"   -- the device this ships for; also what "no answer" should mean
end

-- code: "auto" | "pt" | "en"
function M.setLang(code)
    if code == "en" or code == "pt" then
        current = code
    else
        current = detect()
    end
    return current
end

function M.lang() return current end

function M.weekdays() return WEEKDAYS[current] or WEEKDAYS.en end

function M.t(s)
    if current == "en" then return s end
    return PT[s] or s
end

M.setLang("auto")

return M
