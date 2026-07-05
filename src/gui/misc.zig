pub fn getSlice(s: []const u8) []const u8 {
    for (s, 0..) |c, i|
        if (c == 0) return s[0..i];
    return s;
}
