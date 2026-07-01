// ============================================================================
//  wrally2_inputs.v — ensamblado de puertos de entrada del 68000 (World Rally 2, gaelco2.cpp).
//
//  Mapa MAME (wrally2_state::wrally2_map + INPUT_PORTS(wrally2)) — DISTINTO de aligator:
//    0x300000 IN0 = P1(byte bajo) + DSW2(byte alto)
//    0x300002 IN1 = 0xFF(byte bajo) + DSW1(byte alto)
//    0x300004 IN2 = P2(byte bajo) + COIN(byte alto)
//    0x300006 IN3 = 0xFF(byte bajo) + SERVICE(byte alto)
//
//  IN0[7:0] (P1): b0=UP b1=DOWN b2=RIGHT b3=LEFT b4=Acc(BTN1,act-bajo) b5=Gear(BTN2,act-ALTO,toggle)
//                 b6=ADC_1(serie, lo SOBREESCRIBE wrally2_main con adc1_bit) b7=START1(act-bajo)
//  IN2[7:0] (P2): igual que P1 pero cabina 2 (b6=ADC_2, b7=START2)
//  IN2[15:8] (COIN): b0=COIN1 b2=COIN2 (act-bajo), resto 1
//  IN3[15:8] (SERVICE): b0=SERVICE1 b1=SERVICE3(test mode) b2=SERVICE2 (act-bajo), resto 1
//
//  Polaridad jtframe (act-bajo, 0=pulsado): joystick/Acc/START/coin/service DIRECTOS; Gear es
//  ACTIVO-ALTO en MAME -> se INVIERTE (~joy[5]). joystick jtframe (BUTTONS=2): b0=right b1=left
//  b2=down b3=up b4=BTN1(Acc) b5=BTN2(Gear). (TOGGLE del gear: pendiente; ahora es momentáneo.)
//  El bit6 (ADC) es placeholder aquí; wrally2_main lo sustituye por adc1_bit/adc2_bit al leer.
// ============================================================================
`default_nettype none

module wrally2_inputs (
    input  wire        clk,         // para el toggle de la marcha (Gear = PORT_TOGGLE en MAME)
    input  wire [15:0] dipsw,       // .mra: DSW1 = byte bajo, DSW2 = byte alto
    input  wire [5:0]  joystick1,   // b0=right b1=left b2=down b3=up b4=BTN1 b5=BTN2 (act-bajo)
    input  wire [5:0]  joystick2,   // BUTTONS=2 -> joystick es [5:0] en el build mister (no [6:0])
    input  wire [1:0]  coin,        // coin[0]=coin1 coin[1]=coin2 (act-bajo)
    input  wire [1:0]  start,       // start[0]=start1 start[1]=start2 (act-bajo)
    input  wire        service,     // SERVICE1 (act-bajo)
    input  wire        test,        // SERVICE3 = "go to test mode" (act-bajo); si no hay, atar a 1

    output wire [15:0] port_in0,    // 0x300000  P1 + DSW2
    output wire [15:0] port_in1,    // 0x300002  0xFF + DSW1
    output wire [15:0] port_in2,    // 0x300004  P2 + COIN
    output wire [15:0] port_in3     // 0x300006  0xFF + SERVICE
);
    wire [7:0] dsw1 = dipsw[7:0];
    wire [7:0] dsw2 = dipsw[15:8];

    // Gear = PORT_TOGGLE (act-alto): cada PULSACIÓN (flanco) cambia low<->high; el estado ES el bit.
    reg gear1 = 1'b0, gear2 = 1'b0, b1p = 1'b0, b2p = 1'b0;
    always @(posedge clk) begin
        b1p <= ~joystick1[5]; b2p <= ~joystick2[5];        // pulsado = ~joy[5] (joy act-bajo)
        if (~joystick1[5] & ~b1p) gear1 <= ~gear1;          // flanco de subida (pulsar) -> toggle
        if (~joystick2[5] & ~b2p) gear2 <= ~gear2;
    end

    // P1 byte bajo: {START1, ADC(ph), Gear(toggle act-alto), Acc, LEFT, RIGHT, DOWN, UP}
    wire [7:0] p1 = { start[0], 1'b0, gear1, joystick1[4],
                      joystick1[1], joystick1[0], joystick1[2], joystick1[3] };
    wire [7:0] p2 = { start[1], 1'b0, gear2, joystick2[4],
                      joystick2[1], joystick2[0], joystick2[2], joystick2[3] };

    // COIN (byte alto de IN2): b0=COIN1 b2=COIN2 (act-bajo), resto 1
    wire [7:0] coinb = { 5'b11111, coin[1], 1'b1, coin[0] };
    // SERVICE (byte alto de IN3): b0=SERVICE1 b1=SERVICE3(test) b2=SERVICE2 (act-bajo), resto 1
    wire [7:0] servb = { 5'b11111, 1'b1, test, service };

    assign port_in0 = { dsw2, p1 };
    assign port_in1 = { dsw1, 8'hFF };
    assign port_in2 = { coinb, p2 };
    assign port_in3 = { servb, 8'hFF };
endmodule

`default_nettype wire
