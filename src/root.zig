pub const c = @import("usrsctp");

const std = @import("std");
const builtin = @import("builtin");

pub const AF_CONN: u32 = 123;
pub const SOCK_STREAM: u32 = 1;
pub const IPPROTO_SCTP: u32 = 132;

// Set socket options
pub const SCTP_INITMSG: u32 = 0x0003;
pub const SCTP_NODELAY: u32 = 0x0004;
pub const SCTP_EVENT: u32 = 0x001E;

pub const Error = struct {
    pub const INPROGRESS: i32 = 115;
    pub const IO: i32 = 5;
};

const InitSendFn = fn (addr: ?*anyopaque, buffer: ?*anyopaque, length: usize, tos: u8, set_df: u8) callconv(.c) c_int;
const SocketRecvFn = fn (sock: ?*Socket, addr: SockstoreConn, data: ?*anyopaque, datalen: usize, rcvinfo: RcvInfo, flags: Flags, ulp_info: ?*anyopaque) callconv(.c) c_int;
const SocketSendFn = fn (sock: ?*Socket, sb_free: u32, ulp_info: ?*anyopaque) callconv(.c) c_int;

pub const SocketConfig = struct {
    receive_cb: ?*const SocketRecvFn = null,
    ctx: ?*anyopaque = null,
    non_blocking: bool = false,
    no_delay: bool = false,
    enable_stream_reset: bool = false,
};

pub const AssocValue = extern struct {
    assoc_id: u32 = 0,
    assoc_value: u32 = 0,
};

pub const Socket = opaque {
    pub fn create(config: SocketConfig) !*Socket {
        const socket = usrsctp_socket(
            AF_CONN,
            SOCK_STREAM,
            IPPROTO_SCTP,
            config.receive_cb,
            null,
            0,
            config.ctx,
        ) orelse return error.CreateFailed;

        try socket.setNonBlocking(config.non_blocking);
        if (config.no_delay) {
            var on: i32 = 1;
            try socket.setOption(SCTP_NODELAY, &on, @sizeOf(i32));
        }

        if (config.enable_stream_reset) {
            const ENABLE_STREAM_RESET: c_int = 0x00000900;

            var reset = AssocValue{
                .assoc_id = 0, // SCTP_FUTURE_ASSOC
                .assoc_value = 1, // SCTP_ENABLE_RESET_STREAM_REQ,
            };
            try socket.setOption(ENABLE_STREAM_RESET, &reset, @sizeOf(AssocValue));
        }

        return socket;
    }

    pub fn close(self: *Socket) void {
        _ = usrsctp_close(self);
    }

    pub fn bind(self: *Socket, addr: *SockaddrConn) !void {
        const ret = usrsctp_bind(self, addr, @sizeOf(SockaddrConn));
        if (ret != 0) {
            return error.BindFailed;
        }
    }

    pub fn connect(self: *Socket, addr: *SockaddrConn) !void {
        const ret = usrsctp_connect(self, addr, @sizeOf(SockaddrConn));
        if (ret < 0 and std.c._errno().* != Error.INPROGRESS) {
            return error.ConnectFailed;
        }
    }

    pub fn setInitMessage(self: *Socket, init_msg: *InitMsg) !void {
        try self.setOption(SCTP_INITMSG, init_msg, @sizeOf(InitMsg));
    }

    pub fn setOption(self: *Socket, option_name: c_int, option_value: *anyopaque, size: u32) !void {
        if (usrsctp_setsockopt(self, IPPROTO_SCTP, option_name, option_value, size) != 0) {
            return error.SetOptionFailed;
        }
    }

    pub fn subscribe(self: *Socket, events: []const EventType) !void {
        for (events) |event| {
            var ev = Event{
                .assoc_id = 2, // SCTP_ALL_ASSOC,
                .event_type = event,
                .on = 1,
            };

            try self.setOption(SCTP_EVENT, &ev, @sizeOf(Event));
        }
    }

    pub const SendConfig = struct {
        ppid: u32,
        sid: u16,
        ordered: bool = true,
        max_retransmits: u32 = 0,
        max_lifetime: u32 = 0,
    };

    pub fn send(self: *Socket, data: []const u8, config: SendConfig) error{SendFailed}!void {
        const pr_info: PrInfo = if (config.max_retransmits != 0)
            .{ .policy = .rtx, .value = config.max_retransmits }
        else if (config.max_lifetime != 0)
            .{ .policy = .ttl, .value = config.max_lifetime }
        else
            .{};

        var sendv_spa = SendvSpa{
            .flags = .{
                .send_info = true,
                .pr_info = config.max_retransmits != 0 or config.max_lifetime != 0,
            },
            .send_info = SendInfo{
                .sid = config.sid,
                .flags = .{ .eor = true, .unordered = !config.ordered },
                .ppid = std.mem.nativeToBig(u32, config.ppid),
                .context = 0,
                .assoc_id = 0,
            },
            .pr_info = pr_info,
        };

        const ret = usrsctp_sendv(
            self,
            data.ptr,
            data.len,
            null,
            0,
            &sendv_spa,
            @sizeOf(SendvSpa),
            SENDV_SPA,
            0,
        );

        if (ret < 0) return error.SendFailed;
    }

    fn setNonBlocking(self: *Socket, nonblocking: bool) !void {
        const ret = usrsctp_set_non_blocking(self, @intFromBool(nonblocking));
        if (ret != 0) {
            return error.SetNonBlockingFailed;
        }
    }
};

