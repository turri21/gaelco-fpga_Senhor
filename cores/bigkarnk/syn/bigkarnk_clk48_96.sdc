# bigkarnk_clk48_96.sdc — multicycle del cruce clk48<->clk96.
# Big Karnak corre la logica del juego a clk48 (clkg=clk48) y los slots SDRAM + BRAM del GAMETOP a
# clk96 (JTFRAME_SDRAM96). Los cruces clk48<->clk96 SIN constraint los analiza TimeQuest a 1 ciclo de
# clk96 (10.4 ns) -> el 1er build salio a -1.708 ns (worst-path en el dominio clk48 general[0]).
# clk48 = clk96/2 EN FASE (misma PLL jtframe_pllgame) -> multicycle setup 2 / hold 1 (relacion 2:1,
# correcto y seguro). = misma constraint que WRally/aligator/thoop2, PERO Big Karnak NO lleva mc8051
# (placa Unprotected sin DS5002), asi que NO se incluye la parte de multicycle del mc8051.

set CLK48  {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set CLK96A {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}
set CLK96B {emu|pll|pll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}

foreach C96 [list $CLK96A $CLK96B] {
    set_multicycle_path -from [get_clocks $CLK48] -to [get_clocks $C96] -setup -end 2
    set_multicycle_path -from [get_clocks $CLK48] -to [get_clocks $C96] -hold  -end 1
    set_multicycle_path -from [get_clocks $C96] -to [get_clocks $CLK48] -setup -end 2
    set_multicycle_path -from [get_clocks $C96] -to [get_clocks $CLK48] -hold  -end 1
}

# VU-meter del OSD (cruce de audio, DISPLAY) -> false_path (cosmetico, no afecta al juego).
set_false_path -to [get_registers {*jtframe_vumeter*}]
