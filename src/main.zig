const std = @import("std");
const rl = @import("raylib");

const NCOLS: usize = 21601;
const NROWS: usize = 10801;
const MIN_ELEVATION: f32 = -10898.0;
const MAX_ELEVATION: f32 = 8271.0;

const MAP_WIDTH: usize = 16384;
const MAP_HEIGHT: usize = @intFromFloat(@floor(
    @as(f32, @floatFromInt(MAP_WIDTH * NROWS)) /
        @as(f32, @floatFromInt(NCOLS)),
));

const Borders = struct {
    alloc: std.mem.Allocator,
    strips: [][]rl.Vector2,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Borders {
        const file_content = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "resources/ne_10m_admin_0_boundary_lines_land/ne_10m_admin_0_boundary_lines_land.shp",
            alloc,
            .limited(100 * 1024 * 1024),
        );
        defer alloc.free(file_content);

        var strips: std.ArrayList([]rl.Vector2) = .empty;

        // Check file header
        // File Code (0-3): 9994 (Big Endian)
        const file_code = std.mem.readInt(i32, file_content[0..4], .big);
        if (file_code != 9994) return error.InvalidShapefile;

        // Shape Type (32-35): 3 (PolyLine) (Little Endian)
        const shape_type = std.mem.readInt(i32, file_content[32..36], .little);
        if (shape_type != 3) return error.UnsupportedShapeType;

        var i: usize = 100; // Start of records
        while (i < file_content.len) {
            // Record Header (8 bytes)
            // const rec_number = std.mem.readInt(i32, file_content[i..][0..4], .big);
            const content_len_words = std.mem.readInt(i32, file_content[i + 4 ..][0..4], .big);
            const content_len_bytes = @as(usize, @intCast(content_len_words)) * 2;

            i += 8;
            const record_end = i + content_len_bytes;

            // Record Content
            const rec_shape_type = std.mem.readInt(i32, file_content[i..][0..4], .little);

            // Only parse PolyLines (Type 3)
            if (rec_shape_type == 3) {
                // Skip Box (4 doubles = 32 bytes) at i + 4
                const num_parts = std.mem.readInt(i32, file_content[i + 36 ..][0..4], .little);
                const num_points = std.mem.readInt(i32, file_content[i + 40 ..][0..4], .little);

                const parts_start = i + 44;
                const points_start = parts_start + @as(usize, @intCast(num_parts)) * 4;

                // Parse Parts (indices)
                var part_indices = try alloc.alloc(i32, @intCast(num_parts));
                defer alloc.free(part_indices);

                for (0..@intCast(num_parts)) |p_idx| {
                    part_indices[p_idx] = std.mem.readInt(i32, file_content[parts_start + p_idx * 4 ..][0..4], .little);
                }

                // Create strips
                for (0..@intCast(num_parts)) |p_idx| {
                    const start_pt_idx = part_indices[p_idx];
                    const end_pt_idx = if (p_idx + 1 < num_parts) part_indices[p_idx + 1] else num_points;
                    const count = end_pt_idx - start_pt_idx;

                    var strip = try alloc.alloc(rl.Vector2, @intCast(count));

                    for (0..@intCast(count)) |k| {
                        const pt_offset = points_start + (@as(usize, @intCast(start_pt_idx)) + k) * 16;

                        // Parse X (Lon), Y (Lat) - IEEE 754 double (f64)
                        // Zig's readInt returns bits, we cast to float
                        const x_bits = std.mem.readInt(u64, file_content[pt_offset..][0..8], .little);
                        const y_bits = std.mem.readInt(u64, file_content[pt_offset + 8 ..][0..8], .little);

                        const lon = @as(f64, @bitCast(x_bits));
                        const lat = @as(f64, @bitCast(y_bits));

                        // Project to Map Coordinates
                        // X: -180..180 -> 0..MAP_WIDTH
                        // Y: 90..-90 -> 0..MAP_HEIGHT
                        const px = (lon + 180.0) / 360.0 * @as(f64, @floatFromInt(MAP_WIDTH));
                        const py = (90.0 - lat) / 180.0 * @as(f64, @floatFromInt(MAP_HEIGHT));

                        strip[k] = .{ .x = @floatCast(px), .y = @floatCast(py) };
                    }
                    try strips.append(alloc, strip);
                }
            }

            i = record_end;
        }

        return Borders{
            .alloc = alloc,
            .strips = try strips.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *Borders) void {
        for (self.strips) |strip| {
            self.alloc.free(strip);
        }
        self.alloc.free(self.strips);
    }

    pub fn draw(self: *const Borders, zoom: f32) void {
        const thickness = 2.0 / zoom;
        for (self.strips) |strip| {
            if (strip.len < 2) continue;
            for (0..strip.len - 1) |i| {
                rl.drawLineEx(strip[i], strip[i + 1], thickness, rl.Color.init(255, 255, 255, 120));
            }
        }
    }
};

