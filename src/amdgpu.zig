const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("libdrm/amdgpu.h");
    @cInclude("libdrm/amdgpu_drm.h");
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
        -@as(c_int, @intFromEnum(std.c.E.INVAL)) => error.InvalidValue,
        -@as(c_int, @intFromEnum(std.c.E.NOMEM)) => error.OutOfMemory,
        -@as(c_int, @intFromEnum(std.c.E.NOSPC)) => error.OutOfDeviceMemory,
        -@as(c_int, @intFromEnum(std.c.E.TIME)) => error.Timeout,
        -@as(c_int, @intFromEnum(std.c.E.CANCELED)) => return error.DeviceLost,
        -@as(c_int, @intFromEnum(std.c.E.ACCES)) => return error.PermissionDenied,
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
        const file = try std.fs.cwd().openFile(device_path, .{ .mode = .read_write });
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

    pub fn submit(self: Device, cmdbuf: CmdBuffer) !void {
        var ib = c.amdgpu_cs_ib_info{
            .flags = 0,
            .ib_mc_address = cmdbuf.buf.device_address,
            .size = @as(u32, @intCast(cmdbuf.offset)),
        };
        var req = c.amdgpu_cs_request{
            .flags = 0,
            .ip_type = c.AMDGPU_HW_IP_COMPUTE,
            .ip_instance = 0,
            .ring = 0,
            .resources = null,
            .number_of_dependencies = 0,
            .dependencies = null,
            .number_of_ibs = 1,
            .ibs = &ib,
            .seq_no = undefined, // Will be set by call to amdgpu_cs_submit.
            .fence_info = std.mem.zeroes(c.amdgpu_cs_fence_info),
        };
        try checkResult(error.InvalidValue, c.amdgpu_cs_submit(self.ctx, 0, &req, 1));

        // TODO: Extract this somewhere else.
        var fence = c.amdgpu_cs_fence{
            .context = self.ctx,
            .ip_type = c.AMDGPU_HW_IP_COMPUTE,
            .ip_instance = 0,
            .ring = 0,
            .fence = req.seq_no,
        };
        var status: u32 = undefined;
        var first: u32 = undefined;
        try checkResult(error.InvalidValue, c.amdgpu_cs_wait_fences(&fence, 1, true, 10 * std.time.ns_per_s, &status, &first));

        if (status != 1) {
            return error.Timeout;
        }
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
    device_address: u64,

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
            &self.device_address,
            &self.va_handle,
            map_flags,
        ));
        errdefer assertResult(c.amdgpu_va_range_free(self.va_handle));

        try checkResult(error.InvalidValue, c.amdgpu_bo_va_op(self.handle, 0, len, self.device_address, 0, c.AMDGPU_VA_OP_MAP));

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

