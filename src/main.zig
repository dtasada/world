const std = @import("std");
const rl = @import("raylib");

const Light = @import("Light.zig");
const noise = @import("noise.zig");

const NCOLS: usize = 21601;
const NROWS: usize = 10801;
const SPHERE_RES: i32 = 128;

const Game = struct {
    alloc: std.mem.Allocator,
    vertices: []f32,
    map: struct {
        model: rl.Model,
    },
    camera: rl.Camera2D,
    shader: rl.Shader,
    colors: struct {
        map: []rl.Color,
        width: usize,
        height: usize,
    },

    pub fn init(alloc: std.mem.Allocator, io: std.Io, shader: rl.Shader) !Game {
        const color_image = try rl.loadImage("resources/earth.bmp");
        defer color_image.unload();
        const color_map = try rl.loadImageColors(color_image);

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

        var self: Game = .{
            .alloc = alloc,
            .vertices = vertices,
            .map = .{ .model = undefined },
            .camera = .{
                .offset = .zero(),
                .rotation = 0.0,
                .target = .zero(),
                .zoom = 1.0,
            },
            .shader = shader,
            .colors = .{
                .map = color_map,
                .width = @intCast(color_image.width),
                .height = @intCast(color_image.height),
            },
        };

        try self.genMapTexture();

        const ambient: [4]f32 = .{ 0.1, 0.1, 0.1, 1.0 };
        rl.setShaderValue(shader, rl.getShaderLocation(shader, "ambient"), &ambient, .vec4);

        return self;
    }

    pub fn deinit(self: *Game) void {
        rl.unloadImageColors(self.colors.map);
        self.map.model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture.unload();
        self.map.model.unload();
        self.alloc.free(std.mem.sliceAsBytes(self.vertices));
    }

    pub fn genMapTexture(self: *Game) !void {
        var image = try rl.Image.init("resources/earth.bmp");
        defer image.unload();

        image.flipHorizontal();

        const texture = try image.toTexture();
        rl.setTextureWrap(texture, .repeat);

        const sphere_radius = 40;
        const mesh = rl.genMeshSphere(sphere_radius, SPHERE_RES, SPHERE_RES);

        var material = try rl.loadMaterialDefault();
        material.shader = self.shader;
        material.maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture = texture;

        var model = try rl.Model.fromMesh(mesh);
        model.materials[0] = material;

        var i: usize = 0;
        while (i < mesh.vertexCount * 3) : (i += 3) {
            const norm = rl.Vector3.init(mesh.vertices[i + 0], mesh.vertices[i + 1], mesh.vertices[i + 2]).normalize();

            const u = std.math.atan2(norm.z, norm.x) / (2.0 * std.math.pi) + 0.5;
            const v = std.math.asin(norm.y) / std.math.pi + 0.5;

            const col: usize = @intFromFloat(@as(f32, @floatFromInt(NCOLS - 1)) * std.math.clamp(1.0 - u, 0.0, 1.0));
            const row: usize = @intFromFloat(@as(f32, @floatFromInt(NROWS - 1)) * std.math.clamp(v, 0.0, 1.0));

            var h = self.vertices[row * NCOLS + col];
            if (h == -99999) h = 0;

            const earth_radius: f32 = 6.371e6;
            const exaggeration = 40.0;
            const elevation = (h / earth_radius) * sphere_radius * exaggeration;

            const final = norm.scale(sphere_radius + elevation);

            mesh.vertices[i + 0] = final.x;
            mesh.vertices[i + 1] = final.y;
            mesh.vertices[i + 2] = final.z;

            mesh.normals[i + 0] = norm.x;
            mesh.normals[i + 1] = norm.y;
            mesh.normals[i + 2] = norm.z;

            mesh.texcoords[(i / 3) * 2 + 0] = u;
            mesh.texcoords[(i / 3) * 2 + 1] = 1.0 - v;
        }

        rl.updateMeshBuffer(mesh, 0, mesh.vertices, mesh.vertexCount * 3 * @sizeOf(f32), 0);
        rl.updateMeshBuffer(mesh, 1, mesh.texcoords, mesh.vertexCount * 2 * @sizeOf(f32), 0);
        rl.updateMeshBuffer(mesh, 2, mesh.normals, mesh.vertexCount * 3 * @sizeOf(f32), 0);

        self.map.model = model;
    }

    pub fn update(self: *Game) !void {
        self.map.model.draw(.zero(), 1.0, .white);
    }
};

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
        // if (rl.isMouseButtonDown(.left)) camera.update(.third_person);
        camera.update(.free);

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