pub const SENDV_NOINFO = @as(c_int, 0);
pub const SENDV_SNDINFO = @as(c_int, 1);
pub const SENDV_PRINFO = @as(c_int, 2);
pub const SENDV_AUTHINFO = @as(c_int, 3);
pub const SENDV_SPA = @as(c_int, 4);

pub const Flags = packed struct(u32) {
    _pad1: u13,
    notification: bool,
    _pad2: u18,
};

pub const Event = extern struct {
    assoc_id: u32 = 0,
    event_type: EventType,
    on: u8 = 0,
};

pub const EventType = enum(u16) {
    assoc_change = 0x0001,
    shutdown = 0x0005,
    stream_reset = 0x0009,
    send_failed = 0x000E,
};

const sconn_has_len = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const SockaddrConn = if (sconn_has_len) extern struct {
    len: u8 = 0,
    family: u8 = AF_CONN,
    port: u16 = 0,
    addr: ?*anyopaque = null,

    pub fn init(port: u16, addr: ?*anyopaque) @This() {
        return .{ .len = @sizeOf(@This()), .port = port, .addr = addr };
    }
} else extern struct {
    family: u16 = AF_CONN,
    port: u16 = 0,
    addr: ?*anyopaque = null,

    pub fn init(port: u16, addr: ?*anyopaque) @This() {
        return .{ .port = port, .addr = addr };
    }
};

// sized to match union sctp_sockstore's largest member (sockaddr_in6, 28 bytes);
// translate-C's demotes sctp_sockstore to opaque which breaks the receive callback.
const sockaddr_in6_size = 28;

pub const SockstoreConn = extern union {
    sconn: SockaddrConn,
    _pad: [sockaddr_in6_size]u8,
};

pub const Notification = extern union {
    pub const Header = extern struct {
        type: EventType,
        flags: u16,
        length: u32,
    };

    pub const AssocChange = extern struct {
        pub const State = enum(u16) {
            COMM_UP = 0x0001,
            COMM_LOST = 0x0002,
            RESTART = 0x0003,
            SHUTDOWN_COMP = 0x0004,
            CANT_STR_ASSOC = 0x0005,
        };

        type: EventType,
        flags: u16,
        length: u32,
        state: State,
        err: u16,
        outbound_streams: u16,
        inbound_streams: u16,
        assoc_id: u32,
        _sac_info: [0]u8,
    };

    pub const ShutdownEvent = extern struct {
        type: EventType,
        flags: u16,
        length: u32,
        assoc_id: u32,
    };

    header: Header,
    assoc_change: AssocChange,
    shutdown_event: ShutdownEvent,
};

