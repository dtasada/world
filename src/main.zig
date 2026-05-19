const std = @import("std");
const rl = @import("raylib");

const Light = @import("Light.zig");
const noise = @import("noise.zig");

const persistence = 0.5;
const lacunarity = 2;
const freq = 3;
const amp = 2;
const octaves = 15;

const NCOLS: usize = 21601;
const NROWS: usize = 10801;
const MIN_ELEVATION: f32 = -10898.0;
const MAX_ELEVATION: f32 = 8271.0;

const MAP_WIDTH: usize = 16384;
const MAP_HEIGHT: usize = @intFromFloat(@floor(
    @as(f32, @floatFromInt(MAP_WIDTH * NROWS)) /
        @as(f32, @floatFromInt(NCOLS)),
));

const Game = struct {
    alloc: std.mem.Allocator,
    vertices: []f32,
    map: struct {
        model: rl.Model,
        should_load: std.atomic.Value(bool),
        load_thread: ?std.Thread,
    },
    // borders: Borders,
    camera: rl.Camera2D,
    colors: struct {
        map: []rl.Color,
        width: usize,
        height: usize,
    },

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Game {
        const color_image = try rl.loadImage("resources/earth.bmp");
        defer color_image.unload();
        const color_map = try rl.loadImageColors(color_image);

        const vertex_file = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "resources/earth.bin",
            alloc,
            .limited(NCOLS * NROWS * 4 + 1),
        );
        defer alloc.free(vertex_file);

        const vertices = try alloc.alloc(f32, NCOLS * NROWS);
        errdefer alloc.free(vertices);

        for (std.mem.bytesAsSlice(f32, vertex_file), 0..) |v, i|
            vertices[i] = v;

        var self: Game = .{
            .alloc = alloc,
            .vertices = vertices,
            .map = .{
                .model = undefined,
                .should_load = .init(true),
                .load_thread = null,
            },
            // .borders = undefined, // Init later
            .camera = .{
                .offset = .zero(),
                .rotation = 0.0,
                .target = .zero(),
                .zoom = 1.0,
            },
            .colors = .{
                .map = color_map,
                .width = @intCast(color_image.width),
                .height = @intCast(color_image.height),
            },
        };

        try self.genMapTexture();

        return self;
    }

    pub fn deinit(self: *Game) void {
        if (self.map.load_thread) |t| {
            self.map.should_load.store(false, .monotonic);
            t.join();
        }

        // self.borders.deinit();
        rl.unloadImageColors(self.colors.map);
        defer self.alloc.free(self.vertices);
    }

    pub fn reloadMapTexture(self: *Game) !void {
        // this doesn't cause race conditions because genMapTexture doesn't
        // mutate `self` until after the 2D loop has been finished, which won't
        // happen when disabling `should_load`.
        if (self.map.load_thread) |t| {
            self.map.should_load.store(false, .monotonic);
            t.detach();
        }

        self.map.load_thread = try std.Thread.spawn(.{}, Game.genMapTexture, .{self});
    }

    pub fn genMapTexture(self: *Game) !void {
        self.map.should_load.store(true, .monotonic);

        var image = try rl.Image.init("resources/textures/equirectangular.png");
        defer image.unload();

        image.flipHorizontal();

        const texture = try image.toTexture();
        defer texture.unload();

        rl.setTextureWrap(texture, .repeat);

        const sphere_radius = 40;
        const mesh = rl.genMeshSphere(sphere_radius, 128, 128);

        var material = try rl.loadMaterialDefault();
        // material.shader = shader;
        material.maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture = texture;

        var model = try rl.Model.fromMesh(mesh);
        defer model.unload();
        model.materials[0] = material;

        var i: usize = 0;
        while (i < mesh.vertexCount * 3) : (i += 3) {
            if (!self.map.should_load.load(.monotonic)) return;

            const map_width: f32 = @floatFromInt(MAP_WIDTH);
            const map_height: f32 = @floatFromInt(MAP_HEIGHT);

            const color_width: f32 = @floatFromInt(self.colors.width);
            const color_height: f32 = @floatFromInt(self.colors.height);

            const nrows: f32 = @floatFromInt(NROWS);
            const ncols: f32 = @floatFromInt(NCOLS);

            const x = mesh.vertices[i + 0];
            const y = mesh.vertices[i + 1];
            const z = mesh.vertices[i + 2];

            const norm = rl.Vector3.init(x, y, z).normalize();
            const elevation = {}; // find elevation here.

            const radius = sphere_radius + elevation;

            const final = norm.scale(radius);

            mesh.vertices[i + 0] = final.x;
            mesh.vertices[i + 1] = final.y;
            mesh.vertices[i + 2] = final.z;

            mesh.normals[i + 0] = norm.x;
            mesh.normals[i + 1] = norm.y;
            mesh.normals[i + 2] = norm.z;

            const u = std.math.atan2(norm.z, norm.x) / (2.0 * std.math.pi) + 0.5;
            const v = std.math.asin(norm.y) / std.math.pi + 0.5;
            mesh.texcoords[(i / 3) * 2 + 0] = u;
            mesh.texcoords[(i / 3) * 2 + 1] = 1.0 - v;
        }

        rl.updateMeshBuffer(mesh, 0, mesh.vertices, mesh.vertexCount * 3 * @sizeOf(f32), 0);
        rl.updateMeshBuffer(mesh, 1, mesh.texcoords, mesh.vertexCount * 2 * @sizeOf(f32), 0);
        rl.updateMeshBuffer(mesh, 2, mesh.normals, mesh.vertexCount * 3 * @sizeOf(f32), 0);

        self.map.model = model;

        self.map.should_load.store(false, .monotonic);
    }

    pub fn update(self: *Game) !void {
        self.camera.offset = .{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2.0,
            .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2.0,
        };

        if (rl.getMouseWheelMove() != 0) {
            const mouse_world_before = rl.getScreenToWorld2D(rl.getMousePosition(), self.camera);

            try self.reloadMapTexture();

            const scale_factor: f32 = if (rl.getMouseWheelMove() > 0.0) 1.1 else 1.0 / 1.1;
            _ = scale_factor;

            const mouse_world_after = rl.getScreenToWorld2D(rl.getMousePosition(), self.camera);
            self.camera.target = self.camera.target.add(mouse_world_before.subtract(mouse_world_after));
        }

        if (rl.isMouseButtonDown(.left)) {
            self.camera.target = self.camera.target.subtract(rl.getMouseDelta().scale(1.0 / self.camera.zoom));
        }

        self.camera.begin();

        self.map.model.draw(.zero(), 1.0, .white);

        self.camera.end();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var n = noise.SimplexSphere.init(12345);
    _ = &n;

    rl.initWindow(1280, 720, "world");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var camera: rl.Camera3D = .{
        .fovy = 90,
        .position = rl.Vector3.one().scale(60),
        .projection = .orthographic,
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

    try lights.append(gpa, .init(.directional, rl.Vector3.one().scale(80), .zero(), .yellow, 0.3, shader));
    try lights.append(gpa, .init(.directional, rl.Vector3.one().scale(-80), .zero(), .blue, 0.3, shader));

    var game = try Game.init(gpa, io);

    while (!rl.windowShouldClose()) {
        if (rl.isMouseButtonDown(.left)) camera.update(.third_person);

        rl.beginDrawing();
        defer rl.endDrawing();

        if (rl.getMouseWheelMove() > 0) camera.fovy *= 1.1;
        if (rl.getMouseWheelMove() < 0) camera.fovy /= 1.1;

        rl.clearBackground(.black);

        camera.begin();
        defer camera.end();

        for (lights.items) |l| l.update(shader);

        try game.update();
    }
}
