const std = @import("std");
const cbor = @import("zbor");
const keylib = @import("keylib");
const Request = @import("cred_mgmt/Request.zig");
const Response = @import("cred_mgmt/Response.zig");

const State = @import("state.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn authenticatorCredentialManagement(
    auth: *keylib.ctap.authenticator.Auth,
    request: []const u8,
    out: *std.Io.Writer,
) keylib.ctap.StatusCodes {
    const S = struct {
        const max = 1000;
        var i: i64 = 0;
        var rps: ?std.ArrayListUnmanaged(keylib.common.RelyingParty) = null;
        const allocator = gpa.allocator();

        pub fn deinitRps() void {
            if (rps) |*_rps| {
                _rps.deinit(allocator);
            }
            rps = null;
        }

        pub fn getRp() ?keylib.common.RelyingParty {
            if (rps == null) return null;
            if (std.time.milliTimestamp() - i > max) {
                deinitRps();
                return null;
            }

            const rp = rps.?.swapRemove(0);
            if (rps.?.items.len == 0) {
                deinitRps();
            }

            return rp;
        }
    };

    const di = cbor.DataItem.new(request) catch {
        return .ctap2_err_invalid_cbor;
    };

    const cmReq = cbor.parse(Request, di, .{}) catch |err| {
        std.log.err("authenticatorCredentialManagement: Unable to parse arguments ({any})", .{err});
        return .ctap2_err_invalid_cbor;
    };

    var status: keylib.ctap.StatusCodes = .ctap1_err_success;
    const res = switch (cmReq.subCommand) {
        .getCredsMetadata => getCredsMetadata(auth, &cmReq, &status),
        .enumerateRPsBegin => enumerateRPsBegin(auth, &cmReq, &status, S),
        .enumerateRPsGetNextRP => enumerateRPsGetNextRP(&status, S),
        .enumerateCredentialsBegin => enumerateCredentialsBegin(auth, &cmReq, &status, S),
        .enumerateCredentialsGetNextCredential => enumerateCredentialsGetNextCredential(auth, &status),
        .deleteCredential => deleteCredential(auth, &cmReq, &status, S),
        else => error.ctap2_err_other,
    } catch {
        return .ctap1_err_other;
    };

    if (status != .ctap1_err_success) return status;

    cbor.stringify(res, .{}, out) catch {
        std.log.err("credentialManagement: cbor encoding error", .{});
        return keylib.ctap.StatusCodes.ctap1_err_other;
    };

    return status;
}

pub fn enumerateRPsBegin(auth: *keylib.ctap.authenticator.Auth, req: *const Request, status: *keylib.ctap.StatusCodes, state: anytype) Response {
    if (req.pinUvAuthParam == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol.? != auth.token.version) {
        status.* = .ctap1_err_invalid_parameter;
        return .{};
    }
    if (!auth.token.verify_token("\x02", req.pinUvAuthParam.?.get())) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    // The authenticator verifies that the pinUvAuthToken has the cm permission and no associated
    // permissions RP ID. If not, return CTAP2_ERR_PIN_AUTH_INVALID.
    if (auth.token.permissions & 0x04 == 0 or auth.token.rp_id != null) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    var cred = auth.callbacks.read_first(null, null, null) catch {
        // If no discoverable credentials exist on this authenticator, return CTAP2_ERR_NO_CREDENTIALS.
        status.* = .ctap2_err_no_credentials;
        return .{};
    };

    state.deinitRps();
    state.rps = .empty;
    state.rps.?.append(state.allocator, cred.rp) catch {
        state.deinitRps();
        status.* = .ctap1_err_other;
        return .{};
    };

    outer: while (true) {
        cred = auth.callbacks.read_next() catch {
            break;
        };

        const rp = cred.rp;

        for (state.rps.?.items) |rp2| {
            if (std.mem.eql(u8, rp.id.get(), rp2.id.get())) continue :outer;
        }

        state.rps.?.append(state.allocator, rp) catch {
            state.deinitRps();
            status.* = .ctap1_err_other;
            return .{};
        };
    }

    state.i = std.time.milliTimestamp();

    const rp = state.rps.?.swapRemove(0);
    var digest: [32]u8 = .{0} ** 32;
    std.crypto.hash.sha2.Sha256.hash(rp.id.get(), &digest, .{});

    return .{
        .rp = rp,
        .rpIDHash = digest,
        .totalRPs = @as(u32, @intCast(state.rps.?.items.len + 1)),
    };
}

pub fn enumerateRPsGetNextRP(status: *keylib.ctap.StatusCodes, state: anytype) Response {
    const rp = state.getRp();

    if (rp == null) {
        status.* = .ctap2_err_no_credentials;
        return .{};
    }

    var digest: [32]u8 = .{0} ** 32;
    std.crypto.hash.sha2.Sha256.hash(rp.?.id.get(), &digest, .{});

    return .{
        .rp = rp.?,
        .rpIDHash = digest,
    };
}