pub const Dim3 = struct {
    x: u32,
    y: u32,
    z: u32,
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
        const size = std.mem.alignForward(u64, words * @sizeOf(u32), 0x1000);
        var buf = try Buffer.alloc(dev, size, cmd_buffer_alignment, .{ .host_accessible = true });
        errdefer buf.free();

        const ptr: [*]u32 = @ptrCast(@alignCast(try buf.map()));
        errdefer buf.unmap();

        return CmdBuffer{
            .buf = buf,
            .cmds = ptr[0 .. size / @sizeOf(u32)],
        };
    }

    pub fn free(self: *CmdBuffer) void {
        self.buf.unmap(); // Is this required?
        self.buf.free();
        self.* = undefined;
    }

    /// Reset the command buffer and prepare it for recording new commands.
    pub fn reset(self: *CmdBuffer) void {
        self.offset = 0;
    }

    /// Emit a type-2 packet into the command buffer. According to the docs, this does nothing,
    /// and can be used to pad the buffer.
    pub fn cmdPkt2(self: *CmdBuffer) !void {
        if (self.offset + 1 > self.cmds.len) {
            return error.CmdBufferFull;
        }

        self.cmds[self.offset] = pm4.pkt2_header;
        self.offset += 1;
    }

    /// Emit a type-3 packet header, and set the number of data bytes that may follow.
    pub fn cmdPkt3Raw(self: *CmdBuffer, opcode: pm4.Opcode, opts: Pkt3Options, data_len: usize) !void {
        const header = pm4.Pkt3Header{
            .predicate = opts.predicate,
            .shader_type = opts.shader_type,
            .opcode = opcode,
            .count_minus_one = @as(u14, @intCast(data_len - 1)),
        };
        const total_words = data_len + 1; // 1 for header.
        if (self.offset + total_words > self.cmds.len) {
            return error.CmdBufferFull;
        }

        self.cmds[self.offset] = header.encode();
        self.offset += 1;
    }

    /// Emit a type-3 packet into the command buffer.
    pub fn cmdPkt3(self: *CmdBuffer, opcode: pm4.Opcode, opts: Pkt3Options, data: []const u32) !void {
        try self.cmdPkt3Raw(opcode, opts, data.len);
        std.mem.copy(u32, self.cmds[self.offset..], data);
        self.offset += data.len;
    }

    pub fn cmdNop(self: *CmdBuffer) !void {
        try self.cmdPkt2();
    }

    pub fn cmdSetShReg(self: *CmdBuffer, reg: pm4.Register, value: u32) !void {
        try self.cmdSetShRegs(reg, &[_]u32{value});
    }

    pub fn cmdSetShRegs(self: *CmdBuffer, start_reg: pm4.Register, values: []const u32) !void {
        try self.cmdPkt3Raw(.set_sh_reg, .{}, values.len + 1);
        self.cmds[self.offset] = (@intFromEnum(start_reg) - 0xB000) / @sizeOf(u32);
        std.mem.copy(u32, self.cmds[self.offset + 1 ..], values);
        self.offset += 1 + values.len;
    }

    pub const ComputeDispatchInfo = struct {
        shader: Buffer,
        workgroup_dim: Dim3,
        dim: Dim3,
        /// Total number of SGPRS that the shader uses.
        sgprs: u32,
        /// Total number of VGPRS that the shader uses.
        vgprs: u32,
        user_sgprs: []const u32 = &.{},
    };

    pub fn cmdDispatchCompute(self: *CmdBuffer, info: ComputeDispatchInfo) !void {
        std.debug.assert(info.user_sgprs.len <= 16);

        // No idea what this actually is. Some mask to enable compute units/lanes?
        try self.cmdSetShRegs(.compute_static_thread_mgmt_se0, &[_]u32{
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
        });

        try self.cmdSetShRegs(.compute_pgm_lo, &[_]u32{
            @as(u32, @truncate(info.shader.device_address >> 8)), // Note, apparently shaders must be aligned to 256 byte
            @as(u32, @truncate(info.shader.device_address >> 40)),
        });

        const rsrc1 = pm4.ComputePgmRsrc1{
            .vgprs_times_4 = @as(u6, @intCast(std.math.divCeil(u32, info.vgprs, 4) catch unreachable)),
            .sgprs_times_8 = @as(u4, @intCast(std.math.divCeil(u32, info.sgprs, 8) catch unreachable)),
        };
        const rsrc2 = pm4.ComputePgmRsrc2{
            .user_sgprs = @as(u5, @intCast(info.user_sgprs.len)),
        };
        try self.cmdSetShRegs(.compute_pgm_rsrc1, &[_]u32{
            rsrc1.encode(),
            rsrc2.encode(),
        });

        try self.cmdSetShRegs(.compute_num_thread_x, &[_]u32{
            info.workgroup_dim.x,
            info.workgroup_dim.y,
            info.workgroup_dim.z,
        });

        try self.cmdSetShRegs(.compute_user_data_0, info.user_sgprs);

        const initiator = pm4.ComputeDispatchInitiator{
            .compute_shader_en = true,
            .force_start_at_000 = true,
        };
        try self.cmdPkt3(.dispatch_direct, .{ .shader_type = .compute }, &[_]u32{
            info.dim.x,
            info.dim.y,
            info.dim.z,
            initiator.encode(),
        });
    }
};
