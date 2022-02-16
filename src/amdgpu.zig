const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("amdgpu.h");
    @cInclude("amdgpu_drm.h");
});

pub const pm4 = @import("amdgpu/pm4.zig");

/// Taken from AMDPAL/src/core/os/amdgpu/amdgpuDevice.cpp:CheckResult and calls to that function.
pub const Error = error{
    InvalidValue,
    OutOfMemory,
    OutOfDeviceMemory,
    Timeout,
    DeviceLost,
    PermissionDenied,
    InitializationFailed,
    MapFailed,
    UnmapFailed,
    Unknown,
};

fn checkResult(default: Error, code: c_int) Error!void {
    return switch (code) {
        0 => {},
        -@as(c_int, @enumToInt(std.c.E.INVAL)) => error.InvalidValue,
        -@as(c_int, @enumToInt(std.c.E.NOMEM)) => error.OutOfMemory,
        -@as(c_int, @enumToInt(std.c.E.NOSPC)) => error.OutOfDeviceMemory,
        -@as(c_int, @enumToInt(std.c.E.TIME)) => error.Timeout,
        -@as(c_int, @enumToInt(std.c.E.CANCELED)) => return error.DeviceLost,
        -@as(c_int, @enumToInt(std.c.E.ACCES)) => return error.PermissionDenied,
        else => default,
    };
}

fn assertResult(code: c_int) void {
    checkResult(error.Unknown, code) catch unreachable;
}

