// ============================================================================
//  World Rally (Gaelco) — wrally_vmem.v: memorias de VÍDEO compartidas CPU<->vídeo.
//
//  SYNTHESIS-READY + timing-EXACTO: combina lo verificado y lo inferible:
//   - Almacenamiento en LANES DE BYTE (8b), escritura de BYTE COMPLETO (mem[w]<=byte)
//     -> infiere block-RAM (el bit-slice de byte-enable sobre palabra ancha NO inferia).
//   - Lectura de VÍDEO registrada en CE_PIX (= MISMA latencia que el modelo verificado
//     `tb_video_vmem`=0 diffs; jtframe_dual_ram registra en clk y desfasaba 1 ce_pix).
//   - Lectura de CPU registrada en clk (1 ciclo, cubierta por el wait-state del DTACK).
//   - Multi-puerto (L0/L1/CPU) por REPLICACION fisica (cada copia 1W/1R por lane).
//
//  VRAM: word de 32b = 4 bytes {b0,b1,b2,b3}=[31:24..7:0] (vram_a 4-alineado,
//  wrally_tilemap.v:64). Paleta: word de 16b = {par,impar}=[15:8],[7:0]. Sprite RAM
//  pequena (4KB) async -> registros (OK).
// ============================================================================
`default_nettype none

module wrally_vmem (
    input  wire        clk,
    input  wire        ce_pix,

    // -------- puerto CPU --------
    input  wire [13:0] cpu_addr,
    input  wire        cpu_uds, cpu_lds,
    input  wire        cpu_we,
    input  wire        cs_vram, cs_pal, cs_spr,
    input  wire [15:0] vram_wdata,
    input  wire [15:0] io_wdata,
    output reg  [15:0] cpu_vram_rdata,
    output reg  [15:0] cpu_pal_rdata,
    output reg  [15:0] cpu_spr_rdata,

    // -------- puertos de VÍDEO --------
    input  wire [13:0] vram_a0, vram_a1,
    output reg  [31:0] vram_q0, vram_q1,
    input  wire [9:0]  pal_a,        // puerto A (tilemap): banco 0 (0..0x1ff)
    input  wire [12:0] palb_a,       // puerto B (sprite): 13 bits para alcanzar bancos de SOMBRA (shadowlevel<<10)
    output reg  [15:0] pal_q, palb_q,
    input  wire [10:0] spr_a,
    output reg  [15:0] spr_q
);
    // ===================== VRAM: 3 copias x 4 lanes de byte (4096 words) =================
    // copia L0 (lee video L0), L1 (lee video L1), CP (lee CPU). Cada lane 8b, 1W/1R.
    reg [7:0] v0_b0[0:4095], v0_b1[0:4095], v0_b2[0:4095], v0_b3[0:4095]; // copia L0
    reg [7:0] v1_b0[0:4095], v1_b1[0:4095], v1_b2[0:4095], v1_b3[0:4095]; // copia L1
    reg [7:0] vc_b0[0:4095], vc_b1[0:4095], vc_b2[0:4095], vc_b3[0:4095]; // copia CPU
    wire [11:0] vwidx = cpu_addr[13:2];
    // CPU escribe 16b: mitad alta (A[1]=0 -> b0,b1) o baja (A[1]=1 -> b2,b3). Byte completo.
    wire vw_b0 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_uds;   // b0 = byte par (alto) de la mitad alta
    wire vw_b1 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_lds;
    wire vw_b2 = cpu_we & cs_vram &  cpu_addr[1] & cpu_uds;
    wire vw_b3 = cpu_we & cs_vram &  cpu_addr[1] & cpu_lds;
    always @(posedge clk) begin
        if (vw_b0) begin v0_b0[vwidx]<=vram_wdata[15:8]; v1_b0[vwidx]<=vram_wdata[15:8]; vc_b0[vwidx]<=vram_wdata[15:8]; end
        if (vw_b1) begin v0_b1[vwidx]<=vram_wdata[7:0];  v1_b1[vwidx]<=vram_wdata[7:0];  vc_b1[vwidx]<=vram_wdata[7:0];  end
        if (vw_b2) begin v0_b2[vwidx]<=vram_wdata[15:8]; v1_b2[vwidx]<=vram_wdata[15:8]; vc_b2[vwidx]<=vram_wdata[15:8]; end
        if (vw_b3) begin v0_b3[vwidx]<=vram_wdata[7:0];  v1_b3[vwidx]<=vram_wdata[7:0];  vc_b3[vwidx]<=vram_wdata[7:0];  end
    end
    // lecturas de VÍDEO en ce_pix (= timing verificado)
    always @(posedge clk) if (ce_pix) begin
        vram_q0 <= {v0_b0[vram_a0[13:2]], v0_b1[vram_a0[13:2]], v0_b2[vram_a0[13:2]], v0_b3[vram_a0[13:2]]};
        vram_q1 <= {v1_b0[vram_a1[13:2]], v1_b1[vram_a1[13:2]], v1_b2[vram_a1[13:2]], v1_b3[vram_a1[13:2]]};
    end
    // lectura de CPU en clk (16b: mitad alta o baja segun A[1])
    always @(posedge clk)
        cpu_vram_rdata <= cpu_addr[1] ? {vc_b2[vwidx], vc_b3[vwidx]} : {vc_b0[vwidx], vc_b1[vwidx]};

    // ===================== Paleta: 3 copias x 2 lanes (8192 words) =======================
    reg [7:0] pa_hi[0:8191], pa_lo[0:8191];   // copia A (tilemap)
    reg [7:0] pb_hi[0:8191], pb_lo[0:8191];   // copia B (sprite)
    reg [7:0] pc_hi[0:8191], pc_lo[0:8191];   // copia CPU
    wire [12:0] pwidx = cpu_addr[13:1];
    wire pw_hi = cpu_we & cs_pal & cpu_uds;
    wire pw_lo = cpu_we & cs_pal & cpu_lds;
    always @(posedge clk) begin
        if (pw_hi) begin pa_hi[pwidx]<=io_wdata[15:8]; pb_hi[pwidx]<=io_wdata[15:8]; pc_hi[pwidx]<=io_wdata[15:8]; end
        if (pw_lo) begin pa_lo[pwidx]<=io_wdata[7:0];  pb_lo[pwidx]<=io_wdata[7:0];  pc_lo[pwidx]<=io_wdata[7:0];  end
    end
    always @(posedge clk) if (ce_pix) begin
        pal_q  <= {pa_hi[{3'd0,pal_a}],  pa_lo[{3'd0,pal_a}]};
        palb_q <= {pb_hi[palb_a],        pb_lo[palb_a]};        // 13 bits: banco 0 (sprite) o banco sombra
    end
    always @(posedge clk) cpu_pal_rdata <= {pc_hi[pwidx], pc_lo[pwidx]};

`ifdef SIMULATION
    // PALW: traza de escrituras de paleta (pwidx, dato) + chequeo de lectura.
    integer npw=0;
    reg [31:0] pclk=0;
    always @(posedge clk) begin
        pclk <= pclk + 1'b1;
        if (pw_hi | pw_lo) begin npw <= npw + 1;
            if (npw < 30) $display("PALW #%0d t=%0d pwidx=%h hi=%b lo=%b io_wdata=%h | readback pa[%h]={%h,%h}",
                                   npw, pclk, pwidx, pw_hi, pw_lo, io_wdata, pwidx, pa_hi[pwidx], pa_lo[pwidx]); end
        // muestra ce_pix y una lectura del array en pal_a (sin gate) cada ~2^20 clk
        if (pclk[19:0]==0)
            $display("PALR t=%0d ce_pix=%b pal_a=%h pa_hi[pal_a]=%h pa_lo[pal_a]=%h pal_q=%h npw=%0d",
                     pclk, ce_pix, pal_a, pa_hi[{3'd0,pal_a}], pa_lo[{3'd0,pal_a}], pal_q, npw);
    end
