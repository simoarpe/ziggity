//! The classic rotating ASCII torus (the "donut"), as a pure computation: given
//! a frame number and a grid size it fills a caller-provided buffer with a shade
//! level per cell. No allocation, no rendering, no terminal knowledge — the UI
//! layer maps levels to glyphs/colours and blits them. Based on Andy Sloane's
//! donut.c (https://www.a1k0n.net/2011/07/20/donut-math.html).
const std = @import("std");

/// Luminance ramp, dim -> bright. A non-empty cell's level indexes this as
/// `shades[level - 1]`.
pub const shades = ".,-~:;=!*#$@";

/// The brightest level a cell can hold (also the length of `shades`).
pub const max_level = shades.len;

/// Render one frame into `out`: shade levels where 0 means "empty" and 1..=`max_level`
/// is increasing brightness. `depth` is a caller-owned z-buffer scratch; both
/// slices must be at least `w * h` long. Pure and allocation-free.
pub fn render(frame: usize, w: usize, h: usize, depth: []f32, out: []u8) void {
    std.debug.assert(out.len >= w * h and depth.len >= w * h);
    @memset(out[0 .. w * h], 0);
    @memset(depth[0 .. w * h], 0);
    if (w == 0 or h == 0) return;

    const ff: f32 = @floatFromInt(frame);
    const a = ff * 0.05; // rotation about the x-axis
    const b = ff * 0.025; // rotation about the z-axis
    const sin_a = @sin(a);
    const cos_a = @cos(a);
    const sin_b = @sin(b);
    const cos_b = @cos(b);

    const r1: f32 = 1.0; // tube radius
    const r2: f32 = 2.0; // ring radius
    const k2: f32 = 6.0; // viewer distance
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const cx = wf / 2.0;
    const cy = hf / 2.0;
    // Fit the projected donut inside the grid; the vertical scale is halved
    // because terminal cells are roughly twice as tall as they are wide.
    const k1 = @min(wf * k2 / (2.4 * (r1 + r2)), hf * k2 / (1.2 * (r1 + r2)));

    var theta: f32 = 0;
    while (theta < 6.2832) : (theta += 0.10) {
        const ct = @cos(theta);
        const stt = @sin(theta);
        const circlex = r2 + r1 * ct;
        const circley = r1 * stt;
        var phi: f32 = 0;
        while (phi < 6.2832) : (phi += 0.03) {
            const cp = @cos(phi);
            const sp = @sin(phi);
            const x = circlex * (cos_b * cp + sin_a * sin_b * sp) - circley * cos_a * sin_b;
            const y = circlex * (sin_b * cp - sin_a * cos_b * sp) + circley * cos_a * cos_b;
            const z = k2 + cos_a * circlex * sp + circley * sin_a;
            const ooz = 1.0 / z;
            const xpf = cx + k1 * ooz * x;
            const ypf = cy - (k1 * 0.5) * ooz * y;
            if (xpf < 0 or ypf < 0) continue;
            const xp: usize = @intFromFloat(xpf);
            const yp: usize = @intFromFloat(ypf);
            if (xp >= w or yp >= h) continue;
            const lum = cp * ct * sin_b - cos_a * ct * sp - sin_a * stt + cos_b * (cos_a * stt - ct * sin_a * sp);
            if (lum <= 0) continue;
            const idx = yp * w + xp;
            if (ooz <= depth[idx]) continue;
            depth[idx] = ooz;
            var li: usize = @intFromFloat(lum * 8.0);
            if (li >= max_level) li = max_level - 1;
            out[idx] = @intCast(li + 1); // +1 so 0 stays "empty"
        }
    }
}

test "render fills a plausible donut within bounds" {
    const w = 40;
    const h = 20;
    var out: [w * h]u8 = undefined;
    var depth: [w * h]f32 = undefined;
    render(0, w, h, &depth, &out);

    var lit: usize = 0;
    var max_seen: u8 = 0;
    for (out) |level| {
        if (level == 0) continue;
        lit += 1;
        try std.testing.expect(level <= max_level); // never out of the ramp
        max_seen = @max(max_seen, level);
    }
    // A frame-0 donut lights a healthy fraction of the grid, but never all of it.
    try std.testing.expect(lit > 20);
    try std.testing.expect(lit < w * h);
    try std.testing.expect(max_seen >= 1);
}

test "an empty grid is a no-op" {
    var out: [0]u8 = undefined;
    var depth: [0]f32 = undefined;
    render(3, 0, 0, &depth, &out); // must not divide by zero or index anything
}