const Game = struct {
    alloc: std.mem.Allocator,
    vertices: []f32,
    map: struct {
        texture: rl.Texture,
        should_load: std.atomic.Value(bool),
        load_thread: ?std.Thread,
    },
    borders: Borders,
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
                .texture = undefined,
                .should_load = .init(true),
                .load_thread = null,
            },
            .borders = undefined, // Init later
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

        self.borders = try Borders.init(alloc, io);
        try self.genMapTexture();

        self.camera.target = .{
            .x = @as(f32, @floatFromInt(self.map.texture.width)) / 2.0,
            .y = @as(f32, @floatFromInt(self.map.texture.height)) / 2.0,
        };

        return self;
    }

    pub fn deinit(self: *Game) void {
        if (self.map.load_thread) |t| {
            self.map.should_load.store(false, .monotonic);
            t.join();
        }

        self.borders.deinit();
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

        var image = rl.Image.genColor(MAP_WIDTH, MAP_HEIGHT, .black);
        defer image.unload();

        for (0..MAP_HEIGHT) |y| {
            for (0..MAP_WIDTH) |x| {
                if (!self.map.should_load.load(.monotonic)) return;

                const x_relative_elevation: usize = @intFromFloat(@floor(
                    @as(f32, @floatFromInt(x * NCOLS)) /
                        @as(f32, @floatFromInt(MAP_WIDTH)),
                ));
                const y_relative_elevation: usize = @intFromFloat(@floor(
                    @as(f32, @floatFromInt(y * NROWS)) /
                        @as(f32, @floatFromInt(MAP_HEIGHT)),
                ));

                // std.debug.print("x_relative_elevation: {}", .{@as(f32, @floatFromInt(x * NCOLS)) /
                //     @as(f32, @floatFromInt(MAP_WIDTH))});

                const elevation = self.vertices[y_relative_elevation * NCOLS + x_relative_elevation];

                const x_relative_colors: usize = @intFromFloat(@floor(
                    @as(f32, @floatFromInt(x * self.colors.width)) /
                        @as(f32, @floatFromInt(MAP_WIDTH)),
                ));
                const y_relative_colors: usize = @intFromFloat(@floor(
                    @as(f32, @floatFromInt(y * self.colors.height)) /
                        @as(f32, @floatFromInt(MAP_HEIGHT)),
                ));

                const base_color = self.colors.map[y_relative_colors * self.colors.width + x_relative_colors];

                const brightness = @sqrt(@sqrt(@sqrt(elevation /
                    if (elevation > 0.0) MAX_ELEVATION else MIN_ELEVATION)));

                const color = rl.Color.init(
                    @intFromFloat(@as(f32, @floatFromInt(base_color.r)) * brightness),
                    @intFromFloat(@as(f32, @floatFromInt(base_color.g)) * brightness),
                    @intFromFloat(@as(f32, @floatFromInt(base_color.b)) * brightness),
                    255,
                );

                image.drawPixel(@intCast(x), @intCast(y), color);
            }
        }

        self.map.texture = try image.toTexture();
        self.camera.zoom = self.cameraZoomOut();

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
            self.camera.zoom = std.math.clamp(self.camera.zoom * scale_factor, self.cameraZoomOut(), 200.0);

            const mouse_world_after = rl.getScreenToWorld2D(rl.getMousePosition(), self.camera);
            self.camera.target = self.camera.target.add(mouse_world_before.subtract(mouse_world_after));
        }

        if (rl.isMouseButtonDown(.left)) {
            self.camera.target = self.camera.target.subtract(rl.getMouseDelta().scale(1.0 / self.camera.zoom));
        }

        // Clamp camera target to keep texture on screen
        const view_width = @as(f32, @floatFromInt(rl.getScreenWidth())) / self.camera.zoom;
        const view_height = @as(f32, @floatFromInt(rl.getScreenHeight())) / self.camera.zoom;

        const min_target_x = view_width / 2.0;
        const max_target_x = @as(f32, @floatFromInt(self.map.texture.width)) - view_width / 2.0;
        const min_target_y = view_height / 2.0;
        const max_target_y = @as(f32, @floatFromInt(self.map.texture.height)) - view_height / 2.0;

        if (min_target_x > max_target_x) {
            self.camera.target.x = @as(f32, @floatFromInt(self.map.texture.width)) / 2.0;
        } else {
            self.camera.target.x = std.math.clamp(self.camera.target.x, min_target_x, max_target_x);
        }

        if (min_target_y > max_target_y) {
            self.camera.target.y = @as(f32, @floatFromInt(self.map.texture.height)) / 2.0;
        } else {
            self.camera.target.y = std.math.clamp(self.camera.target.y, min_target_y, max_target_y);
        }

        self.camera.begin();

        self.map.texture.drawEx(.zero(), 0.0, 1.0, .white);
        self.borders.draw(self.camera.zoom);

        self.camera.end();
    }

    pub inline fn cameraZoomOut(self: *const Game) f32 {
        return @as(f32, @floatFromInt(rl.getScreenHeight())) /
            @as(f32, @floatFromInt(self.map.texture.height));
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    rl.setConfigFlags(.{
        .vsync_hint = true,
        // .window_highdpi = true,
        .msaa_4x_hint = true,
        .window_resizable = true,
    });

    rl.initWindow(1280, 720, "lague");
    defer rl.closeWindow();

    var game = try Game.init(alloc, io);
    defer game.deinit();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(.black);

        try game.update();

        rl.drawFPS(12, 12);

        rl.endDrawing();
    }
}
