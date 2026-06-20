#!/bin/bash
set -e
GIT=/mnt/c/_PROYECTOS/Gaelco/jt_ref/jtcores
SRC=$GIT/modules/jtframe/hdl/cpu/8051
W=/tmp/mc8051ctrl
rm -rf "$W"; mkdir -p "$W"; cd "$W"
# restaurar VHDL original 8051 desde git (descarta mi 8052) en una copia local
cp "$SRC"/*.vhd .
cd "$GIT" && git stash list >/dev/null 2>&1 || true
cd "$W"
# revertir SOLO el cambio 8052 con git show del HEAD (los .vhd no estaban trackeados? jt_ref es untracked)
echo "(uso la copia actual; el control real se hace abajo con git checkout)"
