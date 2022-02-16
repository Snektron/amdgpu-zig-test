const std = @import("std");
const amdgpu = @import("amdgpu.zig");
const Device = amdgpu.Device;
const Buffer = amdgpu.Buffer;
const CmdBuffer = amdgpu.CmdBuffer;

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

    var output = try Buffer.alloc(device, 0x1000, 0x1000, .{.host_accessible = true});
    defer output.free();
    std.log.info("Allocated output at 0x{X:0>16}", .{output.device_address});

    var shader = blk: {
        var shader = try Buffer.alloc(device, 0x1000, 0x1000, .{.host_accessible = true});
        errdefer shader.free();
        const shader_code = [_]u32{
            0xC0420080, // s_store_dword s2, s[0:1], 0x0
            0x00000000,
            0xBF810000, // s_endpgm
        };
        var shader_ptr = @ptrCast([*]u32, @alignCast(@alignOf(u32), try shader.map()));
        defer shader.unmap();

        std.mem.copy(u32, shader_ptr[0..shader_code.len], &shader_code);

        break :blk shader;
    };
    defer shader.free();
    std.log.info("Allocated & Uploaded test shader", .{});

    var cmdbuf = try CmdBuffer.alloc(device, 0x4000);
    errdefer cmdbuf.free();
    std.log.info("Allocated cmdbuf at 0x{X:0>16} and mapped it to 0x{X:0>16}", .{cmdbuf.buf.device_address, @ptrToInt(cmdbuf.cmds.ptr)});

    try cmdbuf.cmdDispatchCompute(.{
        .shader = shader,
        .workgroup_dim = .{ .x = 1, .y = 1, .z = 1 },
        .dim = .{ .x = 1, .y = 1, .z = 1 },
        .sgprs = 3,
        .vgprs = 0,
        .user_sgprs = &[_]u32{
            @truncate(u32, output.device_address),
            @truncate(u32, output.device_address >> 32),
            123,
        },
    });

    std.log.info("Submitting cmdbuf... ({} words)", .{ cmdbuf.offset });
    try device.submit(cmdbuf);

    const output_ptr = @ptrCast([*]u32, @alignCast(@alignOf(u32), try output.map()));
    defer output.unmap();

    std.log.info("Result: {}", .{output_ptr[0]});
}
