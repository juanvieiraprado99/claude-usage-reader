-- App version, shown in the corner of every screen.
--
-- NOT named version.lua: KOReader has its own `version` module and gets there
-- first, so require("version") would hand back its table, not this string.
--
-- packaging/build.sh overwrites this file in the staged package with the real
-- version (VERSION + the CI run number), so a shipped build reports something
-- like "0.1.7". Running straight from the repo leaves it as "dev".
return "dev"