pub const RcvInfo = extern struct {
    sid: u16 = 0,
    ssn: u16 = 0,
    flags: u16 = 0,
    ppid: u32 = 0,
    tsn: u32 = 0,
    cumtsn: u32 = 0,
    context: u32 = 0,
    assoc_id: u32 = 0,
};

pub const SendInfo = extern struct {
    pub const Flags = packed struct(u16) {
        _pad: u10 = 0,
        unordered: bool = false,
        _pad2: u2 = 0,
        eor: bool = false,
        _pad3: u2 = 0,
    };

    sid: u16,
    flags: SendInfo.Flags,
    ppid: u32,
    context: u32,
    assoc_id: u32,
};

pub const PrInfo = extern struct {
    pub const Policy = enum(u16) { none = 0, ttl = 1, buf = 2, rtx = 3 };

    policy: Policy = .none,
    value: u32 = 0,
};

pub const AuthInfo = extern struct {
    keynumber: u16 = 0,
};

pub const SendvSpa = extern struct {
    pub const Flags = packed struct(u32) {
        send_info: bool = false,
        pr_info: bool = false,
        auth_info: bool = false,
        _pad: u29 = 0,
    };

    flags: SendvSpa.Flags = .{},
    send_info: SendInfo,
    pr_info: PrInfo = .{},
    auth_info: AuthInfo = .{},
};

pub const InitMsg = extern struct {
    num_ostreams: u16 = 0,
    max_instreams: u16 = 0,
    max_attempts: u16 = 0,
    max_init_timeo: u16 = 0,
};

pub fn init(send_cb: ?*const InitSendFn) void {
    usrsctp_init(0, send_cb, null);
}

pub fn deinit() void {
    _ = usrsctp_finish();
}

pub fn registerAddress(addr: ?*anyopaque) void {
    usrsctp_register_address(addr);
}

pub fn deregisterAddress(addr: ?*anyopaque) void {
    usrsctp_deregister_address(addr);
}

pub fn connInput(addr: ?*anyopaque, data: []const u8) void {
    usrsctp_conninput(addr, data.ptr, data.len, 0);
}

extern fn usrsctp_init(port: u16, send: ?*const fn (addr: ?*anyopaque, buffer: ?*anyopaque, length: usize, tos: u8, set_df: u8) callconv(.c) c_int, ?*const fn (format: [*c]const u8, ...) callconv(.c) void) void;
extern fn usrsctp_finish() c_int;
extern fn usrsctp_socket(domain: c_int, socket_type: c_int, protocol: c_int, receive_cb: ?*const SocketRecvFn, send_cb: ?*const SocketSendFn, sb_threshold: u32, ulp_info: ?*anyopaque) ?*Socket;
extern fn usrsctp_bind(sock: *Socket, addr: *SockaddrConn, addrlen: u32) c_int;
extern fn usrsctp_connect(sock: *Socket, addr: *SockaddrConn, addrlen: u32) c_int;
extern fn usrsctp_set_non_blocking(sock: *Socket, nonblocking: c_int) c_int;
extern fn usrsctp_setsockopt(sock: *Socket, level: c_int, option_name: c_int, option_value: *anyopaque, option_len: u32) c_int;
extern fn usrsctp_close(sock: *Socket) c_int;
extern fn usrsctp_register_address(addr: ?*anyopaque) void;
extern fn usrsctp_deregister_address(addr: ?*anyopaque) void;
extern fn usrsctp_conninput(addr: ?*anyopaque, data: [*]const u8, datalen: usize, flags: u8) void;
extern fn usrsctp_sendv(sock: *Socket, data: ?*const anyopaque, len: usize, to: ?*SockaddrConn, tolen: u32, info: ?*anyopaque, infolen: u32, infotype: u32, flags: i32) isize;
