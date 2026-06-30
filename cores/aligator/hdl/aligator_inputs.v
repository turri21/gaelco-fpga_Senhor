// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 gaelco2.cpp) — ensamblado de puertos de entrada del 68000.
//
//  Mapa MAME (gaelco2.cpp alighunt_map + INPUT_PORTS(alighunt)) — TODO ACTIVO-BAJO (0=pulsado):
//    0x300000 IN0 = DSW1(byte alto) + P1(byte bajo)
//    0x300002 IN1 = DSW2(byte alto) + P2(byte bajo)
//    0x320000 COIN = monedas + servicio
//
//  IN0[7:0]  (P1): b0=up b1=down b2=right b3=left b4=BTN1 b5=BTN2 b6=BTN3 b7=START1
//  IN0[15:8] (DSW1): b0-3 Coin A (SW1:1-4), b4-7 Coin B (SW1:5-8)
//  IN1[7:0]  (P2): b0=up b1=down b2=right b3=left b4=BTN1 b5=BTN2 b6=BTN3 b7=START2
//  IN1[15:8] (DSW2): b0-1 Difficulty, b2-3 Lives, b4 Sound(mono/stereo), b5 Demo Sounds,
//                    b6 Joystick(analog/std), b7 Service Mode (SW2:8)
//  COIN: b0=COIN1 b1=COIN2 b4=SERVICE2(test mode now) b5=SERVICE1 ; resto=1
//
//  Convención de polaridad (validada en thoop/squash en HW, 2026-06-22): jtframe entrega
//  joystick/coin/start/service ACTIVO-BAJO -> se montan DIRECTOS (sin invertir). El byte alto
//  no mapeado va a 0xFF (activo-bajo = no pulsado). joystick jtframe: b0=right b1=left b2=down
//  b3=up b4=BTN1 b5=BTN2 b6=BTN3 (JTFRAME_BUTTONS=3).
// ============================================================================
`default_nettype none

module aligator_inputs (
    // DIP (de la .mra; DSW1 = byte bajo, DSW2 = byte alto)
    input  wire [15:0] dipsw,
    // jtframe activo-bajo (0 = pulsado)
    input  wire [6:0]  joystick1,   // b0=right b1=left b2=down b3=up b4=BTN1 b5=BTN2 b6=BTN3
    input  wire [6:0]  joystick2,
    input  wire [1:0]  coin,        // coin[0]=coin1 coin[1]=coin2
    input  wire [1:0]  start,       // start[0]=start1 start[1]=start2
    input  wire        service,     // boton de servicio (-> COIN bit5 = SERVICE1)

    output wire [15:0] port_in0,    // 0x300000  DSW1 + P1
    output wire [15:0] port_in1,    // 0x300002  DSW2 + P2
    output wire [15:0] port_coin    // 0x320000  monedas + servicio
);
    wire [7:0] dsw1 = dipsw[7:0];
    wire [7:0] dsw2 = dipsw[15:8];

    // P1 byte bajo: {START1, BTN3, BTN2, BTN1, left, right, down, up}
    wire [7:0] p1 = { start[0], joystick1[6], joystick1[5], joystick1[4],
                      joystick1[1], joystick1[0], joystick1[2], joystick1[3] };
    // P2 byte bajo: {START2, BTN3, BTN2, BTN1, left, right, down, up}
    wire [7:0] p2 = { start[1], joystick2[6], joystick2[5], joystick2[4],
                      joystick2[1], joystick2[0], joystick2[2], joystick2[3] };

    assign port_in0 = { dsw1, p1 };    // DSW1 en byte alto, P1 en byte bajo
    assign port_in1 = { dsw2, p2 };    // DSW2 en byte alto, P2 en byte bajo

    // COIN: b0=coin1 b1=coin2 b2,b3=1 b4=SERVICE2(=1, no usado) b5=SERVICE1(boton) b15:6=1
    assign port_coin = { 10'h3FF, service, 1'b1, 1'b1, 1'b1, coin[1], coin[0] };
endmodule

`default_nettype wire
