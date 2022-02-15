const std = @import("std");
const assert = std.debug.assert;

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

    dev: c.amdgpu_device_handle,
    ctx: c.amdgpu_context_handle,

    pub fn init(device_path: []const u8) !Device {
        const file = try std.fs.cwd().openFile(device_path, .{.mode = .read_write});
        defer file.close();

        var major: u32 = undefined;
        var minor: u32 = undefined;
        var dev: c.amdgpu_device_handle = undefined;
        try checkResult(error.InitializationFailed, c.amdgpu_device_initialize(file.handle, &major, &minor, &dev));
        errdefer assertResult(c.amdgpu_device_deinitialize(dev));

        var ctx: c.amdgpu_context_handle = undefined;
        try checkResult(error.InvalidValue, c.amdgpu_cs_ctx_create(dev, &ctx));
        errdefer assertResult(c.amdgpu_cs_ctx_free(ctx));

        return Device{
            .dev = dev,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Device) void {
        assertResult(c.amdgpu_cs_ctx_free(self.ctx));
        assertResult(c.amdgpu_device_deinitialize(self.dev));
        self.* = undefined;
    }

    pub fn queryInfo(self: Device) Info {
        var info: Info = undefined;
        // Apparently this function will never fail as long as dev is initialized.
        assertResult(c.amdgpu_query_gpu_info(self.dev, &info));
        return info;
    }

    pub fn queryMemoryInfo(self: Device) MemoryInfo {
        var info: MemoryInfo = undefined;
        // AMDPAL also asserts this so its likely fine.
        assertResult(c.amdgpu_query_info(self.dev, c.AMDGPU_INFO_MEMORY, @sizeOf(MemoryInfo), &info));
        return info;
    }

    pub fn queryName(self: Device) [*:0]const u8 {
        if (c.amdgpu_get_marketing_name(self.dev)) |name| {
            return name;
        }
        return @as([:0]const u8, "Unknown GPU").ptr;
    }

    const HeapType = enum {
        /// System memory mapped into the device's address space.
        host,
        /// Device-local memory, not visible from host.
        device,
    };

    const AllocInfo = struct {
        heap: HeapType = .device,
        map_32bit: bool = false, // Map the memory into the low 32-bits of the GPUs address space.
    };

    pub fn alloc(self: Device, len: u64, alignment: u64, info: AllocInfo) !Buffer {
        var buf: Buffer = undefined;

        var req = c.amdgpu_bo_alloc_request{
            .alloc_size = len,
            .phys_alignment = alignment, // Replicate AMDPAL in setting the physical alignment to the virtual
            .preferred_heap = switch (info.heap) {
                .host => c.AMDGPU_GEM_DOMAIN_GTT,
                .device => c.AMDGPU_GEM_DOMAIN_VRAM,
            },
            .flags = c.AMDGPU_GEM_CREATE_VM_ALWAYS_VALID,
        };
        try checkResult(error.OutOfDeviceMemory, c.amdgpu_bo_alloc(self.dev, &req, &buf.handle));
        errdefer assertResult(c.amdgpu_bo_free(buf.handle));

        // Technically 32_BIT and RANGE_HIGH can be used both; no idea what that does.
        const flags: u64 = if (info.map_32bit) c.AMDGPU_VA_RANGE_32_BIT else c.AMDGPU_VA_RANGE_HIGH;
        try checkResult(error.Unknown, c.amdgpu_va_range_alloc(
            self.dev,
            c.amdgpu_gpu_va_range_general,
            len,
            alignment,
            0,
            &buf.gpu_address,
            &buf.va_handle,
            flags,
        ));
        errdefer assertResult(c.amdgpu_va_range_free(buf.va_handle));

        try checkResult(error.InvalidValue, c.amdgpu_bo_va_op(buf.handle, 0, len, buf.gpu_address, 0, c.AMDGPU_VA_OP_MAP));

        return buf;
    }
};

pub const Buffer = struct {
    handle: c.amdgpu_bo_handle,
    va_handle: c.amdgpu_va_handle,
    gpu_address: u64,

    pub fn deinit(self: *Buffer) void {
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
