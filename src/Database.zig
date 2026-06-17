const std = @import("std");
const keylib = @import("keylib");
const Credential = keylib.ctap.authenticator.Credential;

pub const kdbx = @import("database/kdbx.zig");

const Self = @This();

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    FileError,
    WouldBlock,
    Other,
    NoHome,
    DatabaseError,
    UnsupportedItem,
    InvalidPairCount,
    NoKey,
    UnexpectedlyLongCidOrIv,
    InvalidCipherSuite,
    InvalidNonceLength,
    InvalidKeyLength,
    DoesNotExist,
};

path: []const u8,
home: []const u8, // TODO: don't know if this is the right place
pw: []const u8,
db: ?*anyopaque = null,
allocator: std.mem.Allocator,
io: std.Io,

init: *const fn (*Self) Error!void,

deinit: *const fn (*const Self) void,

save: *const fn (*const Self) Error!void,

getCredential: *const fn (
    *const Self,
    rpId: ?[]const u8,
    rpIdHash: ?[32]u8,
    idx: *usize,
    aexternal: std.mem.Allocator,
) Error!Credential,

setCredential: *const fn (
    *const Self,
    data: Credential,
) Error!void,

deleteCredential: *const fn (
    *const Self,
    id: [36]u8,
) Error!void,
