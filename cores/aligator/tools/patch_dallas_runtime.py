#!/usr/bin/env python3
"""
patch_dallas_runtime.py — hace el .rbf de Alligator Hunt DISTRIBUIBLE (sin copyright).

Por qué hace falta
------------------
El firmware del DS5002FP (`dallas.bin`, 32 KB) NO puede ir horneado en el bitstream (.rbf)
porque es material con copyright. Debe cargarse en RUNTIME desde el .mra, igual que el resto de
ROMs — exactamente como la NVSRAM real del Dallas, que un loader externo escribe y el MCU lee.
(Mismo planteamiento que World Rally / thoop2.)

jtframe, al generar el GAMETOP (`mister/jtaligator_game_sdram.v` desde `cfg/mem.yaml` +
`modules/jtframe/hdl/inc/prom_dwnld.v`), produce para la región `dallas` un bloque que NO sirve
para cargar en runtime en ESTE core, por dos motivos:

  1. `jtframe_ioctl_range(.addr(raw_addr))` — `raw_addr` es de SDRAMW-2 bits (con JTFRAME_SDRAM_LARGE
     SDRAMW=24 → 22 bits, máx 0x3FFFFF). El firmware vive en el byte 0x1100000 (JTFRAME_PROM_START,
     tras prog 1 MB + gfx 16 MB) → la dirección ENVUELVE → el download escribiría el firmware sobre
     un banco SDRAM (corrupción).
  2. `jtframe_prom` es de UN reloj (clk48). El download escribe en el dominio del downloader (`clk`)
     y el MCU lee a clk48 → cruce de relojes.

Por esos dos motivos, sin este parche la única salida era hornear el firmware (BRAM init / SYNHEX) →
.rbf con copyright, NO distribuible.

Qué hace el parche (camino B = como la NVSRAM real)
---------------------------------------------------
Reemplaza el bloque `dallas` generado por:
  - `jtframe_ioctl_range(.addr(ioctl_addr_noheader))` — dirección COMPLETA (26 bits) → llega a 0x1100000.
  - `jtframe_dual_ram` (DOBLE RELOJ): puerto 0 = escritura del download (clk), puerto 1 = lectura del
    MCU (clk48). Resuelve el cruce de relojes.
El `.mra` mete el firmware (32 KB) en el stream a 0x1100000, así que se carga en runtime.

Uso
---
Tras `jtcore aligator -mister` (que genera el proyecto) y ANTES de compilar con Quartus:

    python3 cores/aligator/tools/patch_dallas_runtime.py <ruta>/mister/jtaligator_game_sdram.v

Es idempotente (re-ejecutar no rompe). En SIMULACIÓN no hace falta: la plantilla global usa
`jtframe_prom` + SIMFILE y carga `dallas.bin` por `$readmemh`.
"""
import re
import sys

NEW_BLOCK = '''// dallas PROM (camino B: carga en RUNTIME desde el .mra; BRAM doble reloj = NVSRAM real)
wire [ 7:0]dallas_dd;
wire [14:0]dallas_waddr;
wire       dallas_we;

jtframe_ioctl_range #(
    .AW(15),
    .OFFSET(JTFRAME_PROM_START)
) u_range_dallas(
    .clk        ( clk                 ),
    .addr       ( ioctl_addr_noheader ),
    .addr_rel   ( dallas_waddr        ),
    .en         ( ioctl_wr            ),
    .inrange    ( dallas_we           ),
    .din        ( ioctl_dout          ),
    .dout       ( dallas_dd           )
);

jtframe_dual_ram #(
    .DW(8),
    .AW(15),
    .SIMFILE("dallas.bin")
) u_prom_dallas(
    .clk0       ( clk          ),
    .data0      ( dallas_dd    ),
    .addr0      ( dallas_waddr ),
    .we0        ( dallas_we    ),
    .q0         (              ),
    .clk1       ( clk48        ),
    .data1      ( 8'd0         ),
    .addr1      ( dallas_addr  ),
    .we1        ( 1'b0         ),
    .q1         ( dallas_data  )
);'''

# Casa tanto el bloque recién generado por jtframe como uno ya parcheado (idempotente).
PATTERN = r'// dallas PROM.*?u_prom_dallas\(.*?\n\);'


def main():
    if len(sys.argv) != 2:
        sys.exit("uso: patch_dallas_runtime.py <ruta a jtaligator_game_sdram.v>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        gt = f.read()
    gt2, n = re.subn(PATTERN, NEW_BLOCK, gt, count=1, flags=re.DOTALL)
    if n != 1:
        sys.exit("ERROR: no se encontró el bloque 'dallas PROM' en %s (n=%d)" % (path, n))
    with open(path, "w", encoding="utf-8") as f:
        f.write(gt2)
    print("OK: dallas -> jtframe_dual_ram (carga en runtime, .rbf distribuible) en %s" % path)


if __name__ == "__main__":
    main()
