// ============================================================================
//  BigKarnak (Gaelco) — generador de TIMING de vídeo (FASE 1 / camino a HW).
//
//  Contadores H/V que barren la trama y producen: coordenadas visibles (hpos/vpos)
//  para el datapath `bigkarnk_video` (que ya está verificado pixel-exacto), las señales
//  de sincronismo/blank/DE para el escalador de MiSTer, y el pulso `vblank_irq` que
//  dispara la IRQ6 del 68000 (= `irq6_line_hold` de MAME).
//
//  Ventana visible = la visarea de MAME (`gaelco.cpp`): 320×240, ROT0, **58.74 Hz** (afinado 2026-07-01).
//  ⚠️ Los porches/anchos de sync EXACTOS del PCB siguen sin medir (pendiente esquemático/HW); pero el
//  REFRESCO ya es el de MAME (58.74 Hz) con hsync CRT-válido (15.625 kHz). Geometría fina = ajuste en HW.
//
//  `ce_pix` = enable de reloj de píxel (lo entrega el PLL/wrally_clocks; 1 pulso/píxel).
// ============================================================================
`default_nettype none

module bigkarnk_video_timing #(
    // Horizontal (en píxeles). HTOTAL = HVIS+HFP+HSW+HBP.
    // 2026-06-25 FIX GEOMETRIA CRT (ensanchar + centrar): pixel clock bajado a 6 MHz (clk48/8) y
    //   HTOTAL=384 -> hsync 6e6/384 = 15.625 kHz (IGUAL, CRT-OK) PERO activo 320/384 = 83.3% de la
    //   linea (antes 320/512 = 62.5% -> bandas laterales anchas). Llena la pantalla como Final Fight/
    //   Dead Connection. Porches EQUILIBRADOS (HFP=HBP=18) -> centra (antes HBP=96>>HFP=48 = corrida a
    //   la derecha). Periodo de linea 64us SIN cambiar -> presupuesto sprite-engine intacto.
    parameter HVIS = 320,
    parameter HFP  = 18,     // front porch  (= HBP -> imagen centrada)
    parameter HSW  = 28,     // sync width   (28/6MHz = 4.67us, estandar)
    parameter HBP  = 18,     // back porch   (HTOTAL = 320+18+28+18 = 384 -> hsync 6e6/384 = 15.625 kHz)
    // Vertical (en líneas). VTOTAL = VVIS+VFP+VSW+VBP.
    // 2026-07-01 AFINADO A 58.74 Hz (= `screen.set_refresh_hz(58.74)` de gaelco.cpp para bigkarnk):
    //   hsync = 6MHz/384 = 15.625 kHz (CRT-perfecto, SIN cambiar). refresh = hsync/VTOTAL.
    //   58.74 Hz -> VTOTAL = 15625/58.74 = 266 (antes 272 = 57.45 Hz). Blanking vertical 32->26 (VBP 16->10).
    //   6e6/(384*266) = 58.741 Hz. La velocidad del juego sube +2.25% vs 57.45 (a fidelidad de MAME).
    parameter VVIS = 240,
    parameter VFP  = 8,
    parameter VSW  = 8,
    parameter VBP  = 10,     // (VTOTAL = 240+8+8+10 = 266 -> 6e6/(384*266) = 58.74 Hz; CRT 15.625 kHz)
    parameter SYNC_ACTIVE = 1'b1   // FIX 0x0 (2026-06-16): jtframe_resync espera hs/vs ACTIVO-ALTO
                                   // (mide el pulso por flanco de SUBIDA: hs_edge=hs&!last_hs, hs_len de
                                   // subida->bajada). Con activo-bajo media el periodo ACTIVO como ancho
                                   // de sync -> regenera un hsync de casi toda la linea -> scaler 0x0.
                                   // toki (que funciona) emite activo-alto. NO afecta a blanks/DE.
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,     // enable de reloj de píxel

    // coordenadas visibles para bigkarnk_video (válidas cuando de=1)
    output wire [9:0]  hpos,       // 0..HVIS-1
    output wire [8:0]  vpos,       // 0..VVIS-1

    // señales de salida de vídeo (para el sys/ de MiSTer)
    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        de,         // display enable (área visible)

    // a la CPU
    output reg         vblank_irq  // 1 pulso (1 ce_pix) al entrar en vblank
);
    localparam HTOTAL = HVIS + HFP + HSW + HBP;
    localparam VTOTAL = VVIS + VFP + VSW + VBP;

    reg [9:0] hcnt;
    reg [8:0] vcnt;

    wire hmax = (hcnt == HTOTAL-1);
    wire vmax = (vcnt == VTOTAL-1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= 0; vcnt <= 0;
            hsync <= ~SYNC_ACTIVE; vsync <= ~SYNC_ACTIVE;
            hblank <= 1'b1; vblank <= 1'b1; vblank_irq <= 1'b0;
        end else if (ce_pix) begin
            vblank_irq <= 1'b0;

            // contador horizontal
            if (hmax) begin
                hcnt <= 0;
                // contador vertical (avanza al final de cada línea)
                if (vmax) vcnt <= 0;
                else      vcnt <= vcnt + 1'b1;
            end else begin
                hcnt <= hcnt + 1'b1;
            end

            // blanks (área NO visible)
            // hblank SIN -1 (como vblank): el -1 recortaba 1 columna -> ancho 319 vs 320 de MAME.
            hblank <= (hcnt >= HVIS) ? 1'b1 : 1'b0;
            vblank <= (vcnt >= VVIS) ? 1'b1 : 1'b0;

            // sync (tras el front porch, durante SW)
            hsync <= (hcnt >= HVIS+HFP && hcnt < HVIS+HFP+HSW) ? SYNC_ACTIVE : ~SYNC_ACTIVE;
            vsync <= (vcnt >= VVIS+VFP && vcnt < VVIS+VFP+VSW) ? SYNC_ACTIVE : ~SYNC_ACTIVE;

            // IRQ6 de vblank: al entrar en la primera línea no visible
            if (hmax && vcnt == VVIS-1) vblank_irq <= 1'b1;
        end
    end

    assign hpos = hcnt;     // válido en 0..HVIS-1 (de=1)
    assign vpos = vcnt[8:0];
    // FIX del 1px del BORDE DERECHO (2026-07-01, = aligator/wrally): `de` extendido 1px a la dcha
    //   (`hcnt <= HVIS`, no `<`). El RGB lleva 1px de retardo de pipeline del tilemap (el "+1" que
    //   compensa el offset +3=+4-1); en la ÚLTIMA columna visible (x=HVIS-1=319) ese +1 caía en hblank
    //   -> la columna x=319 salía negra (se veía p.ej. en el grid de la escena 600: golden tiene la
    //   línea vertical del borde derecho, el sim la perdía). Con `<=` la ventana abre 1 ciclo más y
    //   captura esa última columna. NO desplaza el resto (el centro sigue 0.00%). thoop2 NO lo tenía.
    assign de   = (hcnt <= HVIS) && (vcnt < VVIS);

endmodule

`default_nettype wire
