const std = @import("std");
const rl = @import("raylib");

const Light = @import("Light.zig");
const noise = @import("noise.zig");

const persistence = 0.5;
const lacunarity = 2;
const freq = 3;
const amp = 2;
const octaves = 15;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var n = noise.SimplexSphere.init(12345);

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

    try lights.append(gpa, .init(.point, rl.Vector3.one().scale(80), .zero(), .yellow, 0.3, shader));
    try lights.append(gpa, .init(.point, rl.Vector3.one().scale(-80), .zero(), .blue, 0.3, shader));

    var image = try rl.Image.init("resources/textures/equirectangular.png");
    defer image.unload();

    image.flipHorizontal();

    const texture = try image.toTexture();
    defer texture.unload();

    rl.setTextureWrap(texture, .repeat);

    const sphere_radius = 40;
    const mesh = rl.genMeshSphere(sphere_radius, 128, 128);

    var material = try rl.loadMaterialDefault();
    material.shader = shader;
    material.maps[@intFromEnum(rl.MaterialMapIndex.albedo)].texture = texture;

    var model = try rl.Model.fromMesh(mesh);
    defer model.unload();
    model.materials[0] = material;

    var i: usize = 0;
    while (i < mesh.vertexCount * 3) : (i += 3) {
        const x = mesh.vertices[i + 0];
        const y = mesh.vertices[i + 1];
        const z = mesh.vertices[i + 2];

        const norm = rl.Vector3.init(x, y, z).normalize();
        const h = n.fbm(norm.x, norm.y, norm.z, freq, amp, lacunarity, persistence, octaves);

        const radius = sphere_radius + h;

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

        rl.drawModel(model, .zero(), 1.0, .white);
    }
}
