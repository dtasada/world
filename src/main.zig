const std = @import("std");
const rl = @import("raylib");

const Light = @import("Light.zig");
const Game = @import("Game.zig");
const noise = @import("noise.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    rl.initWindow(1280, 720, "world");
    defer rl.closeWindow();

    rl.setTargetFPS(400);

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

        {
            camera.begin();
            defer camera.end();

            for (lights.items) |l| l.update(shader);

            try game.update();
        }

        rl.drawFPS(12, 12);
    }
}