pub fn getCredsMetadata(auth: *keylib.ctap.authenticator.Auth, req: *const Request, status: *keylib.ctap.StatusCodes) Response {
    if (req.pinUvAuthParam == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol.? != auth.token.version) {
        status.* = .ctap1_err_invalid_parameter;
        return .{};
    }
    if (!auth.token.verify_token("\x01", req.pinUvAuthParam.?.get())) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    var credential_count: u32 = 1;
    _ = auth.callbacks.read_first(null, null, null) catch {
        credential_count -= 1;
    };

    if (credential_count > 0) {
        while (true) {
            _ = auth.callbacks.read_next() catch {
                break;
            };
            credential_count += 1;
        }
    }

    return .{
        .existingResidentCredentialsCount = credential_count,
        // This number is aribitrary for the given platform authenticator
        // and always greater than zero!
        .maxPossibleRemainingResidentCredentialsCount = 100,
    };
}

pub fn enumerateCredentialsBegin(auth: *keylib.ctap.authenticator.Auth, req: *const Request, status: *keylib.ctap.StatusCodes, state: anytype) Response {
    if (req.pinUvAuthParam == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.subCommandParams == null or req.subCommandParams.?.rpIDHash == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol.? != auth.token.version) {
        status.* = .ctap1_err_invalid_parameter;
        return .{};
    }

    var m = std.Io.Writer.Allocating.init(state.allocator);
    defer m.deinit();
    m.writer.writeByte(0x04) catch {
        status.* = .ctap1_err_other;
        return .{};
    };
    cbor.stringify(
        req.subCommandParams.?,
        .{},
        &m.writer,
    ) catch {
        status.* = .ctap1_err_other;
        return .{};
    };

    if (!auth.token.verify_token(m.written(), req.pinUvAuthParam.?.get())) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    if (auth.token.permissions & 0x04 == 0) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }
    if (auth.token.rp_id) |rp_id| {
        var digest: [32]u8 = .{0} ** 32;
        std.crypto.hash.sha2.Sha256.hash(rp_id.get(), &digest, .{});
        if (!std.mem.eql(u8, &digest, &req.subCommandParams.?.rpIDHash.?)) {
            status.* = .ctap2_err_pin_auth_invalid;
            return .{};
        }
    }

    _ = auth.callbacks.read_first(null, null, req.subCommandParams.?.rpIDHash.?) catch {
        // If no discoverable credentials exist on this authenticator, return CTAP2_ERR_NO_CREDENTIALS.
        status.* = .ctap2_err_no_credentials;
        return .{};
    };

    var credential_count: u32 = 1;
    while (true) {
        _ = auth.callbacks.read_next() catch {
            break;
        };
        credential_count += 1;
    }

    const cred = auth.callbacks.read_first(null, null, req.subCommandParams.?.rpIDHash.?) catch {
        // If no discoverable credentials exist on this authenticator, return CTAP2_ERR_NO_CREDENTIALS.
        status.* = .ctap2_err_no_credentials;
        return .{};
    };

    return .{
        .user = cred.user,
        .credentialID = .{
            .id = cred.id,
            .type = .@"public-key",
        },
        .publicKey = cred.key,
        .totalCredentials = credential_count,
        .credProtect = cred.policy,
    };
}

pub fn enumerateCredentialsGetNextCredential(auth: *keylib.ctap.authenticator.Auth, status: *keylib.ctap.StatusCodes) Response {
    const cred = auth.callbacks.read_next() catch {
        status.* = .ctap2_err_no_credentials;
        return .{};
    };

    return .{
        .user = cred.user,
        .credentialID = .{
            .id = cred.id,
            .type = .@"public-key",
        },
        .publicKey = cred.key,
        .credProtect = cred.policy,
    };
}

pub fn deleteCredential(auth: *keylib.ctap.authenticator.Auth, req: *const Request, status: *keylib.ctap.StatusCodes, state: anytype) Response {
    if (req.pinUvAuthParam == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.subCommandParams == null or req.subCommandParams.?.credentialID == null) {
        status.* = .ctap2_err_missing_parameter;
        return .{};
    }
    if (req.pinUvAuthProtocol.? != auth.token.version) {
        status.* = .ctap1_err_invalid_parameter;
        return .{};
    }

    var m = std.Io.Writer.Allocating.init(state.allocator);
    defer m.deinit();
    m.writer.writeByte(0x06) catch {
        status.* = .ctap1_err_other;
        return .{};
    };
    cbor.stringify(
        req.subCommandParams.?,
        .{},
        &m.writer,
    ) catch {
        status.* = .ctap1_err_other;
        return .{};
    };

    if (!auth.token.verify_token(m.written(), req.pinUvAuthParam.?.get())) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    if (auth.token.permissions & 0x04 == 0) {
        status.* = .ctap2_err_pin_auth_invalid;
        return .{};
    }

    const id = req.subCommandParams.?.credentialID.?.id.get();
    if (id.len != 36) {
        status.* = .ctap2_err_no_credentials;
        return .{};
    }

    State.database.?.deleteCredential(&State.database.?, id[0..36].*) catch {
        status.* = .ctap2_err_no_credentials;
        return .{};
    };

    return .{};
}
