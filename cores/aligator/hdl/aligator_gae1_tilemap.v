// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — Motor de TILEMAP de UNA capa (LINE-BUFFER).
//
//  REDISEÑO (2026-06-23): de prefetch on-the-fly con LEAD fijo  ->  RENDERIZADO POR LÍNEA a
//  un line buffer doble (ping-pong), igual que aligator_gae1_sprite (probado limpio en HW).
//  Motivo: el prefetch antiguo asumía latencia SDRAM FIJA (LEAD=7); con 4 clientes en el banco
//  gfx (gfx0+gfx1+gfxs+snd) la latencia es VARIABLE (árbitro+refresh) -> gl/gh rancios -> el
//  gradiente del POST salía revuelto (sim Verilator lo reproducía: golden=0, HW=SIM=16 inversiones).
//
//  Modelo: el FSM corre a clk pleno (ce=1). Al cambiar de línea (start) renderiza la línea `line`
//  COMPLETA (320 px visibles) en el banco wbank, fetcheando el gfx de cada MEDIA-TILE (8 px) y
//  ESPERANDO gfx_ok (sin LEAD) -> inmune a la latencia variable. El display lee lb por X (hpos)
//  del banco rbank. Doble buffer: render(line=next_vpos, wbank) mientras display(vpos, rbank).
//
//  Formato de tile GAE1 (= versión antigua, validada): par {word0,word1} en aligator_vmem;
//    code={word0[2:0],word1} (19b; alighunt ≤17b), color=word0[15:9], flipx=word0[7], flipy=word0[6].
//    gfx 16x16 5bpp (plano5=0): rom_a (elemento DW32) = {code[16:0], col[3], row}. pen 0 = transparente.
//    Una media-tile (col[3] fijo) cubre 8 px que comparten rom_a; el bit = 7-(col&7).
//  Line buffer (12b): {color[6:0], pen[4:0]}. pen 0 -> el compositor deja ver la capa inferior.
// ============================================================================
`default_nettype none

module aligator_gae1_tilemap (
    input  wire        clk,
    input  wire        ce,           // 1'b1 (FSM a clk pleno)
    input  wire        start,        // pulso: renderiza la línea `line` en wbank
    input  wire [8:0]  line,         // screenY a renderizar (next_vpos)
    input  wire [9:0]  scroll_x,     // x-scroll resuelto para esta línea (xoff + linescroll)
    input  wire [8:0]  scroll_y,     // y-scroll (yoff)
    input  wire [2:0]  bank,         // banco VRAM de la capa = (vregs[L]>>9)&7
    output reg         busy,

    // puerto de par de tile de aligator_vmem ({word0,word1}), latencia 1 clk
    output reg  [13:0] tp_idx,       // banco*0x800 + tile_index (tile_index = ty*64+tx)
    input  wire [31:0] tp_q,         // {word0[31:16], word1[15:0]}

    // puerto de lectura ROM gfx (4 planos DW32), handshake gfx_ok
    output reg  [21:0] rom_a,        // elemento DW32 intra-plano
    input  wire [7:0]  d_p0, d_p1, d_p2, d_p3,
    input  wire        gfx_ok,

    // line buffer: lectura async para el compositor (por X visible 0..319)
    input  wire [9:0]  lb_x,
    output wire [11:0] lb_q,         // {color[6:0], pen[4:0]}

    input  wire        wbank,
    input  wire        rbank
);
    localparam [2:0] IDLE=0, REQ=1, RDTP=2, ATTR=3, WAITG=4, PIX=5, DONE=6;

    reg [2:0]  state;
    reg [9:0]  sx;                    // screenX en curso (0..320)
    reg        wbank_r;
    reg [4:0]  ty_r;                  // fila de tile (tmy[8:4]) — constante en la línea
    reg [3:0]  row0_r;                // fila gfx (tmy[3:0]) — constante en la línea
    reg [9:0]  tmx_r;                 // tmx del pixel en curso

    // atributos de la media-tile en curso
    reg [18:0] code_r; reg flipx_r, flipy_r; reg [6:0] color_r;
    reg [7:0]  g0, g1, g2, g3;        // 4 planos de la media-tile fetcheada
`ifdef ALIGATOR_SWAPTRACE
    reg [12:0] swtn = 0;
