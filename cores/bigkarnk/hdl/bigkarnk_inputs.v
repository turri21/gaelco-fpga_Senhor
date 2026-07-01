// ============================================================================
//  Big Karnak (Gaelco) — ensamblado de puertos de entrada del 68000.
//
//  Mapa MAME (gaelco.cpp bigkarnk_map + INPUT_PORTS(bigkarnk, via gaelco)):
//    0x700000 DSW1   0x700002 DSW2   0x700004 P1   0x700006 P2   0x700008 SERVICE
//    (todos ACTIVO-BAJO)
//
//  P1: b0=up b1=down b2=right b3=left b4=BTN2 b5=BTN1 b6=COIN1 b7=COIN2
//  P2: b0=up b1=down b2=right b3=left b4=BTN2 b5=BTN1 b6=START1 b7=START2
//  DSW1: b0-3 Coin A, b4-7 Coin B.
//  DSW2: b0-2 Difficulty, b3-4 Lives, b5 Demo Sounds, b6 Impact, b7 Service Mode.
//  SERVICE: b0=SERVICE1, b1="Go to test mode now" (dip), b2-7 sin usar.
//
//  Entradas en formato jtframe ACTIVO-BAJO (0=pulsado), igual que los puertos del 68k.
//  joystick jtframe: b0=right b1=left b2=down b3=up b4=BTN1 b5=BTN2.
// ============================================================================
`default_nettype none

module bigkarnk_inputs (
    // DIP (de la .mra; DSW1 = byte bajo, DSW2 = byte alto)
    input  wire [15:0] dipsw,
    // jtframe activo-bajo (0 = pulsado)
    input  wire [5:0]  joystick1,   // b0=right b1=left b2=down b3=up b4=BTN1 b5=BTN2
    input  wire [5:0]  joystick2,
    input  wire [1:0]  coin,        // coin[0]=coin1 coin[1]=coin2
    input  wire [1:0]  start,       // start[0]=start1 start[1]=start2
    input  wire        service,     // boton de servicio (SERVICE1, activo-bajo)

    output wire [15:0] port_dsw1,
    output wire [15:0] port_dsw2,
    output wire [15:0] port_p1,
    output wire [15:0] port_p2,
    output wire [15:0] port_service
);
    wire [7:0] dsw1 = dipsw[7:0];
    wire [7:0] dsw2 = dipsw[15:8];

    // DSW puros (byte alto = 0xFF, bits sin mapear activo-bajo). DSW2:7 = Service Mode (dip).
    assign port_dsw1 = {8'hFF, dsw1};
    assign port_dsw2 = {8'hFF, dsw2};

    // P1: {coin2,coin1,btn2,btn1,left,right,down,up} (todos activo-bajo)
    assign port_p1 = {8'hFF, coin[1], coin[0],
                      joystick1[5], joystick1[4], joystick1[1], joystick1[0], joystick1[2], joystick1[3]};
    // P2: {start2,start1,btn2,btn1,left,right,down,up}
    assign port_p2 = {8'hFF, start[1], start[0],
                      joystick2[5], joystick2[4], joystick2[1], joystick2[0], joystick2[2], joystick2[3]};

    // SERVICE: b0 = SERVICE1 (boton), b1 = "test mode now" dip (off=1), resto sin usar (1).
    assign port_service = {8'hFF, 6'b111111, 1'b1, service};
endmodule

`default_nettype wire