pub const Device = struct {
    pub const Info = c.amdgpu_gpu_info;
    pub const MemoryInfo = c.drm_amdgpu_memory_info;
    pub const HeapInfo = c.drm_amdgpu_heap_info;

    handle: c.amdgpu_device_handle,
    ctx: c.amdgpu_context_handle,

    pub fn init(device_path: []const u8) !Device {
        const file = try std.fs.cwd().openFile(device_path, .{.mode = .read_write});
        defer file.close();

        var major: u32 = undefined;
        var minor: u32 = undefined;
        var handle: c.amdgpu_device_handle = undefined;
        try checkResult(error.InitializationFailed, c.amdgpu_device_initialize(file.handle, &major, &minor, &handle));
        errdefer assertResult(c.amdgpu_device_deinitialize(handle));

        var ctx: c.amdgpu_context_handle = undefined;
        try checkResult(error.InvalidValue, c.amdgpu_cs_ctx_create(handle, &ctx));
        errdefer assertResult(c.amdgpu_cs_ctx_free(ctx));

        return Device{
            .handle = handle,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Device) void {
        assertResult(c.amdgpu_cs_ctx_free(self.ctx));
        assertResult(c.amdgpu_device_deinitialize(self.handle));
        self.* = undefined;
    }

    pub fn queryInfo(self: Device) Info {
        var info: Info = undefined;
        // Apparently this function will never fail as long as handle is initialized.
        assertResult(c.amdgpu_query_gpu_info(self.handle, &info));
        return info;
    }

    pub fn queryMemoryInfo(self: Device) MemoryInfo {
        var info: MemoryInfo = undefined;
        // AMDPAL also asserts this so its likely fine.
        assertResult(c.amdgpu_query_info(self.handle, c.AMDGPU_INFO_MEMORY, @sizeOf(MemoryInfo), &info));
        return info;
    }

    pub fn queryName(self: Device) [*:0]const u8 {
        if (c.amdgpu_get_marketing_name(self.handle)) |name| {
            return name;
        }
        return @as([:0]const u8, "Unknown GPU").ptr;
    }
};

pub const Buffer = struct {
    pub const AllocInfo = struct {
        pub const HeapType = enum {
            /// System memory mapped into the device's address space.
            host,
            /// Device-local memory, not visible from host.
            device,
        };

        /// The memory heap where this allocation is supposed to be placed, either in the
        /// host (cpu) or device (gpu) RAM.
        heap: HeapType = .device,
        /// Map the memory into the low 32-bits of the GPUs address space.
        map_32bit: bool = false,
        /// Allocate the memory in a place that makes it CPU-accessible.
        /// Probably always the case if heap == .host
        host_accessible: bool = false,
        // TODO: USWC flags and stuff?
    };

    handle: c.amdgpu_bo_handle,
    va_handle: c.amdgpu_va_handle,
    gpu_address: u64,

    pub fn alloc(dev: Device, len: u64, alignment: u64, info: AllocInfo) !Buffer {
        var self: Buffer = undefined;

        var alloc_flags: u64 = c.AMDGPU_GEM_CREATE_VM_ALWAYS_VALID;
        if (info.host_accessible) {
            alloc_flags |= c.AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED;
        }

        var req = c.amdgpu_bo_alloc_request{
            .alloc_size = len,
            .phys_alignment = alignment, // Replicate AMDPAL in setting the physical alignment to the virtual
            .preferred_heap = switch (info.heap) {
                .host => c.AMDGPU_GEM_DOMAIN_GTT,
                .device => c.AMDGPU_GEM_DOMAIN_VRAM,
            },
            .flags = alloc_flags,
        };
        try checkResult(error.OutOfDeviceMemory, c.amdgpu_bo_alloc(dev.handle, &req, &self.handle));
        errdefer assertResult(c.amdgpu_bo_free(self.handle));

        // Technically 32_BIT and RANGE_HIGH can be used both; no idea what that does.
        const map_flags: u64 = if (info.map_32bit) c.AMDGPU_VA_RANGE_32_BIT else c.AMDGPU_VA_RANGE_HIGH;
        try checkResult(error.Unknown, c.amdgpu_va_range_alloc(
            dev.handle,
            c.amdgpu_gpu_va_range_general,
            len,
            alignment,
            0,
            &self.gpu_address,
            &self.va_handle,
            map_flags,
        ));
        errdefer assertResult(c.amdgpu_va_range_free(self.va_handle));

        try checkResult(error.InvalidValue, c.amdgpu_bo_va_op(self.handle, 0, len, self.gpu_address, 0, c.AMDGPU_VA_OP_MAP));

        return self;
    }

    pub fn free(self: *Buffer) void {
        // TODO: Does the buffer need to be unmapped before destruction?
        assertResult(c.amdgpu_bo_free(self.handle));
        assertResult(c.amdgpu_va_range_free(self.va_handle));
        self.* = undefined;
    }

    pub fn map(self: Buffer) !*anyopaque {
        var ptr: ?*anyopaque = undefined;
        const res = c.amdgpu_bo_cpu_map(self.handle, &ptr);
        if (res != 0) {
            return error.MapFailed;
        }
        return ptr.?;
    }

    pub fn unmap(self: Buffer) void {
        assertResult(c.amdgpu_bo_cpu_unmap(self.handle));
    }
};

pub const CmdBuffer = struct {
    /// taken from AMDPAL/src/core/cmdAllocator.cpp.
    const cmd_buffer_alignment = 0x1000;

    pub const Pkt3Options = struct {
        predicate: bool = false,
        shader_type: pm4.ShaderType = .graphics,
    };

    buf: Buffer,
    cmds: []u32,
    offset: u64 = 0,

    /// Initialize a command buffer, with enough space for at least `words` words of command data.
    /// `words` is rounded up to a multiple of 0x1000 / word_size.
    pub fn alloc(dev: Device, words: u64) !CmdBuffer {
        const size = std.mem.alignForwardGeneric(u64, words * @sizeOf(u32), 0x1000);
        var buf = try Buffer.alloc(dev, size, cmd_buffer_alignment, .{.host_accessible = true});
        errdefer buf.free();

        const ptr = @ptrCast([*]u32, @alignCast(@alignOf(u32), try buf.map()));
        errdefer buf.unmap();

        return CmdBuffer{
            .buf = buf,
            .cmds = ptr[0..size / @sizeOf(u32)],
        };
    }

    pub fn free(self: *CmdBuffer) void {
        self.buf.unmap(); // Is this required?
        self.buf.free();
        self.* = undefined;
    }

    /// Emit a type-3 packet into the command buffer.
    fn cmdPkt3(self: *CmdBuffer, opcode: pm4.Opcode, opts: Pkt3Options, data: []const u32) !void {
        const header = pm4.makePkt3Header(opts.predicate, opts.shader_type, opcode, @intCast(u14, data.len - 1));
        const total_words = data.len + 1; // 1 for header.
        if (self.offset + total_words > self.cmds.len) {
            return error.CmdBufferFull;
        }

        self.cmds[self.offset] = header;
        std.mem.copy(u32, self.cmds[self.offset + 1..], data);
        self.offset += total_words;
    }
};