`endif

    // ---- line buffer doble (2 x 512 x 12) ----  512 = potencia de 2 -> lb_x=(hpos-14)&0x1ff nunca sale de
    // rango (el borde izq lee índices altos no escritos = 0 = backdrop, igual que en sim). Compensa el pipeline.
    reg [11:0] lb0 [0:511];
    reg [11:0] lb1 [0:511];
    assign lb_q = rbank ? lb1[lb_x] : lb0[lb_x];

    // tmx del pixel actual y del siguiente (para detectar límite de media-tile)
    wire [9:0] tmx_next = (sx + 10'd1 + scroll_x) & 10'h3ff;
    wire       half_end = (tmx_next[3] != tmx_r[3]);   // cruza límite de 8 px (media-tile/tile)

    // decode del pixel actual (combinacional)
    wire [3:0] col0 = tmx_r[3:0];
    wire [3:0] col1 = flipx_r ? ~col0 : col0;
    wire [2:0] bbit = 3'd7 - col1[2:0];
    wire [4:0] pen  = {1'b0, g3[bbit], g2[bbit], g1[bbit], g0[bbit]};   // plano5=0
    wire [11:0] lb_wdata = {color_r, pen};

    // dirección de tile / gfx para el fetch de la media-tile que empieza en sx
    wire [5:0]  tx_f       = tmx_r[9:4];
    wire [10:0] tindex_f   = {ty_r, tx_f};
    wire [15:0] word0      = tp_q[31:16];
    wire [15:0] word1      = tp_q[15:0];
    wire [18:0] code_w     = {word0[2:0], word1};
    wire        flipx_w    = word0[7];
    wire        flipy_w    = word0[6];
    wire [3:0]  col1_f     = flipx_w ? ~tmx_r[3:0] : tmx_r[3:0];
    wire [3:0]  row1_f     = flipy_w ? ~row0_r     : row0_r;

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
            ATTR: begin                                 // tp_q listo -> attrs -> dirección gfx
                code_r  <= code_w; flipx_r <= flipx_w; flipy_r <= flipy_w;
                color_r <= word0[15:9];
                rom_a   <= {code_w[16:0], col1_f[3], row1_f};
                state   <= WAITG;
            end
            WAITG: if (gfx_ok) begin                     // espera el dato (sin LEAD) -> inmune a latencia
                g0 <= d_p0; g1 <= d_p1; g2 <= d_p2; g3 <= d_p3;
                state <= PIX;
`ifdef ALIGATOR_SWAPTRACE
                // TRAZA: rom_a (elemento gfx) + 4 bytes de plano devueltos -> mapear al elemento del blob en python
                if (rom_a[21:9]==13'h1d01 && swtn<13'd60) begin
                    $display("SWAPTRACE rom_a=%06x dp=%02x%02x%02x%02x", rom_a, d_p3,d_p2,d_p1,d_p0);
                    swtn <= swtn + 1;
                end
`endif
            end
            PIX: begin                                   // escribe el pixel actual y avanza
                if (wbank_r) lb1[sx[8:0]] <= lb_wdata; else lb0[sx[8:0]] <= lb_wdata;
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

`ifdef ALIGATOR_TMTRACE
    // DIAG: reporta cuánto avanza el render por línea (max sx) y si quedó BUSY al empezar la siguiente.
    reg [9:0] dbg_maxsx=0; reg [9:0] dbg_n=0;
    always @(posedge clk) if (ce) begin
        if (start) begin
            if (dbg_n<10'd24 && (busy || dbg_maxsx!=10'd319)) begin
                $display("TMTRACE scroll=%0d: prev_line maxsx=%0d busy=%b state=%0d", scroll_x, dbg_maxsx, busy, state);
                dbg_n <= dbg_n + 10'd1;
            end
            dbg_maxsx <= 10'd0;
        end else if (state==PIX && sx>dbg_maxsx) dbg_maxsx <= sx;
    end
`endif

    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; sx=0; wbank_r=0; code_r=0;
        for (k=0;k<512;k=k+1) begin lb0[k]=0; lb1[k]=0; end end
    // synthesis translate_on
endmodule

`default_nettype wire
