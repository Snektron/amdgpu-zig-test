pub const ShaderType = enum(u1) {
    graphics = 0,
    compute = 1,
};

pub const pkt2_header = 0x2 << 30;

pub const Pkt3Header = struct {
    predicate: bool,
    shader_type: ShaderType,
    opcode: Opcode,
    count_minus_one: u14,

    pub fn encode(self: Pkt3Header) u32 {
        var bits: u32 = 0x3 << 30;
        bits |= @as(u32, self.count_minus_one) << 16;
        bits |= @as(u32, @intFromEnum(self.opcode)) << 8;
        bits |= @as(u32, @intFromEnum(self.shader_type)) << 1;
        bits |= @as(u32, @intFromBool(self.predicate));
        return bits;
    }
};

/// Registers. Values are byte offsets.
pub const Register = enum(u16) {
    compute_dispatch_initiator = 0xB800,
    compute_num_thread_x = 0xB81C,
    compute_num_thread_y = 0xB820,
    compute_num_thread_z = 0xB824,
    compute_pgm_lo = 0xB830,
    compute_pgm_hi = 0xB834,
    compute_pgm_rsrc1 = 0xB848,
    compute_pgm_rsrc2 = 0xB84c,
    compute_static_thread_mgmt_se0 = 0xB858,
    compute_static_thread_mgmt_se1 = 0xB85c,
    compute_static_thread_mgmt_se2 = 0xB864,
    compute_static_thread_mgmt_se3 = 0xB868,
    compute_user_data_0 = 0xB900,
    _,
};

pub const ComputeDispatchInitiator = struct {
    compute_shader_en: bool = false,
    force_start_at_000: bool = false,
    // TODO: Other fields.

    pub fn encode(self: ComputeDispatchInitiator) u32 {
        var bits: u32 = 0;
        bits |= @as(u32, @intFromBool(self.compute_shader_en));
        bits |= @as(u32, @intFromBool(self.force_start_at_000)) << 2;
        return bits;
    }
};

pub const ComputePgmRsrc1 = struct {
    vgprs_times_4: u6 = 0,
    sgprs_times_8: u4 = 0,
    // TODO: Other fields.

    pub fn encode(self: ComputePgmRsrc1) u32 {
        var bits: u32 = 0;
        bits |= @as(u32, self.vgprs_times_4);
        bits |= @as(u32, self.sgprs_times_8) << 6;
        return bits;
    }
};

pub const ComputePgmRsrc2 = struct {
    scratch_en: bool = false,
    user_sgprs: u5 = 0, // max 16
    // TODO: Other fields.

    pub fn encode(self: ComputePgmRsrc2) u32 {
        var bits: u32 = 0;
        bits |= @as(u32, @intFromBool(self.scratch_en));
        bits |= @as(u32, self.user_sgprs) << 1;
        return bits;
    }
};

/// Constants are taken from core/hw/gfxip/gfx6/chip/si_ci_vi_merged_pm4_it_opcodes.h
pub const Opcode = enum(u8) {
    nop = 0x10,
    set_base = 0x11,
    clear_state = 0x12,
    index_buffer_size = 0x13,
    dispatch_direct = 0x15,
    dispatch_indirect = 0x16,
    atomic_gds = 0x1D,
    atomic = 0x1E,
    occlusion_query = 0x1F,
    set_predication = 0x20,
    reg_rmw = 0x21,
    cond_exec = 0x22,
    pred_exec = 0x23,
    draw_indirect = 0x24,
    draw_index_indirect = 0x25,
    index_base = 0x26,
    draw_index_2 = 0x27,
    context_control = 0x28,
    index_type = 0x2A,
    draw_indirect_multi = 0x2C,
    draw_index_auto = 0x2D,
    num_instances = 0x2F,
    draw_index_multi_auto = 0x30,
    indirect_buffer_cnst = 0x33,
    strmout_buffer_update = 0x34,
    draw_index_offset_2 = 0x35,
    write_data = 0x37,
    draw_index_indirect_multi = 0x38,
    mem_semaphore = 0x39,
    copy_dw_si_ci = 0x3B,
    wait_reg_mem = 0x3C,
    indirect_buffer = 0x3F,
    // cond_indirect_buffer              = 0x3F,
    copy_data = 0x40,
    cp_dma = 0x41,
    pfp_sync_me = 0x42,
    surface_sync = 0x43,
    cond_write = 0x45,
    event_write = 0x46,
    event_write_eop = 0x47,
    event_write_eos = 0x48,
    preamble_cntl = 0x4A,
    context_reg_rmw = 0x51,
    load_sh_reg = 0x5F,
    load_config_reg = 0x60,
    load_context_reg = 0x61,
    set_config_reg = 0x68,
    set_context_reg = 0x69,
    set_context_reg_indirect = 0x73,
    set_sh_reg = 0x76,
    set_sh_reg_offset = 0x77,
    scratch_ram_write = 0x7D,
    scratch_ram_read = 0x7E,
    load_const_ram = 0x80,
    write_const_ram = 0x81,
    dump_const_ram = 0x83,
    increment_ce_counter = 0x84,
    increment_de_counter = 0x85,
    wait_on_ce_counter = 0x86,
    wait_on_de_counter_si = 0x87,
    wait_on_de_counter_diff = 0x88,
    switch_buffer = 0x8B,
    draw_preamble_ci_vi = 0x36,
    release_mem_ci_vi = 0x49,
    dma_data_ci_vi = 0x50,
    acquire_mem_ci_vi = 0x58,
    rewind_ci_vi = 0x59,
    load_uconfig_reg_ci_vi = 0x5E,
    set_queue_reg_ci_vi = 0x78,
    set_uconfig_reg_ci_vi = 0x79,
    index_attributes_indirect_ci_vi = 0x91,
    set_sh_reg_index_ci_vi = 0x9B,
    set_resources_ci_vi = 0xA0,
    map_process_ci_vi = 0xA1,
    map_queues_ci_vi = 0xA2,
    unmap_queues_ci_vi = 0xA3,
    query_status_ci_vi = 0xA4,
    run_list_ci_vi = 0xA5,
    load_sh_reg_index_vi = 0x63,
    load_context_reg_index_vi = 0x9F,
    dump_const_ram_offset_vi = 0x9E,
};
