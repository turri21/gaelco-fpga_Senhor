// ============================================================================
//  BigKarnak (Gaelco) — bigkarnk_video.v: compositor de los 2 tilemaps (Tipo-1).
//
//  Instancia 2 bigkarnk_tilemap (L0, L1) con scroll aplicado y resuelve la PRIORIDAD
//  multipasada de screen_update_bigkarnk (gaelco_v.cpp:250-292) por PIXEL via una tabla
//  de RANGO (orden painter's back->front; gana el rango mas alto).
//
//  Split-pen (set_transmask 0xff01/0x00ff): cada pixel de tile es
//    pen 0      -> transparente
//    pen 1-7    -> "front" (LAYER0)
//    pen 8-15   -> "back"  (LAYER1)   (isback = pen[3])
//  Rango por (capa T, isback, categoria) = posicion en el orden de dibujo de MAME
//  (cat3 abajo .. cat0 arriba; con el reorden de cat1 donde se intercalan sprites).
//  ⚠️ MAME marca la prioridad como NO verificada -> CALIBRAR contra captura.
//
//  Scroll (set_scrolly/set_scrollx): L0 sx=vregs[1]+4 sy=vregs[0]; L1 sx=vregs[3] sy=vregs[2].
//  Salida: indice de paleta del ganador (color*16+pen, 10b) + rango (para mezcla de sprite).
// ============================================================================
`default_nettype none

module bigkarnk_video (
    input  wire        clk,
    input  wire        ce,           // ce_pix
    input  wire [8:0]  hpos,         // 0..319
    input  wire [8:0]  vpos,         // 0..239

    input  wire [15:0] vreg_l0y, vreg_l0x, vreg_l1y, vreg_l1x,

    // tilemap L0 (videoram + gfx)
    output wire [10:0] tile_a0, input wire [31:0] tile_q0,
    output wire [19:0] rom_a0,  input wire [7:0] d0_p0, d0_p1, d0_p2, d0_p3, input wire gfx0_ok,
    // tilemap L1
    output wire [10:0] tile_a1, input wire [31:0] tile_q1,
    output wire [19:0] rom_a1,  input wire [7:0] d1_p0, d1_p1, d1_p2, d1_p3, input wire gfx1_ok,

    // salida (registrada, alineada): indice de paleta del ganador + rango + opaco
    output reg  [9:0]  pal_index,    // color*16 + pen (0..1023). 0 = backdrop
    output reg  [4:0]  win_rank,     // rango del pixel ganador (para mezcla con sprite)
    output reg  [3:0]  win_prio,     // buffer de prioridad = OR de pcodes (mecanismo MAME pri_mask)
    output reg         win_opaque
);
    // ---- scroll: coordenada de tilemap (512x512, wrap) ----
    // +16 vertical = la visarea Y de MAME empieza en 16 (igual que el sprite layer ya hace). FIX HW: el
    // tilemap salia 16px desplazado abajo (franja negra arriba) por no aplicar este offset.
    // tilemap +1px a la DERECHA (medido vs MAME 0193: el tilemap salia 1px a la izquierda; sprites OK).
    // Se baja el offset en 1 en AMBAS capas (preserva el relativo L0-L1 = +4).
    // Offsets golden: L0 sx=vregs[1]+4, L1 sx=vregs[3]+0. El pipeline del tilemap añade +1px
    // -> se compensa con -1 en el codigo (medido: dx=-1 alinea el centro a 6.5%). => +3 / -1.
    wire [8:0] tmx0 = hpos + vreg_l0x[8:0] + 9'd3;
    wire [8:0] tmy0 = vpos + vreg_l0y[8:0] + 9'd16;
    wire [8:0] tmx1 = hpos + vreg_l1x[8:0] - 9'd1;
    wire [8:0] tmy1 = vpos + vreg_l1y[8:0] + 9'd16;

    // ---- 2 tilemaps (misma latencia -> salidas alineadas) ----
    wire [3:0] pen0, pen1; wire [5:0] color0, color1; wire [1:0] cat0, cat1;
    bigkarnk_tilemap u_l0 (
        .clk(clk), .ce(ce), .tmx(tmx0), .tmy(tmy0), .layer(1'b0),
        .tile_a(tile_a0), .tile_q(tile_q0),
        .rom_a(rom_a0), .d_p0(d0_p0), .d_p1(d0_p1), .d_p2(d0_p2), .d_p3(d0_p3), .gfx_ok(gfx0_ok),
        .dbg_hpos(hpos),
        .pen(pen0), .color(color0), .category(cat0)
    );
    bigkarnk_tilemap u_l1 (
        .clk(clk), .ce(ce), .tmx(tmx1), .tmy(tmy1), .layer(1'b1),
        .tile_a(tile_a1), .tile_q(tile_q1),
        .rom_a(rom_a1), .d_p0(d1_p0), .d_p1(d1_p1), .d_p2(d1_p2), .d_p3(d1_p3), .gfx_ok(gfx1_ok),
        .dbg_hpos(hpos),
        .pen(pen1), .color(color1), .category(cat1)
    );

    // ---- rango painter's FIEL a screen_update_bigkarnk (= golden _SEQ): orden de dibujo 0..15
    //   (mayor = mas arriba). base=(3-cat)*4 ; dentro de cada cat: L1back,L0back,L1front,L0front.
    function [4:0] rank;
        input        t;        // 0=L0, 1=L1
        input        isback;   // 1 = pen 8-15 (LAYER1/back), 0 = pen 1-7 (LAYER0/front)
        input [1:0]  cat;
        reg   [4:0]  base; reg [1:0] off;
        begin
            base = ({3'd0,(2'd3 - cat)}) << 2;          // cat3->0 cat2->4 cat1->8 cat0->12
            off  = (isback ? 2'd0 : 2'd2) + (t ? 2'd0 : 2'd1);  // L1b,L0b,L1f,L0f = 0,1,2,3
            rank = base + {3'd0, off};
        end
    endfunction

    // ---- pcode FIEL (= golden pcode): buffer de prioridad de MAME (screen.priority()) ----
    //   front(pen1-7): cat3->1 cat2->2 cat1->4 cat0->8 ; back(pen8-15): cat3->0 cat2->1 cat1->2 cat0->4
    function [3:0] pcode;
        input        isback;
        input [1:0]  cat;
        begin
            if (!isback) case (cat) 2'd3:pcode=4'd1; 2'd2:pcode=4'd2; 2'd1:pcode=4'd4; default:pcode=4'd8; endcase
            else         case (cat) 2'd3:pcode=4'd0; 2'd2:pcode=4'd1; 2'd1:pcode=4'd2; default:pcode=4'd4; endcase
        end
    endfunction

`ifdef BIGKARNK_L1ONLY
    wire op0 = 1'b0;                 // diag: solo capa L1
