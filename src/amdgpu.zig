const std = @import("std");
const assert = std.debug.assert;

const c = @cImport({
    @cInclude("amdgpu.h");
    @cInclude("amdgpu_drm.h");
});

pub const pm4 = @import("amdgpu/pm4.zig");

fn logErr(func: []const u8, code: c_int) void {
    assert(code != 0);
    if (code < 0) {
        std.log.err("{s} returned {s}", .{func, @tagName(@intToEnum(std.c.E, -code))});
    } else {
        std.log.err("{s} returned AMDGPU-specific error code {}", .{func, code});
    }
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
        const init_res = c.amdgpu_device_initialize(file.handle, &major, &minor, &dev);
        if (init_res != 0) {
            logErr("amdgpu_device_initialize()", init_res);
            return error.DrmInitFailed;
        }
        errdefer _ = c.amdgpu_device_deinitialize(dev);

        var ctx: c.amdgpu_context_handle = undefined;
        const ctx_res = c.amdgpu_cs_ctx_create(dev, &ctx);
        if (ctx_res != 0) {
            logErr("amdgpu_cs_ctx_create()", init_res);
            return error.ContextCreationFailed;
        }
        errdefer _ = c.amdgpu_cs_ctx_free(ctx);

        return Device{
            .dev = dev,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Device) void {
        assert(c.amdgpu_cs_ctx_free(self.ctx) == 0);
        assert(c.amdgpu_device_deinitialize(self.dev) == 0);
        self.* = undefined;
    }

    pub fn queryInfo(self: Device) !Info {
        var info: Info = undefined;
        const res = c.amdgpu_query_gpu_info(self.dev, &info);
        if (res != 0) {
            logErr("amdgpu_query_gpu_info()", res);
            return error.QueryFailed;
        }
        return info;
    }

    pub fn queryMemoryInfo(self: Device) !MemoryInfo {
        var info: MemoryInfo = undefined;
        const res = c.amdgpu_query_info(self.dev, c.AMDGPU_INFO_MEMORY, @sizeOf(MemoryInfo), &info);
        if (res != 0) {
            logErr("amdgpu_query_info(AMDGPU_INFO_MEMORY)", res);
            return error.QueryFailed;
        }
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
        const alloc_res = c.amdgpu_bo_alloc(self.dev, &req, &buf.handle);
        if (alloc_res != 0) {
            logErr("amdgpu_bo_alloc()", alloc_res);
            return error.AllocFailed;
        }
        errdefer assert(c.amdgpu_bo_free(buf.handle) == 0);

        // Technically 32_BIT and RANGE_HIGH can be used both; no idea what that does.
        const flags: u64 = if (info.map_32bit) c.AMDGPU_VA_RANGE_32_BIT else c.AMDGPU_VA_RANGE_HIGH;
        const range_alloc_res = c.amdgpu_va_range_alloc(
            self.dev,
            c.amdgpu_gpu_va_range_general,
            len,
            alignment,
            0,
            &buf.gpu_address,
            &buf.va_handle,
            flags,
        );
        if (range_alloc_res != 0) {
            logErr("amdgpu_va_range_alloc()", range_alloc_res);
            return error.DeviceVaAllocFailed;
        }
        errdefer assert(c.amdgpu_va_range_free(buf.va_handle) == 0);

        const map_res = c.amdgpu_bo_va_op(buf.handle, 0, len, buf.gpu_address, 0, c.AMDGPU_VA_OP_MAP);
        if (map_res != 0) {
            logErr("amdgpu_bo_va_op", map_res);
            return error.DeviceMapFailed;
        }

        return buf;
    }
};

pub const Buffer = struct {
    handle: c.amdgpu_bo_handle,
    va_handle: c.amdgpu_va_handle,
    gpu_address: u64,

    pub fn deinit(self: *Buffer) void {
        // TODO: Does the buffer need to be unmapped before destruction?
        assert(c.amdgpu_bo_free(self.handle) == 0);
        assert(c.amdgpu_va_range_free(self.va_handle) == 0);
        self.* = undefined;
    }
};
