// ============================================================================
//  World Rally 2: Twin Racing (Gaelco, Tipo-2 / chip GAE1) — Motor de TILEMAP de UNA capa (LINE-BUFFER).
//
//  Base: aligator_gae1_tilemap (rediseño line-buffer 2026-06-23, validado en HW). El FSM corre a clk
//  pleno (ce=1); al cambiar de línea (start) renderiza la línea `line` COMPLETA en el banco wbank,
//  fetcheando el gfx de cada MEDIA-TILE (8 px) y ESPERANDO gfx_ok (sin LEAD) -> inmune a la latencia
//  variable del árbitro. El display lee lb por X del banco rbank (doble buffer ping-pong).
//
//  DIFERENCIAS WR2 vs aligator (2026-06-26):
//   - 5bpp REAL (plano4 = ic68). El banco ba1 (16MB DW32) tiene los planos 0-3 en la mitad BAJA
//     ({p0,p1,p2,p3}) y el plano4 en la mitad ALTA @0x800000 como DW32 {p4,0,0,0}. El motor hace
//     DOS lecturas por media-tile en el MISMO puerto rom_a/d_p*: read1 (rom_a[21]=0) -> g0..g3;
//     read2 (rom_a[21]=1) -> g4 = d_p0 (byte0 del {p4,0,0,0}). pen = {g4,g3,g2,g1,g0} (5 bits).
//   - ELEMS = 2MB/32 = 65536 -> elemento gfx = code[15:0] (= word1). rom_a = {p4sel, code[15:0], col3, row}.
//   - color (Layer 0) = word0[14:9] (6 bits); el +0x40 de Layer 1 lo aplica el compositor (no aquí).
//   - FIX del pipeline de display (validado en aligator V013): line buffer de 512 (potencia de 2 -> la
//     lectura compensada lb_x=(hpos-14)&0x1ff del compositor nunca sale de rango) + render sx 0..383.
//  Line buffer (12b): {color[6:0], pen[4:0]}. pen 0 -> el compositor deja ver la capa inferior.
// ============================================================================
`default_nettype none

module wrally2_gae1_tilemap (
    input  wire        clk,
    input  wire        ce,           // 1'b1 (FSM a clk pleno)
    input  wire        start,        // pulso: renderiza la línea `line` en wbank
    input  wire [8:0]  line,         // screenY a renderizar (next_vpos)
    input  wire [9:0]  scroll_x,     // x-scroll resuelto para esta línea (xoff + linescroll)
    input  wire [8:0]  scroll_y,     // y-scroll (yoff)
    input  wire [2:0]  bank,         // banco VRAM de la capa = (vregs[L]>>9)&7
    output reg         busy,

    // puerto de par de tile de wrally2_vmem ({word0,word1}), latencia 1 clk
    output reg  [13:0] tp_idx,       // banco*0x800 + tile_index (tile_index = ty*64+tx)
    input  wire [31:0] tp_q,         // {word0[31:16], word1[15:0]}

    // puerto de lectura ROM gfx DW32, handshake gfx_ok. Se usa para DOS lecturas (planos 0-3 y plano4).
    output reg  [21:0] rom_a,        // bit21 = selector mitad alta (plano4) ; [20:0] = elemento
    input  wire [7:0]  d_p0, d_p1, d_p2, d_p3,
    input  wire        gfx_ok,

    // line buffer: lectura async para el compositor (por X visible 0..319, con compensación de pipeline)
    input  wire [9:0]  lb_x,
    output wire [11:0] lb_q,         // {color[6:0], pen[4:0]}

    input  wire        wbank,
    input  wire        rbank
);
    localparam [2:0] IDLE=0, REQ=1, RDTP=2, ATTR=3, WAITG=4, WAITG4=5, PIX=6, DONE=7;

    reg [2:0]  state;
    reg [9:0]  sx;                    // screenX en curso (0..383)
    reg        wbank_r;
    reg [4:0]  ty_r;                  // fila de tile (tmy[8:4]) — constante en la línea
    reg [3:0]  row0_r;                // fila gfx (tmy[3:0]) — constante en la línea
    reg [9:0]  tmx_r;                 // tmx del pixel en curso

    // atributos de la media-tile en curso
    reg [15:0] code_r; reg flipx_r, flipy_r; reg [6:0] color_r;
    reg [20:0] elem_r;                // elemento gfx de la media-tile (para la 2ª lectura del plano4)
    reg [7:0]  g0, g1, g2, g3, g4;    // 5 planos de la media-tile fetcheada

    // ---- line buffer doble (2 x 512 x 12) ----  512 = potencia de 2 -> lb_x=(hpos-14)&0x1ff del compositor
    //  nunca sale de rango (el borde izq lee índices altos no escritos = 0 = backdrop). Compensa el pipeline.
    //  M10K LECTURA REGISTRADA (FIX FIT): la lectura ASÍNCRONA generaba un mux 512:1 enorme (~25K comb ALUTs
    //  en el compositor) + FFs. Patrón canónico 1W/1R registrado (write-enable por estado PIX, read cada clk,
    //  salida registrada lb*_q) -> infiere M10K (0 ALMs). El +1 clk de latencia se asienta DENTRO del periodo
    //  de píxel (lb_x estable 6/3 clk por ce_pix) -> NO desplaza: el compositor sigue con lb_x=(hpos-14).
    //  Validado single-left 0.00% vs mame_left.
    reg [11:0] lb0 [0:511];
    reg [11:0] lb1 [0:511];
    reg [11:0] lb0_q, lb1_q;
    wire lb0_we = (state==PIX) & ~wbank_r;
    wire lb1_we = (state==PIX) &  wbank_r;
    always @(posedge clk) begin
        if (lb0_we) lb0[sx[8:0]] <= lb_wdata;
        lb0_q <= lb0[lb_x[8:0]];                 // lectura registrada -> M10K (read port)
    end
    always @(posedge clk) begin
        if (lb1_we) lb1[sx[8:0]] <= lb_wdata;
        lb1_q <= lb1[lb_x[8:0]];
    end
    assign lb_q = rbank ? lb1_q : lb0_q;

    // tmx del pixel actual y del siguiente (para detectar límite de media-tile)
    wire [9:0] tmx_next = (sx + 10'd1 + scroll_x) & 10'h3ff;
    wire       half_end = (tmx_next[3] != tmx_r[3]);   // cruza límite de 8 px (media-tile/tile)

    // decode del pixel actual (combinacional) — pen de 5 bits {p4,p3,p2,p1,p0}
    wire [3:0] col0 = tmx_r[3:0];
    wire [3:0] col1 = flipx_r ? ~col0 : col0;
    wire [2:0] bbit = 3'd7 - col1[2:0];
    wire [4:0] pen  = {g4[bbit], g3[bbit], g2[bbit], g1[bbit], g0[bbit]};
    wire [11:0] lb_wdata = {color_r, pen};

    // dirección de tile / gfx para el fetch de la media-tile que empieza en sx
    wire [5:0]  tx_f       = tmx_r[9:4];
    wire [10:0] tindex_f   = {ty_r, tx_f};
    wire [15:0] word0      = tp_q[31:16];
    wire [15:0] word1      = tp_q[15:0];
    wire [15:0] code_w     = word1;                     // ELEMS=65536 -> code%ELEMS = word1
    wire        flipx_w    = word0[7];
    wire        flipy_w    = word0[6];
    wire [3:0]  col1_f     = flipx_w ? ~tmx_r[3:0] : tmx_r[3:0];
    wire [3:0]  row1_f     = flipy_w ? ~row0_r     : row0_r;
    wire [20:0] elem_w     = {code_w[15:0], col1_f[3], row1_f};   // byte intra-plano (21b)

    always @(posedge clk) if (ce) begin
        if (start) begin
            wbank_r <= wbank; busy <= 1'b1;
            ty_r    <= (line + scroll_y) >> 4;          // tmy[8:4]
            row0_r  <= (line + scroll_y) & 9'h00f;      // tmy[3:0]
            sx      <= 10'd0;
            tmx_r   <= scroll_x & 10'h3ff;              // tmx del pixel 0
            state   <= REQ;
        end else case (state)
            IDLE: ;
            REQ: begin                                  // pide el par de tile de la media en curso
                tp_idx <= {bank, tindex_f};
                state  <= RDTP;
            end
            RDTP: state <= ATTR;                         // espera 1 clk: tp_idx registrado -> tp_q válido en ATTR
            ATTR: begin                                 // tp_q listo -> attrs -> dirección gfx (read1: planos 0-3)
                code_r  <= code_w; flipx_r <= flipx_w; flipy_r <= flipy_w;
                color_r <= {1'b0, word0[14:9]};         // color 6-bit (Layer 0)
                elem_r  <= elem_w;
                rom_a   <= {1'b0, elem_w};              // mitad baja -> {p0,p1,p2,p3}
                state   <= WAITG;
            end
            WAITG: if (gfx_ok) begin                     // read1 listo -> captura planos 0-3 ; lanza read2 (plano4)
                g0 <= d_p0; g1 <= d_p1;
                // planos 2,3 = 0 en la zona GAP (elem>=0x100000, elem_r[20]=1): el .mra de HW reusa ic70 ahí como
                // don't-care (no puede poner ceros en lanes de un interleave); aquí se descartan. No-op en sim (blob ya 0).
                g2 <= elem_r[20] ? 8'd0 : d_p2;
                g3 <= elem_r[20] ? 8'd0 : d_p3;
                rom_a <= {1'b1, elem_r};                // mitad alta @0x800000 -> {p4,0,0,0}
                state <= WAITG4;
            end
            WAITG4: if (gfx_ok) begin                    // read2 listo -> plano4 = byte0
                g4 <= d_p0;
                state <= PIX;
            end
            PIX: begin                                   // (la escritura del lb la hacen los bloques M10K por lb*_we=state==PIX)
                if (sx == 10'd383) begin
                    state <= DONE;
                end else begin
                    sx    <= sx + 10'd1;
                    tmx_r <= tmx_next;
                    if (half_end) state <= REQ;          // nueva media-tile -> re-fetch
                    // si no, sigue en PIX (misma media-tile, mismo gfx/attrs)
                end
            end
            DONE: begin busy <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end

    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; sx=0; wbank_r=0; code_r=0; lb0_q=0; lb1_q=0;
        for (k=0;k<512;k=k+1) begin lb0[k]=0; lb1[k]=0; end end
    // synthesis translate_on
endmodule

`default_nettype wire
