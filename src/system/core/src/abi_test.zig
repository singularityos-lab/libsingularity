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
    try same(core.device.DeviceNames, c.SintyDeviceNames);
    try same(core.net.LinkInfo, c.SintyLinkInfo);
    try same(core.gpu.NvidiaGpu, c.SintyNvidiaGpu);
    try same(core.firewall.Summary, c.SintyFirewallSummary);
    try same(core.audio.Object, c.SintyAudioObject);
    try same(core.time.RtcTime, c.SintyRtcTime);
    try same(core.time.ClockState, c.SintyClockState);
    try same(core.firmware.EsrtEntry, c.SintyEsrtEntry);
    try same(core.disk.Partition, c.SintyPartition);
    try same(core.disk.TableInfo, c.SintyDiskTable);
    try same(core.fs.FsInfo, c.SintyFsInfo);
    try same(core.crypt.Info, c.SintyLuksInfo);
}
