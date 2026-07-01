// ============================================================================
//  Thunder Hoop (Gaelco) — generador de TIMING de vídeo (FASE 1 / camino a HW).
//
//  Contadores H/V que barren la trama y producen: coordenadas visibles (hpos/vpos)
//  para el datapath `wrally2_video` (que ya está verificado pixel-exacto), las señales
//  de sincronismo/blank/DE para el escalador de MiSTer, y el pulso `vblank_irq` que
//  dispara la IRQ6 del 68000 (= `irq6_line_hold` de MAME).
//
//  Ventana visible = la visarea de MAME (`gaelco.cpp`): 320×240, ROT0, 57.42 Hz.
//  ⚠️ Los porches/anchos de sync y el reloj de píxel EXACTOS son FASE 1 (pendiente
//  del esquemático / medida en HW real). Aquí van valores PROVISIONALES coherentes
//  (~60 Hz) que el escalador de MiSTer acepta; afinar luego para fidelidad CRT 1:1.
//
//  `ce_pix` = enable de reloj de píxel (lo entrega el PLL/wrally_clocks; 1 pulso/píxel).
// ============================================================================
`default_nettype none

module wrally2_video_timing #(
    // Horizontal (en píxeles). HTOTAL = HVIS+HFP+HSW+HBP.
    // 2026-06-16: ajustado a pixel clock 8 MHz (clk48/6). HTOTAL=512 -> hsync 15.6 KHz (estandar).
    // VTOTAL=269 -> refresco 8e6/(512*269) = 58.1 Hz. (Antes /7=6.857MHz, HTOTAL=448, VTOTAL=264.)
    // wrally2 MONITOR ÚNICO = 384 px de ancho (cada monitor del twin es 384). El render debe ser 384
    // para casar con el golden (W=384). pxl_cen/refresh fino para HW pendiente (Fase 6).
    // CRT-FIEL: HTOTAL=512 @ pxlclk 8MHz -> hsync 15.625 KHz (estándar 15K, entra en CRT). 384 visible (1 monitor).
    // TWIN: 768 visible. HVIS/HTOTAL son RUNTIME (input `twin`): single 384/HTOTAL512 @8MHz; twin 768/HTOTAL1024
    // @16MHz. En ambos refresh ~59.2Hz (vblank 60Hz coherente -> el juego va igual). El pxl_cen lo conmuta el game.
    parameter HFP  = 24,     // front porch (constante; el back porch sale de HTOTAL-HVIS-HFP-HSW)
    parameter HSW  = 48,     // sync width
    // Vertical (en líneas). VTOTAL = VVIS+VFP+VSW+VBP.
    parameter VVIS = 240,
    parameter VFP  = 10,
    parameter VSW  = 8,
    parameter VBP  = 6,      // (VTOTAL = 240+10+8+6 = 264 -> 8e6/(512*264) = 59.21 Hz ~ 59.10 de MAME)
    parameter SYNC_ACTIVE = 1'b1   // FIX 0x0 (2026-06-16): jtframe_resync espera hs/vs ACTIVO-ALTO
                                   // (mide el pulso por flanco de SUBIDA: hs_edge=hs&!last_hs, hs_len de
                                   // subida->bajada). Con activo-bajo media el periodo ACTIVO como ancho
                                   // de sync -> regenera un hsync de casi toda la linea -> scaler 0x0.
                                   // toki (que funciona) emite activo-alto. NO afecta a blanks/DE.
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,     // enable de reloj de píxel
    input  wire        twin,       // 1=TWIN: HVIS=768/HTOTAL=1024 (16MHz); 0=single: HVIS=384/HTOTAL=512 (8MHz)

    // coordenadas visibles para wrally2_video (válidas cuando de=1)
    output wire [9:0]  hpos,       // 0..HVIS-1
    output wire [8:0]  vpos,       // 0..VVIS-1
    output wire        frame_end,  // 1 en la última línea del frame (vcnt==VTOTAL-1) -> wrap de next_vpos

    // señales de salida de vídeo (para el sys/ de MiSTer)
    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        de,         // display enable (área visible)

    // a la CPU
    output reg         vblank_irq  // 1 pulso (1 ce_pix) al entrar en vblank
);
    // RUNTIME: ancho visible y total según el modo. Twin = 2x (768/1024); single = 384/512.
    wire [10:0] HVIS   = twin ? 11'd768  : 11'd384;
    wire [10:0] HTOTAL = twin ? 11'd1024 : 11'd512;   // back porch = HTOTAL-HVIS-HFP_eff-HSW_eff
    // FIX twin HDMI (research Darius 2026-06-30): al DOBLAR el pixel clock (8->16MHz) en twin, mantener los
    // porches CONSTANTES en píxeles HALVABA la DURACIÓN del hsync (single 48px@8MHz=6µs -> twin 48px@16MHz=3µs).
    // El escalador/ascal de MiSTer RECHAZA pulsos hsync tan cortos -> "muestra el último válido" / 0x0. El core
    // Darius (jtframe, wide 864px, que SÍ va por HDMI) usa HSYNC=150px@24MHz=6.25µs. Doblamos HFP/HSW en twin
    // para conservar ~6µs (= single, que el escalador SÍ acepta). HBP twin = 1024-768-48-96 = 112 (ok).
    wire [10:0] HFP_eff = twin ? (HFP*2) : HFP;   // 24 -> 48 px (3µs en ambos modos)
    wire [10:0] HSW_eff = twin ? (HSW*2) : HSW;   // 48 -> 96 px (6µs en ambos modos)
    localparam VTOTAL = VVIS + VFP + VSW + VBP;

    reg [10:0] hcnt;
    reg [8:0] vcnt;

    wire hmax = (hcnt == HTOTAL-1'b1);
    wire vmax = (vcnt == VTOTAL-1);
    assign frame_end = vmax;

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
            hsync <= (hcnt >= HVIS+HFP_eff && hcnt < HVIS+HFP_eff+HSW_eff) ? SYNC_ACTIVE : ~SYNC_ACTIVE;
            vsync <= (vcnt >= VVIS+VFP && vcnt < VVIS+VFP+VSW) ? SYNC_ACTIVE : ~SYNC_ACTIVE;

            // IRQ6 de vblank: al entrar en la primera línea no visible
            if (hmax && vcnt == VVIS-1) vblank_irq <= 1'b1;
        end
    end

    assign hpos = hcnt[9:0]; // válido en 0..HVIS-1 (de=1); hcnt[10] sólo en porches de twin
    assign vpos = vcnt[8:0];
    // de extendido 1px a la dcha (hcnt<=HVIS): el hblank registrado abre la ventana del volcado/escalador
    // 1 ciclo más tarde (hcnt 1..HVIS); con de=(hcnt<HVIS) la ÚLTIMA columna de esa ventana salía negra
    // (de=0). El RGB lleva 1px de retardo de pipeline -> hcnt=HVIS muestra la columna visible HVIS-1 correcta.
    assign de   = (hcnt <= HVIS) && (vcnt < VVIS);

endmodule

`default_nettype wire