`elsif BIGKARNK_L0ONLY
    wire op0 = (pen0 != 4'd0);
`else
    wire op0 = (pen0 != 4'd0);
`endif
`ifdef BIGKARNK_L0ONLY
    wire op1 = 1'b0;                 // diag: solo capa L0
`else
    wire op1 = (pen1 != 4'd0);
`endif

`ifdef BIGKARNK_LINETRACE
    // DIAG: traza pen0/op0 por hpos en una scanline de barras (vpos fijo) -> patron de huecos en X.
    always @(posedge clk) if (ce && vpos==9'd85) begin
        $display("LT hpos=%0d pen0=%h op0=%b col0=%h g0ok=%b rom0=%h ta0=%h", hpos, pen0, op0, color0, gfx0_ok, rom_a0, tile_a0);
    end
`endif
`ifdef SIMULATION
    integer n_ce=0, n_g0=0, n_g1=0, n_op0=0, n_op1=0;
    always @(posedge clk) if (ce) begin
        n_ce<=n_ce+1;
        if (gfx0_ok) n_g0<=n_g0+1;
        if (gfx1_ok) n_g1<=n_g1+1;
        if (op0) n_op0<=n_op0+1;
        if (op1) n_op1<=n_op1+1;
        if (n_ce[18:0]==0) $display("VIDDBG ce=%0d g0ok=%0d g1ok=%0d op0=%0d op1=%0d | pen0=%h pen1=%h col0=%h col1=%h gfx0d=%h rom0=%h",
            n_ce, n_g0, n_g1, n_op0, n_op1, pen0, pen1, color0, color1, {d0_p3,d0_p2,d0_p1,d0_p0}, rom_a0);
    end
`endif
    wire [4:0] r0 = rank(1'b0, pen0[3], cat0);
    wire [4:0] r1 = rank(1'b1, pen1[3], cat1);
    // buffer de prioridad = OR de los pcodes de TODOS los tiles opacos en el pixel (= golden prio[o])
    wire [3:0] pc0 = op0 ? pcode(pen0[3], cat0) : 4'd0;
    wire [3:0] pc1 = op1 ? pcode(pen1[3], cat1) : 4'd0;
    wire [3:0] prio_buf = pc0 | pc1;

    // gana el opaco de mayor rango; si ambos transparentes -> backdrop (indice 0)
    wire l0_wins = op0 & (~op1 | (r0 >= r1));
    always @(posedge clk) if (ce) begin
        win_prio <= prio_buf;
        if (op0 & l0_wins) begin
            pal_index <= {color0, pen0}; win_rank <= r0; win_opaque <= 1'b1;
        end else if (op1) begin
            pal_index <= {color1, pen1}; win_rank <= r1; win_opaque <= 1'b1;
        end else begin
            pal_index <= 10'd0; win_rank <= 5'd0; win_opaque <= 1'b0;
        end
    end
endmodule

`default_nettype wire
