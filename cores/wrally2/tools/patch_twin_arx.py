#!/usr/bin/env python3
# patch_twin_arx.py — enables automatic 8:3 aspect ratio in TWIN mode for World Rally 2.
#
# WHY: World Rally 2 is a dual-monitor cabinet. In this core the OSD "Monitor" option selects
#   Left / Right / Twin (status[14:13]); Twin renders 768 px wide (two 4:3 monitors side by side).
#   The correct pixel aspect for Twin is 8:3, but MiSTer's "Original" aspect uses the core's
#   VIDEO_ARX/ARY (4:3), so without this the user has to set custom_aspect_ratio_1=8:3 in MiSTer.ini
#   by hand and cycle the Aspect Ratio option. This patch makes "Original" resolve to 8:3 in Twin and
#   4:3 in single automatically.
#
# WHAT: injects, right before the `video_freak u_crop(` instance in jtframe's mister target
#   (modules/jtframe/target/mister/hdl/jtframe_mister.sv), a small gated block:
#       `ifdef JTFRAME_TWIN_ARX
#           wire [12:0] freak_arx = status[14] ? 13'd8 : raw_arx;   // twin -> 8:3, single -> 4:3
#           wire [12:0] freak_ary = status[14] ? 13'd3 : raw_ary;
#       `else
#           wire [12:0] freak_arx = raw_arx;
#           wire [12:0] freak_ary = raw_ary;
#       `endif
#   and rewires the instance's .ARX/.ARY from raw_arx/raw_ary to freak_arx/freak_ary.
#   The block is GATED by JTFRAME_TWIN_ARX (defined in cores/wrally2/cfg/macros.def [mister]); other
#   cores don't define it and take the `else`, so behaviour is unchanged for them.
#
# The patch is idempotent (safe to run twice) and only needed to build from source; the prebuilt
# releases/jtwrally2_V010.rbf already has it baked in.
#
# USAGE:
#   python3 cores/wrally2/tools/patch_twin_arx.py <jtcores>/modules/jtframe/target/mister/hdl/jtframe_mister.sv
import sys

MARKER = "JTFRAME_TWIN_ARX"
BLOCK = """`ifdef JTFRAME_TWIN_ARX
// wrally2 twin (status[14]) -> ARX 8:3 (two 4:3 monitors); everything else = core ARX (4:3).
// Gated by macro: other cores don't define JTFRAME_TWIN_ARX and take the `else`.
wire [12:0] freak_arx = status[14] ? 13'd8 : raw_arx;
wire [12:0] freak_ary = status[14] ? 13'd3 : raw_ary;
`else
wire [12:0] freak_arx = raw_arx;
wire [12:0] freak_ary = raw_ary;
`endif

video_freak u_crop("""


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch_twin_arx.py <path-to>/jtframe_mister.sv")
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    if MARKER in src:
        print("already patched (JTFRAME_TWIN_ARX present) — nothing to do")
        return

    if "video_freak u_crop(" not in src:
        sys.exit("ERROR: 'video_freak u_crop(' not found in %s (unexpected jtframe version)" % path)

    # 1) insert the gated freak_arx/ary block just before the video_freak instance
    src = src.replace("video_freak u_crop(", BLOCK, 1)

    # 2) rewire the instance ports from raw_* to freak_*
    replaced = 0
    for a, b in ((".ARX        ( raw_arx       )", ".ARX        ( freak_arx     )"),
                 (".ARY        ( raw_ary       )", ".ARY        ( freak_ary     )")):
        if a in src:
            src = src.replace(a, b, 1)
            replaced += 1
    if replaced != 2:
        sys.exit("ERROR: could not rewire .ARX/.ARY ports (%d/2) — check jtframe_mister.sv formatting" % replaced)

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(src)
    print("patched OK: JTFRAME_TWIN_ARX block inserted + .ARX/.ARY rewired to freak_arx/freak_ary")


if __name__ == "__main__":
    main()
