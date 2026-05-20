const std = @import("std");
const rl = @import("raylib");

const Light = @import("Light.zig");
const noise = @import("noise.zig");

const NCOLS: usize = 21601;
const NROWS: usize = 10801;
const SPHERE_RES: i32 = 250;

const Game = struct {
    alloc: std.mem.Allocator,
    vertices: []f32,
    left_model: rl.Model,
    right_model: rl.Model,
    shader: rl.Shader,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, shader: rl.Shader) !Game {
        var color_image = try rl.loadImage("resources/earth.bmp");
        defer color_image.unload();
        color_image.flipHorizontal();

        const texture = try rl.loadTextureFromImage(color_image);
        rl.setTextureWrap(texture, .repeat);

        const vertices_bytes = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            "resources/earth.bin",
            alloc,
            .limited(NCOLS * NROWS * @sizeOf(f32) + 1),
            .@"4",
            null,
        );
        errdefer alloc.free(vertices_bytes);
        const vertices = std.mem.bytesAsSlice(f32, vertices_bytes);

        const sphere_radius = 40.0;
        const left_mesh = try createGlobeMesh(sphere_radius, SPHERE_RES, SPHERE_RES, 0.0, 0.5, vertices);
        const right_mesh = try createGlobeMesh(sphere_radius, SPHERE_RES, SPHERE_RES, 0.5, 1.0, vertices);

        var left_model = try rl.Model.fromMesh(left_mesh);
        var right_model = try rl.Model.fromMesh(right_mesh);

        left_model.materials[0].shader = shader;
        left_model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture = texture;

        right_model.materials[0].shader = shader;
        right_model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture = texture;

        const ambient: [4]f32 = .{ 0.1, 0.1, 0.1, 1.0 };
        rl.setShaderValue(shader, rl.getShaderLocation(shader, "ambient"), &ambient, .vec4);

        return .{
            .alloc = alloc,
            .vertices = vertices,
            .left_model = left_model,
            .right_model = right_model,
            .shader = shader,
        };
    }

    pub fn deinit(self: *Game) void {
        const tex = self.left_model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture;
        tex.unload();
        self.left_model.unload();
        self.right_model.unload();
        self.alloc.free(std.mem.sliceAsBytes(self.vertices));
    }

    pub fn update(self: *Game) !void {
        self.left_model.draw(.zero(), 1.0, .white);
        self.right_model.draw(.zero(), 1.0, .white);
    }
};

fn createGlobeMesh(radius: f32, rings: i32, slices: i32, u_min: f32, u_max: f32, heightmap: []const f32) !rl.Mesh {
    const v_count: usize = @intCast((rings + 1) * (slices + 1));
    const t_count: usize = @intCast(rings * slices * 2);

    var mesh = std.mem.zeroInit(rl.Mesh, .{
        .vertexCount = @as(i32, @intCast(v_count)),
        .triangleCount = @as(i32, @intCast(t_count)),
    });

    mesh.vertices = @ptrCast(@alignCast(rl.memAlloc(@intCast(v_count * 3 * @sizeOf(f32)))));
    mesh.texcoords = @ptrCast(@alignCast(rl.memAlloc(@intCast(v_count * 2 * @sizeOf(f32)))));
    mesh.normals = @ptrCast(@alignCast(rl.memAlloc(@intCast(v_count * 3 * @sizeOf(f32)))));
    mesh.indices = @ptrCast(@alignCast(rl.memAlloc(@intCast(t_count * 3 * @sizeOf(u16)))));

    for (0..@intCast(rings + 1)) |r| {
        const v = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
        const phi = (v - 0.5) * std.math.pi;
        const sin_phi = std.math.sin(phi);
        const cos_phi = std.math.cos(phi);

        for (0..@intCast(slices + 1)) |s| {
            const u_rel = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(slices));
            const u = u_min + u_rel * (u_max - u_min);
            const theta = (u - 0.5) * 2.0 * std.math.pi;

            const nx = cos_phi * std.math.cos(theta);
            const ny = sin_phi;
            const nz = cos_phi * std.math.sin(theta);

            const u_map = 1.0 - u;
            const v_map = 1.0 - v;
            const col = @as(usize, @intFromFloat(std.math.clamp(u_map, 0, 1) * @as(f32, @floatFromInt(NCOLS - 1))));
            const row = @as(usize, @intFromFloat(std.math.clamp(v_map, 0, 1) * @as(f32, @floatFromInt(NROWS - 1))));

            var h = heightmap[row * NCOLS + col];
            if (h == -99999) h = 0;

            const earth_radius: f32 = 6.371e6;
            const exaggeration = 40.0;
            const elevation = (h / earth_radius) * radius * exaggeration;

            const d = radius + elevation;
            const idx = r * @as(usize, @intCast(slices + 1)) + s;
            mesh.vertices[idx * 3 + 0] = nx * d;
            mesh.vertices[idx * 3 + 1] = ny * d;
            mesh.vertices[idx * 3 + 2] = nz * d;

            mesh.normals[idx * 3 + 0] = nx;
            mesh.normals[idx * 3 + 1] = ny;
            mesh.normals[idx * 3 + 2] = nz;

            mesh.texcoords[idx * 2 + 0] = u;
            mesh.texcoords[idx * 2 + 1] = 1.0 - v;
        }
    }

    var k: usize = 0;
    const s_stride = @as(usize, @intCast(slices + 1));
    for (0..@intCast(rings)) |r| {
        for (0..@intCast(slices)) |s| {
            const _i0 = r * s_stride + s;
            const _i1 = _i0 + 1;
            const _i2 = (r + 1) * s_stride + s;
            const _i3 = _i2 + 1;

            mesh.indices[k + 0] = @intCast(_i0);
            mesh.indices[k + 1] = @intCast(_i2);
            mesh.indices[k + 2] = @intCast(_i1);
            mesh.indices[k + 3] = @intCast(_i1);
            mesh.indices[k + 4] = @intCast(_i2);
            mesh.indices[k + 5] = @intCast(_i3);
            k += 6;
        }
    }

    rl.uploadMesh(&mesh, false);
    return mesh;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    rl.initWindow(1280, 720, "world");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var camera: rl.Camera3D = .{
        .fovy = 90,
        .position = rl.Vector3.one().scale(60),
        .projection = .perspective,
        .up = .init(0, 1, 0),
        .target = .zero(),
    };

    const shader: rl.Shader = try rl.loadShader(
        "resources/shaders/lighting.vert.glsl",
        "resources/shaders/lighting.frag.glsl",
    );
    defer shader.unload();

    var lights: std.ArrayList(Light) = .empty;
    defer lights.deinit(gpa);

    try lights.append(gpa, .init(.directional, rl.Vector3.one().scale(80), .zero(), .yellow, 0.5, shader));
    try lights.append(gpa, .init(.directional, rl.Vector3.one().scale(-80), .zero(), .blue, 0.5, shader));

    var game = try Game.init(gpa, io, shader);
    defer game.deinit();

    while (!rl.windowShouldClose()) {
        if (rl.isMouseButtonDown(.left)) camera.update(.third_person);

        rl.beginDrawing();
        defer rl.endDrawing();

        if (rl.getMouseWheelMove() > 0) camera.fovy *= 1.1;
        if (rl.getMouseWheelMove() < 0) camera.fovy /= 1.1;

        rl.clearBackground(.black);
        rl.setShaderValue(shader, rl.getShaderLocation(shader, "viewPos"), &camera.position, .vec3);

        camera.begin();
        defer camera.end();

        for (lights.items) |l| l.update(shader);

        try game.update();
    }
}
