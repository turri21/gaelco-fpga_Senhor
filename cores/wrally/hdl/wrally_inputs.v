// ============================================================================
//  World Rally (Gaelco) — mapeo de ENTRADAS a los puertos del 68000 (BLOQUE 4).
//
//  Toma botones NOMBRADOS (activo-alto, 1 = pulsado; el wrapper MiSTer los saca del
//  joystick/teclado) y produce las 4 palabras de puerto que lee el 68000, con el
//  layout EXACTO de `wrally.cpp` INPUT_PORTS (todo ACTIVO-BAJO salvo donde se indica).
//  Modo **JOYSTICK** (decisión de proyecto): dirección digital, sin ADC/volante.
//
//    700000 DSW      = los 16 DIP (se pasan tal cual desde el OSD)
//    700002 P1_P2    = direcciones, botones, monedas, starts (ver bits abajo)
//    700004 WHEEL    = 0xFFFF en modo joystick (el dial va condicionado por DSW)
//    700008 SYSTEM   = service/test + (bits 2/3 = ADC, =0 en joystick)
//
//  Combinacional puro -> 100% verificable (ver tb_inputs).
// ============================================================================
`default_nettype none

module wrally_inputs (
    // DIP switches (16) desde el OSD del core
    input  wire [15:0] dsw,

    // --- jugador 1 (activo-alto: 1 = pulsado) ---
    input  wire p1_up, p1_down, p1_left, p1_right,
    input  wire p1_btn1,       // acelerar/disparo
    input  wire p1_gear,       // cambio de marcha (BUTTON2, toggle en HW)
    // --- jugador 2 ---
    input  wire p2_up, p2_down, p2_left, p2_right,
    input  wire p2_btn1,
    input  wire p2_gear,
    // --- sistema ---
    input  wire coin1, coin2,
    input  wire start1, start2,
    input  wire service,       // SERVICE1
    input  wire test,          // SERVICE2 (entra en test mode)

    // --- puertos hacia el 68000 (activo-bajo) ---
    output wire [15:0] port_dsw,
    output wire [15:0] port_p1p2,
    output wire [15:0] port_wheel,
    output wire [15:0] port_system
);
    // DSW: tal cual (los DIP son activo-bajo por convención; el OSD ya entrega el
    // valor con ese sentido). 0xFFFF = todos en su posición "por defecto/off".
    assign port_dsw = dsw;

    // P1_P2 (0x700002), todo ACTIVO-BAJO -> bit = ~pulsado
    assign port_p1p2 = ~{
        start2,            // [15] START2
        start1,            // [14] START1
        p2_btn1,           // [13] P2 BUTTON1
        p2_gear,           // [12] P2 BUTTON2 (gear)
        p2_left,           // [11] P2 LEFT
        p2_right,          // [10] P2 RIGHT
        p2_down,           // [ 9] P2 DOWN
        p2_up,             // [ 8] P2 UP
        coin2,             // [ 7] COIN2
        coin1,             // [ 6] COIN1
        p1_btn1,           // [ 5] P1 BUTTON1
        p1_gear,           // [ 4] P1 BUTTON2 (gear)
        p1_left,           // [ 3] P1 LEFT
        p1_right,          // [ 2] P1 RIGHT
        p1_down,           // [ 1] P1 DOWN
        p1_up              // [ 0] P1 UP
    };

    // WHEEL (0x700004): en modo joystick no se usa el dial -> reposo 0xFFFF.
    assign port_wheel = 16'hFFFF;

    // SYSTEM (0x700008): [0]=SERVICE1, [1]=SERVICE2(test) activo-bajo;
    // [2],[3] = bits del ADC (ACTIVO-ALTO CUSTOM) -> 0 en modo joystick;
    // [15:4] sin uso, activo-bajo -> 1.
    assign port_system = { 12'hFFF, 2'b00, ~test, ~service };

endmodule

`default_nettype wire
