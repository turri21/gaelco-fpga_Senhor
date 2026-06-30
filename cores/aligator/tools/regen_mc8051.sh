#!/bin/bash
# Regenera mc8051_regen.v (Verilog) desde el VHDL de Oregano via GHDL synth.
# Es el MISMO core mc8051 que usan WRally / thoop2 (DS5002FP); se incluye aquí por comodidad.
# Uso: bash regen_mc8051.sh [SRCDIR] [OUT.v]
#   SRCDIR = dir con los .vhd del 8051 (def: el de jtframe)
#   OUT    = fichero verilog de salida (def: el de este core)
set -e
SRC="${1:-/mnt/c/_PROYECTOS/Gaelco/jt_ref/jtcores/modules/jtframe/hdl/cpu/8051}"
OUT="${2:-/mnt/c/_PROYECTOS/gaelco-fpga/cores/aligator/hdl/mc8051_regen.v}"
W=/tmp/mc8051regen
rm -rf "$W"
mkdir -p "$W"
cd "$W"
cp "$SRC"/*.vhd .

# Orden de dependencias (= orden del yaml de jtframe): paquete -> hojas -> arriba
FILES="mc8051_p.vhd \
control_fsm_.vhd control_fsm_rtl.vhd control_fsm_rtl_cfg.vhd \
control_mem_.vhd control_mem_rtl.vhd control_mem_rtl_cfg.vhd \
alumux_.vhd alumux_rtl.vhd alumux_rtl_cfg.vhd \
alucore_.vhd alucore_rtl.vhd alucore_rtl_cfg.vhd \
addsub_cy_.vhd addsub_cy_rtl.vhd addsub_cy_rtl_cfg.vhd \
addsub_ovcy_.vhd addsub_ovcy_rtl.vhd addsub_ovcy_rtl_cfg.vhd \
addsub_core_.vhd addsub_core_struc.vhd addsub_core_struc_cfg.vhd \
comb_divider_.vhd comb_divider_rtl.vhd comb_divider_rtl_cfg.vhd \
comb_mltplr_.vhd comb_mltplr_rtl.vhd comb_mltplr_rtl_cfg.vhd \
dcml_adjust_.vhd dcml_adjust_rtl.vhd dcml_adjust_rtl_cfg.vhd \
mc8051_siu_.vhd mc8051_siu_rtl.vhd mc8051_siu_rtl_cfg.vhd \
mc8051_tmrctr_.vhd mc8051_tmrctr_rtl.vhd mc8051_tmrctr_rtl_cfg.vhd \
mc8051_alu_.vhd mc8051_alu_struc.vhd mc8051_alu_struc_cfg.vhd \
mc8051_control_.vhd mc8051_control_struc.vhd mc8051_control_struc_cfg.vhd \
mc8051_core_.vhd mc8051_core_struc.vhd mc8051_core_struc_cfg.vhd"

echo "=== ghdl -a (analyze, -fsynopsys) ==="
ghdl -a -fsynopsys $FILES
echo "=== ghdl synth --out=verilog mc8051_core ==="
ghdl synth -fsynopsys --out=verilog mc8051_core > "$OUT"
echo "=== OK: $(wc -l < "$OUT") lineas, $(grep -c '^module ' "$OUT") modulos ==="
grep -nE "module mc8051_core" "$OUT" | head
