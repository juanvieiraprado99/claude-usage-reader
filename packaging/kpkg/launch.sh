#!/bin/sh
#
# KPM launch hook (`kpm launch claudeusage`). Runs from inside the unpacked
# package directory, so the launcher is reachable relative to here.

exec sh bin/claudeusage.sh