`endif

    // ===================== Sprite RAM (4KB) -> BRAM (byte-lanes, lectura registrada) ======
    // El array plano con lectura ASÍNCRONA costaba ~33K registros + ~17K ALUTs (no infería).
    // Ahora: 2 copias (vídeo/CPU) × 2 lanes (par/impar word), escritura de byte completo,
    // lectura REGISTRADA -> infiere block-RAM. 2048 words.
    // ⚠️ La lectura de vídeo spr_q gana +1 ciclo vs el async anterior. En v1 (spr_en=0) es
    //    transparente; para v2 el motor de sprite debe absorber ese ciclo (re-verificar
    //    tb_video_vmem con spr_en=1).
    reg [7:0] sv_e[0:2047], sv_o[0:2047];   // copia vídeo (lee spr_a)
    reg [7:0] sc_e[0:2047], sc_o[0:2047];   // copia CPU
    wire [10:0] swidx = cpu_addr[11:1];
    wire sw_e = cpu_we & cs_spr & cpu_uds;  // byte par (alto)
    wire sw_o = cpu_we & cs_spr & cpu_lds;  // byte impar (bajo)
    always @(posedge clk) begin
        if (sw_e) begin sv_e[swidx] <= io_wdata[15:8]; sc_e[swidx] <= io_wdata[15:8]; end
        if (sw_o) begin sv_o[swidx] <= io_wdata[7:0];  sc_o[swidx] <= io_wdata[7:0];  end
    end
    always @(posedge clk) spr_q         <= {sv_e[spr_a],          sv_o[spr_a]};
    always @(posedge clk) cpu_spr_rdata <= {sc_e[cpu_addr[11:1]], sc_o[cpu_addr[11:1]]};

`ifdef WR_SCENE
    // SCENE-REPLAY: precarga VRAM/paleta/sprite-RAM con un dump de escena de MAME (scene_*.hex,
    // generados por tools/wr_scene_prep.py) para renderizar esa escena SIN boot (jtwrally_game
    // mantiene la CPU en reset y fuerza los vregs). Solo sim.
    // synthesis translate_off
    initial begin
        $readmemh("scene_vram_b0.hex", v0_b0); $readmemh("scene_vram_b1.hex", v0_b1);
        $readmemh("scene_vram_b2.hex", v0_b2); $readmemh("scene_vram_b3.hex", v0_b3);
        $readmemh("scene_vram_b0.hex", v1_b0); $readmemh("scene_vram_b1.hex", v1_b1);
        $readmemh("scene_vram_b2.hex", v1_b2); $readmemh("scene_vram_b3.hex", v1_b3);
        $readmemh("scene_pal_hi.hex", pa_hi);  $readmemh("scene_pal_lo.hex", pa_lo);
        $readmemh("scene_pal_hi.hex", pb_hi);  $readmemh("scene_pal_lo.hex", pb_lo);
        $readmemh("scene_spr_e.hex", sv_e);    $readmemh("scene_spr_o.hex", sv_o);
        $display("WR_SCENE: VRAM/paleta/sprite-RAM precargadas desde scene_*.hex");
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
