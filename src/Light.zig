//! Basic lighting implementation
const std = @import("std");
const rl = @import("raylib");

const Light = @This();

var lightsCount: i32 = 0;

const LightType = enum(i32) { directional = 0, point = 1 };

type: LightType,
enabled: bool,
position: rl.Vector3,
target: rl.Vector3,
color: rl.Color,
intensity: f32,

enabledLoc: i32,
typeLoc: i32,
positionLoc: i32,
targetLoc: i32,
colorLoc: i32,

pub fn init(t: LightType, position: rl.Vector3, target: rl.Vector3, color: rl.Color, intensity: f32, shader: rl.Shader) Light {
    var light: Light = .{
        .type = t,
        .enabled = true,
        .position = position,
        .target = target,
        .color = color,
        .intensity = intensity,

        .enabledLoc = rl.getShaderLocation(shader, rl.textFormat("lights[%i].enabled", .{lightsCount})),
        .typeLoc = rl.getShaderLocation(shader, rl.textFormat("lights[%i].type", .{lightsCount})),
        .positionLoc = rl.getShaderLocation(shader, rl.textFormat("lights[%i].position", .{lightsCount})),
        .targetLoc = rl.getShaderLocation(shader, rl.textFormat("lights[%i].target", .{lightsCount})),
        .colorLoc = rl.getShaderLocation(shader, rl.textFormat("lights[%i].color", .{lightsCount})),
    };

    light.update(shader);
    lightsCount += 1;

    return light;
}

pub fn update(self: *const Light, shader: rl.Shader) void {
    const enabled: i32 = @intFromBool(self.enabled);
    rl.setShaderValue(shader, self.enabledLoc, &enabled, .int);

    rl.setShaderValue(shader, self.typeLoc, &self.type, .int);

    const position: [3]f32 = .{ self.position.x, self.position.y, self.position.z };
    rl.setShaderValue(shader, self.positionLoc, &position, .vec3);

    const target: [3]f32 = .{ self.target.x, self.target.y, self.target.z };
    rl.setShaderValue(shader, self.targetLoc, &target, .vec3);

    const color: [4]f32 = .{
        @as(f32, @floatFromInt(self.color.r)) * self.intensity / 255,
        @as(f32, @floatFromInt(self.color.g)) * self.intensity / 255,
        @as(f32, @floatFromInt(self.color.b)) * self.intensity / 255,
        @as(f32, @floatFromInt(self.color.a)) * self.intensity / 255,
    };
    rl.setShaderValue(shader, self.colorLoc, &color, .vec4);
}
