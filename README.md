# gaelco-fpga

Recreaciones en FPGA de placas arcade de **Gaelco**, construidas sobre el framework
[**JTFRAME**](https://github.com/jotego/jtframe) (Jose Tejada / jotego). Multi-plataforma
(MiSTer, Pocket, …) desde el mismo código.

## Cores

### World Rally (Gaelco, 1993)
Racer cenital. Hardware: **MC68000 @12 MHz** + **Dallas DS5002FP** (MCU seguro 8051) + ASIC de
vídeo Gaelco (2 tilemaps + sprites) + VRAM cifrada + **OKI MSM6295**.

**Estado: jugable en MiSTer** — arranque, vídeo, audio, handshake del coprocesador DS5002, demo de
atracción y partida. El DS5002 se implementa con el core **mc8051** (Oregano, incluido en jtframe)
adaptado al timing del DS5002.

## Construir

Este repo contiene **solo el código del core** (`cores/wrally/`). El framework y los cores de
terceros (jtframe, fx68k, jt6295, mc8051) **no se incluyen**: los aporta jtframe.

1. Clona [jtcores](https://github.com/jotego/jtcores) (trae jtframe + fx68k + jt6295 como módulos).
2. Coloca `cores/wrally/` de este repo dentro de tu checkout de jtcores.
3. Compila con la herramienta de jtframe (`jtcore wrally -mister`, etc.).

Estructura del core:
```
cores/wrally/
├── hdl/    Verilog del core (wrally_*.v, jtwrally_game.v, wrally_dbg_uart.v, mc8051_regen.v)
├── cfg/    macros.def, mem.yaml, files.yaml
├── mra/    definición .mra (cómo ensamblar las ROMs)
├── syn/    wrally_clk48_96.sdc (constraints de timing)
└── tools/  regeneración del core mc8051 (ghdl → Verilog)
```

## ROMs

**No se incluyen** (material con copyright). Cada cual aporta las ROMs originales de su placa. El
`.mra` describe cómo ensamblarlas.

## Créditos

- **JTFRAME**, **jt6295** — Jose Tejada (jotego)
- **fx68k** (núcleo 68000) — Jared Boone (ijor)
- **mc8051** — Oregano Systems (vía jtframe)
- **MAME** — referencia de hardware (driver `wrally.cpp`)
- Gaelco SA — por liberar el código del DS5002FP para emulación

## Licencia

**GPLv3** (ver [`LICENSE`](LICENSE)) — obligado por las dependencias jtframe / fx68k / jt6295.
