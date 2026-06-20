#!/usr/bin/env python3
"""
patch_dallas_runtime.py — hace el .rbf de World Rally DISTRIBUIBLE (sin copyright).

Por qué hace falta
------------------
El firmware del DS5002FP (`wrdallas.bin`, 32 KB) NO puede ir horneado en el bitstream (.rbf)
porque es material con copyright. Debe cargarse en RUNTIME desde el .mra, igual que el resto de
ROMs — exactamente como la NVSRAM real del Dallas, que un loader externo escribe y el MCU lee.

jtframe, al generar el GAMETOP (`mister/jtwrally_game_sdram.v` desde `cfg/mem.yaml` +
`modules/jtframe/hdl/inc/prom_dwnld.v`), produce para la región `wrdallas` un bloque que NO sirve
para cargar en runtime en ESTE core, por dos motivos:

  1. `jtframe_ioctl_range(.addr(raw_addr))` — `raw_addr` es de 22 bits (SDRAMW-2, con SDRAMW=23),
     máx 0x3FFFFF. El firmware vive en el byte 0x400000 (JTFRAME_PROM_START, tras prog+gfx+oki = 4 MB)
     → la dirección ENVUELVE a 0 → el download escribiría el firmware sobre el banco 0 (corrupción).
  2. `jtframe_prom` es de UN reloj (clk48). El download escribe en el dominio del downloader (`clk`)
     y el MCU lee a clk48 → cruce de relojes.

Por esos dos motivos, sin este parche la única salida era hornear el firmware (BRAM init / SYNHEX) →
.rbf con copyright, NO distribuible.

Qué hace el parche (camino B = como la NVSRAM real)
---------------------------------------------------
Reemplaza el bloque `wrdallas` generado por:
  - `jtframe_ioctl_range(.addr(ioctl_addr_noheader))` — dirección COMPLETA (26 bits) → llega a 0x400000.
  - `jtframe_dual_ram` (DOBLE RELOJ): puerto 0 = escritura del download (clk), puerto 1 = lectura del
    MCU (clk48). Resuelve el cruce de relojes.
El `.mra` mete `wrdallas.bin` (CRC 547d1768) en el stream a 0x400000, así que el firmware se carga en
runtime. Validado en HW (MiSTer): firma A53E = el DS5002 arranca con el firmware cargado por runtime.

Uso
---
Tras `jtcore wrally -mister` (que genera el proyecto) y ANTES de compilar con Quartus:

    python3 cores/wrally/tools/patch_dallas_runtime.py <ruta>/mister/jtwrally_game_sdram.v

Es idempotente (re-ejecutar no rompe). En SIMULACIÓN no hace falta: la plantilla global usa
`jtframe_prom` + SIMFILE y carga `wrdallas.bin` por `$readmemh`.
"""
import re
import sys

NEW_BLOCK = '''// wrdallas PROM (camino B: carga en RUNTIME desde el .mra; BRAM doble reloj = NVSRAM real)
wire [ 7:0]wrdallas_dd;
wire [14:0]wrdallas_waddr;
wire       wrdallas_we;

jtframe_ioctl_range #(
    .AW(15),
    .OFFSET(JTFRAME_PROM_START)
) u_range_wrdallas(
    .clk        ( clk                 ),
    .addr       ( ioctl_addr_noheader ),
    .addr_rel   ( wrdallas_waddr      ),
    .en         ( ioctl_wr            ),
    .inrange    ( wrdallas_we         ),
    .din        ( ioctl_dout          ),
    .dout       ( wrdallas_dd         )
);

jtframe_dual_ram #(
    .DW(8),
    .AW(15),
    .SIMFILE("wrdallas.bin")
) u_prom_wrdallas(
    .clk0       ( clk            ),
    .data0      ( wrdallas_dd    ),
    .addr0      ( wrdallas_waddr ),
    .we0        ( wrdallas_we    ),
    .q0         (                ),
    .clk1       ( clk48          ),
    .data1      ( 8'd0           ),
    .addr1      ( wrdallas_addr  ),
    .we1        ( 1'b0           ),
    .q1         ( wrdallas_data  )
);'''

# Casa tanto el bloque recién generado por jtframe como uno ya parcheado (idempotente).
PATTERN = r'// wrdallas PROM.*?u_prom_wrdallas\(.*?\n\);'


def main():
    if len(sys.argv) != 2:
        sys.exit("uso: patch_dallas_runtime.py <ruta a jtwrally_game_sdram.v>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        gt = f.read()
    gt2, n = re.subn(PATTERN, NEW_BLOCK, gt, count=1, flags=re.DOTALL)
    if n != 1:
        sys.exit("ERROR: no se encontró el bloque 'wrdallas PROM' en %s (n=%d)" % (path, n))
    with open(path, "w", encoding="utf-8") as f:
        f.write(gt2)
    print("OK: wrdallas -> jtframe_dual_ram (carga en runtime, .rbf distribuible) en %s" % path)


if __name__ == "__main__":
    main()
