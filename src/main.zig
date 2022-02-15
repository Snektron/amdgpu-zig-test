const std = @import("std");
const amdgpu = @import("amdgpu.zig");
const Device = amdgpu.Device;

fn dumpHeapInfo(name: []const u8, info: Device.HeapInfo) void {
    std.log.info("{s} heap info:", .{name});
    std.log.info("  size: {}", .{info.total_heap_size});
    std.log.info("  usage: {}", .{info.heap_usage});
    std.log.info("  max allocation: {}", .{info.max_allocation});
}

pub fn main() !void {
    var args = std.process.args();
    const prog_name = args.next() orelse return error.ExecutableNameMissing;
    const device_path = args.next() orelse {
        std.log.err("usage: {s} <device path>", .{prog_name});
        std.process.exit(1);
    };

    std.log.info("using device {s}", .{device_path});
    var device = try Device.init(device_path);
    defer device.deinit();

    const info = device.queryInfo();
    std.log.info("device: {s}", .{device.queryName()});
    std.log.info("shader engines: {}", .{info.num_shader_engines});
    std.log.info("constant engine ram size: {}", .{info.ce_ram_size});

    const mem_info = device.queryMemoryInfo();
    dumpHeapInfo("gtt", mem_info.gtt);
    dumpHeapInfo("vram", mem_info.vram);
    dumpHeapInfo("cpu-accessible vram", mem_info.cpu_accessible_vram);

    var buf = try device.alloc(0x1000, 0x1000, .{});
    defer buf.deinit();

    var buf2 = try device.alloc(0x1000, 0x1000, .{});
    defer buf2.deinit();

    std.log.info("Allocated buf at 0x{X:0>16}", .{buf.gpu_address});
    std.log.info("Allocated buf2 at 0x{X:0>16}", .{buf2.gpu_address});

    const ptr = @ptrCast(*u32, @alignCast(4, try buf.map()));
    defer buf.unmap();

    std.log.info("Mapped buf to 0x{X:0>16}", .{@ptrToInt(ptr)});
}
