// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 gaelco2.cpp / chip GAE1) — aligator_vmem.v
//
//  VRAM 64KB (0x200000-0x20ffff) PLANA + paleta 8KB (0x210000-0x211fff), en BRAM.
//  Organizada a la gaelco2 (NO Tipo-1): una sola VRAM con sprites/tilemaps/linescroll/scroll.
//
//  La VRAM se guarda por PARIDAD de word (even/odd) para servir el PAR {word0,word1} de un
//  tile en UNA lectura de 32b (el motor GAE1 lee 2 words por tile: code/attr + code_lo).
//    even[k] = word 2k (par)   ;   odd[k] = word 2k+1 (impar)   ;   k = 0..0x3FFF
//  Puertos de vídeo:
//    - tp0/tp1: par de tile de las 2 capas. idx = banco*0x800 + tile_index (14b). -> {w0,w1}
//    - wrd:     word genérico (sprites/scroll/linescroll). a = word 0..0x7FFF -> 16b
//    - pal:     paleta (color 0..0xFFF) -> 16b
//  Cada puerto con su copia (1W/1R) -> infiere BRAM. CPU escribe el dato CRUDO (gaelco2 no cifra).
// ============================================================================
`default_nettype none

module aligator_vmem (
    input  wire        clk,
    input  wire        clk96,        // lectura del motor de SPRITES (port clk96 del fix de overrun)

    // -------- puerto CPU (de aligator_main) --------
    input  wire [15:0] cpu_addr,         // direccion de BYTE dentro de la región
    input  wire        cpu_uds, cpu_lds,
    input  wire        cpu_we,
    input  wire        cs_vram,          // 0x200000-0x20ffff  VRAM 64KB
    input  wire        cs_pal,           // 0x210000-0x211fff  paleta 8KB
    input  wire [15:0] cpu_wdata,        // dato crudo del bus
    output reg  [15:0] cpu_vram_rdata,
    output reg  [15:0] cpu_pal_rdata,

    // -------- puertos de VÍDEO (al motor GAE1) --------
    input  wire [13:0] tp0_idx,          // tilemap0: banco*0x800 + tile_index
    output reg  [31:0] tp0_q,            // {word0, word1}
    input  wire [13:0] tp1_idx,          // tilemap1
    output reg  [31:0] tp1_q,
    input  wire [14:0] wrd_a,            // word genérico (0..0x7FFF)
    output wire [15:0] wrd_q,
    input  wire [14:0] spr_a,            // word para el motor de SPRITES (lista + indirección)
    output wire [15:0] spr_q,
    input  wire [11:0] pal_a,            // color de paleta (0..0xFFF)
    output reg  [15:0] pal_q
);
    // ===================== VRAM 64KB por paridad de word (even/odd) =====================
    // 5 copias (CPU, tp0, tp1, wrd, spr), cada una even+odd con byte-lanes hi/lo. 16384 words/half.
    // ramstyle "no_rw_check" FUERZA inferencia M10K (lectura en bloque always distinto al de escritura
    // no infería sola -> registros -> overflow del fitter; no_rw_check evita la lógica RDW y mete BRAM).
    // CPU
    (* ramstyle = "no_rw_check" *) reg [7:0] ce_hi[0:16383], ce_lo[0:16383], co_hi[0:16383], co_lo[0:16383];
    // tilemap0
    (* ramstyle = "no_rw_check" *) reg [7:0] t0e_hi[0:16383], t0e_lo[0:16383], t0o_hi[0:16383], t0o_lo[0:16383];
    // tilemap1
    (* ramstyle = "no_rw_check" *) reg [7:0] t1e_hi[0:16383], t1e_lo[0:16383], t1o_hi[0:16383], t1o_lo[0:16383];
    // word genérico
    (* ramstyle = "no_rw_check" *) reg [7:0] we_hi[0:16383], we_lo[0:16383], wo_hi[0:16383], wo_lo[0:16383];
    // motor de sprites
    (* ramstyle = "no_rw_check" *) reg [7:0] se_hi[0:16383], se_lo[0:16383], so_hi[0:16383], so_lo[0:16383];

    wire        par   = cpu_addr[1];          // 0 = word par (even), 1 = impar (odd)
    wire [13:0] hidx  = cpu_addr[15:2];        // indice dentro del half (0..0x3FFF)
    wire vw_e_hi = cpu_we & cs_vram & ~par & cpu_uds;
    wire vw_e_lo = cpu_we & cs_vram & ~par & cpu_lds;
    wire vw_o_hi = cpu_we & cs_vram &  par & cpu_uds;
    wire vw_o_lo = cpu_we & cs_vram &  par & cpu_lds;
    wire        w_par  = wrd_a[0];     // puerto word genérico (scroll/linescroll)
    wire [13:0] w_hidx = wrd_a[14:1];
    wire        s_par  = spr_a[0];     // puerto del motor de SPRITES (lista + indirección)
    wire [13:0] s_hidx = spr_a[14:1];
    // Cada copia: ESCRITURA (CPU) + su LECTURA en el MISMO always block -> Quartus infiere M10K
    // (leer en un bloque always distinto al de escritura NO infería -> 2.6Mbit en registros -> overflow).
    always @(posedge clk) begin
        if (vw_e_hi) ce_hi[hidx]<=cpu_wdata[15:8];
        if (vw_e_lo) ce_lo[hidx]<=cpu_wdata[7:0];
        if (vw_o_hi) co_hi[hidx]<=cpu_wdata[15:8];
        if (vw_o_lo) co_lo[hidx]<=cpu_wdata[7:0];
        cpu_vram_rdata <= par ? {co_hi[hidx], co_lo[hidx]} : {ce_hi[hidx], ce_lo[hidx]};
    end
    always @(posedge clk) begin       // copia tilemap0
        if (vw_e_hi) t0e_hi[hidx]<=cpu_wdata[15:8];
        if (vw_e_lo) t0e_lo[hidx]<=cpu_wdata[7:0];
        if (vw_o_hi) t0o_hi[hidx]<=cpu_wdata[15:8];
        if (vw_o_lo) t0o_lo[hidx]<=cpu_wdata[7:0];
        tp0_q <= {t0e_hi[tp0_idx], t0e_lo[tp0_idx], t0o_hi[tp0_idx], t0o_lo[tp0_idx]};
    end
    always @(posedge clk) begin       // copia tilemap1
        if (vw_e_hi) t1e_hi[hidx]<=cpu_wdata[15:8];
        if (vw_e_lo) t1e_lo[hidx]<=cpu_wdata[7:0];
        if (vw_o_hi) t1o_hi[hidx]<=cpu_wdata[15:8];
        if (vw_o_lo) t1o_lo[hidx]<=cpu_wdata[7:0];
        tp1_q <= {t1e_hi[tp1_idx], t1e_lo[tp1_idx], t1o_hi[tp1_idx], t1o_lo[tp1_idx]};
    end
    // wrd/spr: lectura INCONDICIONAL de los 4 byte-arrays (registrada) + mux de paridad en la SALIDA
    // (el mux dentro del read clocked lo clasificaba como async -> no infería; así infiere como el tilemap).
    reg [7:0] we_hi_q, we_lo_q, wo_hi_q, wo_lo_q; reg w_par_q;
    always @(posedge clk) begin       // copia word genérico
        if (vw_e_hi) we_hi[hidx]<=cpu_wdata[15:8];
        if (vw_e_lo) we_lo[hidx]<=cpu_wdata[7:0];
        if (vw_o_hi) wo_hi[hidx]<=cpu_wdata[15:8];
        if (vw_o_lo) wo_lo[hidx]<=cpu_wdata[7:0];
        we_hi_q <= we_hi[w_hidx]; we_lo_q <= we_lo[w_hidx];
        wo_hi_q <= wo_hi[w_hidx]; wo_lo_q <= wo_lo[w_hidx];
        w_par_q <= w_par;
    end
    assign wrd_q = w_par_q ? {wo_hi_q, wo_lo_q} : {we_hi_q, we_lo_q};

    // DUAL-CLOCK (fix overrun de sprites): CPU ESCRIBE @clk(48); el motor de SPRITES LEE @clk96.
    // Simple-dual-port (1W clk / 1R clk96) -> M10K dual-clock (no_rw_check ya puesto). Mismo riesgo
    // de read-during-write que el diseño previo (sprite-RAM no buffeada); aceptable (tear ocasional 1 frame).
    reg [7:0] se_hi_q, se_lo_q, so_hi_q, so_lo_q; reg s_par_q;
    always @(posedge clk) begin       // copia sprites — ESCRITURA CPU @48
        if (vw_e_hi) se_hi[hidx]<=cpu_wdata[15:8];
        if (vw_e_lo) se_lo[hidx]<=cpu_wdata[7:0];
        if (vw_o_hi) so_hi[hidx]<=cpu_wdata[15:8];
        if (vw_o_lo) so_lo[hidx]<=cpu_wdata[7:0];
    end
    always @(posedge clk96) begin     // LECTURA del motor de sprites @96
        se_hi_q <= se_hi[s_hidx]; se_lo_q <= se_lo[s_hidx];
        so_hi_q <= so_hi[s_hidx]; so_lo_q <= so_lo[s_hidx];
        s_par_q <= s_par;
    end
    assign spr_q = s_par_q ? {so_hi_q, so_lo_q} : {se_hi_q, se_lo_q};

    // ===================== Paleta 8KB (4K words) — CPU + 1 puerto de vídeo =====================
    reg [7:0] pc_hi[0:4095], pc_lo[0:4095];   // copia CPU
    reg [7:0] pv_hi[0:4095], pv_lo[0:4095];   // copia vídeo
    wire [11:0] pwo = cpu_addr[12:1];          // word offset (0..0xFFF)
    wire pw_hi = cpu_we & cs_pal & cpu_uds;
    wire pw_lo = cpu_we & cs_pal & cpu_lds;
    always @(posedge clk) begin
        if (pw_hi) begin pc_hi[pwo]<=cpu_wdata[15:8]; pv_hi[pwo]<=cpu_wdata[15:8]; end
        if (pw_lo) begin pc_lo[pwo]<=cpu_wdata[7:0];  pv_lo[pwo]<=cpu_wdata[7:0];  end
        cpu_pal_rdata <= {pc_hi[pwo], pc_lo[pwo]};
        pal_q <= {pv_hi[pal_a], pv_lo[pal_a]};
    end

`ifdef ALIGATOR_SCENE
    // REPLAY: precarga la escena volcada de MAME (render sin bootear, CPU en reset). Formato PARIDAD:
    //   scene_ve_* = words PARES (even), scene_vo_* = words IMPARES (odd), 16384 c/u. Las 4 copias leen.
    initial begin
        $readmemh("scene_ve_hi.hex", ce_hi);  $readmemh("scene_ve_lo.hex", ce_lo);
        $readmemh("scene_vo_hi.hex", co_hi);  $readmemh("scene_vo_lo.hex", co_lo);
        $readmemh("scene_ve_hi.hex", t0e_hi); $readmemh("scene_ve_lo.hex", t0e_lo);
        $readmemh("scene_vo_hi.hex", t0o_hi); $readmemh("scene_vo_lo.hex", t0o_lo);
        $readmemh("scene_ve_hi.hex", t1e_hi); $readmemh("scene_ve_lo.hex", t1e_lo);
        $readmemh("scene_vo_hi.hex", t1o_hi); $readmemh("scene_vo_lo.hex", t1o_lo);
        $readmemh("scene_ve_hi.hex", we_hi);  $readmemh("scene_ve_lo.hex", we_lo);
        $readmemh("scene_vo_hi.hex", wo_hi);  $readmemh("scene_vo_lo.hex", wo_lo);
        $readmemh("scene_ve_hi.hex", se_hi);  $readmemh("scene_ve_lo.hex", se_lo);
        $readmemh("scene_vo_hi.hex", so_hi);  $readmemh("scene_vo_lo.hex", so_lo);
        $readmemh("scene_pal_hi.hex", pc_hi); $readmemh("scene_pal_lo.hex", pc_lo);
        $readmemh("scene_pal_hi.hex", pv_hi); $readmemh("scene_pal_lo.hex", pv_lo);
        $display("ALIGATOR_SCENE: VRAM(paridad)/paleta precargadas (replay)");
    end
`endif
endmodule

`default_nettype wire
