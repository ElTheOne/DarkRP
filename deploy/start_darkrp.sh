#!/bin/sh
set -eu

server_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$server_dir"

exec ./srcds_run_x64 \
	-game garrysmod \
	-console \
	-insecure \
	-nohltv \
	-strictportbind \
	-ip 0.0.0.0 \
	-port 27015 \
	+hostname "DarkRP Foundation" \
	+map rp_downtown_fade_v3 \
	+maxplayers 128 \
	+gamemode darkrp \
	+sv_cheats 1 \
	+exec server.cfg \
	+sv_lan 1
