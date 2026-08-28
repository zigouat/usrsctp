pub const c = @import("usrsctp");

const std = @import("std");
const builtin = @import("builtin");

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

pub const Socket = opaque {
    pub fn create(config: SocketConfig) !*Socket {
        const socket = usrsctp_socket(
            AF_CONN,
            c.SOCK_STREAM,
            c.IPPROTO_SCTP,
            config.receive_cb,
            null,
            0,
            config.ctx.?,
        ) orelse return error.CreateFailed;

        try socket.setNonBlocking(config.non_blocking);
        if (config.no_delay) {
            var on: i32 = 1;
            try socket.setOption(c.SCTP_NODELAY, &on, @sizeOf(i32));
        }

        if (config.enable_stream_reset) {
            var reset: c.sctp_assoc_value = .{
                .assoc_id = c.SCTP_FUTURE_ASSOC,
                .assoc_value = c.SCTP_ENABLE_RESET_STREAM_REQ,
            };
            try socket.setOption(c.SCTP_ENABLE_STREAM_RESET, &reset, @sizeOf(c.sctp_assoc_value));
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
        if (ret < 0 and std.c._errno().* != c.EINPROGRESS) {
            return error.ConnectFailed;
        }
    }

    pub fn setInitMessage(self: *Socket, init_msg: *InitMsg) !void {
        try self.setOption(c.SCTP_INITMSG, init_msg, @sizeOf(InitMsg));
    }

    pub fn setOption(self: *Socket, option_name: c_int, option_value: *anyopaque, size: u32) !void {
        if (usrsctp_setsockopt(self, c.IPPROTO_SCTP, option_name, option_value, size) != 0) {
            return error.SetOptionFailed;
        }
    }

    pub fn subscribe(self: *Socket, events: []const EventType) !void {
        for (events) |event| {
            var ev = Event{
                .assoc_id = c.SCTP_ALL_ASSOC,
                .event_type = event,
                .on = 1,
            };

            try self.setOption(c.SCTP_EVENT, &ev, @sizeOf(c.sctp_event));
        }
    }

    fn setNonBlocking(self: *Socket, nonblocking: bool) !void {
        const ret = usrsctp_set_non_blocking(self, @intFromBool(nonblocking));
        if (ret != 0) {
            return error.SetNonBlockingFailed;
        }
    }
};

pub const AF_CONN: u16 = 123;

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
pub const Notification = c.sctp_notification;

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

pub const SndInfo = extern struct {
    sid: u16 = 0,
    flags: u16 = 0,
    ppid: u32 = 0,
    context: u32 = 0,
    assoc_id: u32 = 0,
};

pub const PrInfo = extern struct {
    policy: u16 = 0,
    value: u32 = 0,
};

pub const AuthInfo = extern struct {
    keynumber: u16 = 0,
};

pub const SendvSpa = extern struct {
    flags: u32 = 0,
    sndinfo: SndInfo = .{},
    prinfo: PrInfo = .{},
    authinfo: AuthInfo = .{},
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
    c.usrsctp_conninput(addr, data.ptr, data.len, 0);
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
