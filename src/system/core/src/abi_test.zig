const std = @import("std");
const core = @import("core.zig");
const c = @cImport(@cInclude("sinty-system/v1.h"));

fn same(comptime Z: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
    inline for (std.meta.fields(Z)) |f| {
        try std.testing.expectEqual(@offsetOf(C, f.name), @offsetOf(Z, f.name));
    }
}

test "header layouts match the exported structs" {
    try same(core.proc.Process, c.SintyProcess);
    try same(core.proc.Socket, c.SintySocket);
    try same(core.sensors.Reading, c.SintySensorReading);
    try same(core.power.Supply, c.SintyPowerSupply);
    try same(core.power.CpuPolicy, c.SintyCpuPolicy);
    try same(core.display.Backlight, c.SintyBacklight);
    try same(core.display.DdcDisplay, c.SintyDdcDisplay);
}
