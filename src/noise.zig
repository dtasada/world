const std = @import("std");

pub const SimplexSphere = struct {
    perm: [512]u8,

    const gradients = [_][3]f32{
        .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 },
        .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 },
        .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 },
    };

    pub fn init(seed: u64) SimplexSphere {
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();

        var p: [256]u8 = undefined;
        for (0..256) |i| p[i] = @intCast(i);

        var i: usize = 255;
        while (i > 0) : (i -= 1) {
            const j = random.uintLessThan(usize, i + 1);
            std.mem.swap(u8, &p[i], &p[j]);
        }

        var perm: [512]u8 = undefined;
        for (0..512) |k| perm[k] = p[k & 255];

        return .{ .perm = perm };
    }

    inline fn dot(g: [3]f32, x: f32, y: f32, z: f32) f32 {
        return g[0] * x + g[1] * y + g[2] * z;
    }

    inline fn fastFloor(x: f32) i32 {
        return if (x >= 0) @intFromFloat(x) else @intFromFloat(x - 1);
    }

    /// raw simplex noise on unit sphere direction
    pub fn sample(self: *const SimplexSphere, x: f32, y: f32, z: f32) f32 {
        const F3: f32 = 1.0 / 3.0;
        const G3: f32 = 1.0 / 6.0;

        const s = (x + y + z) * F3;

        const i = fastFloor(x + s);
        const j = fastFloor(y + s);
        const k = fastFloor(z + s);

        const t = @as(f32, @floatFromInt(i + j + k)) * G3;

        const X0 = @as(f32, @floatFromInt(i)) - t;
        const Y0 = @as(f32, @floatFromInt(j)) - t;
        const Z0 = @as(f32, @floatFromInt(k)) - t;

        const x0 = x - X0;
        const y0 = y - Y0;
        const z0 = z - Z0;

        const ii: usize = @intCast(i & 255);
        const jj: usize = @intCast(j & 255);
        const kk: usize = @intCast(k & 255);

        const gi0 = self.perm[ii + self.perm[jj + self.perm[kk]]] % 12;

        var n0: f32 = 0;

        var t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
        if (t0 > 0) {
            t0 *= t0;
            n0 = t0 * t0 * dot(gradients[gi0], x0, y0, z0);
        }

        return n0 * 32.0;
    }

    pub fn fbm(
        self: *const SimplexSphere,
        x: f32,
        y: f32,
        z: f32,
        frequency: f32,
        amplitude: f32,
        lacunarity: f32,
        persistence: f32,
        octaves: u32,
    ) f32 {
        var freq = frequency;
        var amp = amplitude;

        var sum: f32 = 0;

        var i: u32 = 0;
        while (i < octaves) : (i += 1) {
            sum += self.sample(x * freq, y * freq, z * freq) * amp;

            freq *= lacunarity;
            amp *= persistence;
        }

        return sum;
    }
};
