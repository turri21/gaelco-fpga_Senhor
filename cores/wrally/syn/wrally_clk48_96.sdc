# wrally_clk48_96.sdc — multicycle para el cruce clk48 <-> clk96.
#
# CONTEXTO: con JTFRAME_SDRAM96 el `clk` del GAMETOP es clk96 (los slots SDRAM y las BRAM
# del GAMETOP -p.ej. wrdallas- corren a clk96). NOSOTROS corremos la logica del juego a
# clk48 (jtwrally_game: clkg=clk48). Eso crea cruces clk48<->clk96 (p.ej. wram_mcu[clk48]
# -> wrdallas PROM[clk96]) que jtframe NO constrina (los cores estandar corren el game a
# clk96, sin este cruce). Sin constraint, TimeQuest los analiza a 1 ciclo de clk96 (10.4ns)
# y fallan (setup slack -1.154).
#
# clk48 = clk96/2 EN FASE (misma PLL). Un dato lanzado en clk48 es estable 2 ciclos de clk96
# -> setup multicycle 2, hold 1 (relacion 2:1 estandar). Es CORRECTO y seguro (el dato existe
# ese tiempo). Cierra el cruce con holgura sin tocar el RTL (fx68k sigue relajado a clk48).

set CLK48 {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set CLK96 {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}

# clk48 -> clk96
set_multicycle_path -from [get_clocks $CLK48] -to [get_clocks $CLK96] -setup -end 2
set_multicycle_path -from [get_clocks $CLK48] -to [get_clocks $CLK96] -hold  -end 1
# clk96 -> clk48
set_multicycle_path -from [get_clocks $CLK96] -to [get_clocks $CLK48] -setup -end 2
set_multicycle_path -from [get_clocks $CLK96] -to [get_clocks $CLK48] -hold  -end 1

# El VU-meter del OSD (jtframe_vumeter) lee el audio del OKI (cruce clk48->clk96). Es DISPLAY
# del OSD, timing IRRELEVANTE -> false_path (los 5 peores hold paths -0.411 son todos aqui;
# cosmetico, no afecta al juego). Cierra el hold sin afectar nada funcional.
set_false_path -to [get_registers {*jtframe_vumeter*}]

# === mc8051 (DS5002): multicycle de los paths internos del core (2026-06-19) ===
# El core Oregano (mc8051_core u_core, Verilog ghdl-flattened) tiene logica combinacional MUY
# profunda (ALU/control). Corre a clk48 pero es CEN-PACED: avanza solo en cen_eff = clk48/4/12
# (= cada 48 ciclos de clk48). Sin constraint, TimeQuest analiza sus paths a 1 ciclo (20.8ns) y
# FALLAN (worst setup slack -8.068, TNS -2785ns en clk48). Pero el dato real existe ~48 ciclos
# -> son MULTICICLO. Cualquier path lanzado desde un registro de u_core (o capturado en el) es
# seguro relajar: la condicion enable garantiza >=48 ciclos entre actualizaciones. Multicycle 4
# (83ns) cierra con holgura (paths ~29ns) sin tocar el RTL. Mismo principio que el cruce 48<->96
# de arriba y que el multicycle del r8051 anterior. NO afecta a la frontera (wram/ROM): esos
# registros del wrapper (rom_addr_r/x_addr_r/rom_data_q/xdata_din_q) NO llevan *u_core* en su ruta.
set_multicycle_path -from [get_registers {*u_core*}] -setup -end 4
set_multicycle_path -from [get_registers {*u_core*}] -hold  -end 3
set_multicycle_path -to   [get_registers {*u_core*}] -setup -end 4
set_multicycle_path -to   [get_registers {*u_core*}] -hold  -end 3
