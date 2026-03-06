const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const kdbx = @import("kdbx");
const root = @import("root");

const GridType = enum {
    general,
    advanced,
    const num_grids = @typeInfo(@This()).@"enum".fields.len;
};

pub fn draw(
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
) !void {
    const local = struct {
        // Title, Username, URL, Last Modified
        const num_cols = 3;
        const equal_spacing = [num_cols]f32{ -1, -1, -1 };
        var col_widths: [num_cols]f32 = @splat(100); // Default width to 100

        const resize_min = 80;
        const resize_max = 500;
        fn headerResizeOptions(grid: *dvui.GridWidget, col_num: usize) ?dvui.GridWidget.HeaderResizeWidget.InitOptions {
            _ = grid;
            return .{
                .sizes = &col_widths,
                .num = col_num,
                .min_size = resize_min,
                .max_size = resize_max,
            };
        }

        // This is filled if a entry is clicked.
        // It determines which entry should be shown.
        var selected_entry_id: ?usize = null; // The entry index within the kdbx group
        var selected_row: ?usize = null; // The slected row displayed
        var selected_entry_guuid: ?u128 = null; // The group uuid
        var index_map: std.AutoHashMapUnmanaged(usize, usize) = .empty;
        var row_num: usize = 0;

        // This cotrols which kind of information is displayed
        // for a selected entry.
        var active_grid: GridType = .general;

        fn tabSelected(grid_type: GridType) bool {
            return active_grid == grid_type;
        }

        fn tabName(grid_type: GridType) []const u8 {
            return switch (grid_type) {
                .general => "General",
                .advanced => "Advanced",
            };
        }

        // Timer for clipboard
        var cb_seconds_remaining: ?i8 = null;
        var cb_ts: ?i64 = null;

        // Buffer for search box
        var search: [128]u8 = .{0} ** 128;

        var menu_active: bool = false;
    };

    var vbox = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .corner_radius = .all(0),
        },
    );
    defer vbox.deinit();

    // Status bar at the bottom
    statusBar(uniqueId, local);

    // This is the context window for an entry which is placed on the bottom
    // (below the table).
    contextWindow(uniqueId, local);

    // The list of entries of a group.
    {
        var grid = dvui.grid(@src(), .colWidths(&local.col_widths), .{}, .{
            .min_size_content = .{ .h = 530 },
            .expand = .both,
            .background = true,
            //.border = dvui.Rect.all(2),
            .corner_radius = .all(0),
        });
        defer grid.deinit();

        var banded: dvui.GridWidget.CellStyle.HoveredRow = .{
            .cell_opts = .{
                .background = true,
                .color_fill_hover = dvui.themeGet().color(.control, .fill_hover),
            },
        };
        banded.processEvents(grid);

        const col_widths_src = local.equal_spacing;

        dvui.columnLayoutProportional(
            &col_widths_src,
            &local.col_widths,
            grid.data().contentRect().w,
        );

        dvui.gridHeading(@src(), grid, 0, "Title", local.headerResizeOptions(grid, 0), .{});
        dvui.gridHeading(@src(), grid, 1, "Username", local.headerResizeOptions(grid, 1), .{});
        dvui.gridHeading(@src(), grid, 2, "URL", local.headerResizeOptions(grid, 2), .{});

        const searchText = dvui.dataGetSlice(null, uniqueId, "searchText", []const u8) orelse "";

        // for loop
        if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
            local.row_num = 0;
            blk: for (group.entries.items, 0..) |item, eidx| {
                const title = item.get("Title") orelse "";
                const username = item.get("UserName") orelse "";
                const url = item.get("URL") orelse "";

                if (!searchTextMatchesEntry(item, searchText, allocator)) continue :blk;

                var cell: dvui.GridWidget.Cell = .colRow(0, local.row_num);
                try local.index_map.put(allocator, local.row_num, eidx);
                defer local.row_num += 1;

                var opts: dvui.Options = .{
                    .corner_radius = .all(0),
                };
                var cellOpts: dvui.widgets.GridWidget.CellOptions = .{};

                if (local.selected_row != null and local.selected_row.? == local.row_num) {
                    opts = .{
                        .background = true,
                        .color_fill = dvui.themeGet().color(.control, .fill_hover),
                        .corner_radius = .all(0),
                    };
                    cellOpts = .{
                        .background = true,
                        .color_fill = dvui.themeGet().color(.control, .fill_hover),
                    };
                } else if (local.menu_active) {
                    opts = .{
                        .corner_radius = .all(0),
                    };
                    cellOpts = .{};
                } else {
                    opts = banded.options(cell);
                    cellOpts = banded.cellOptions(cell);
                }

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, cellOpts);
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        title,
                        .{},
                        opts,
                    );
                }

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, cellOpts);
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        username,
                        .{},
                        opts,
                    );
                }

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, cellOpts);
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        url,
                        .{},
                        opts,
                    );
                }
            }

            // Mouse / Keyboard handling

            // Right click => context menu
            {
                const ctext = dvui.context(@src(), .{ .rect = grid.data().borderRectScale().r }, .{});
                defer ctext.deinit();

                if (ctext.activePoint()) |cp| {
                    if (!local.menu_active) {
                        if (grid.pointToCell(dvui.currentWindow().mouse_pt)) |cell| {
                            local.selected_row = cell.row_num;
                            local.selected_entry_id = local.index_map.get(cell.row_num);
                            local.selected_entry_guuid = group.uuid;
                        }

                        local.menu_active = true;
                    }

                    const entry = group.entries.items[local.selected_entry_id.?];

                    var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
                    defer fw2.deinit();

                    if (entry.get("UserName")) |v| blk: {
                        if (v.len == 0) break :blk;

                        if (dvui.menuItemLabel(@src(), "Copy Username", .{}, .{ .expand = .horizontal }) != null) {
                            dvui.clipboardTextSet(v);
                            dvui.toast(@src(), .{ .message = "Username copied to clipboard" });
                            local.cb_seconds_remaining = 20;
                            local.cb_ts = std.time.timestamp();
                            ctext.close();
                        }
                    }

                    if (entry.get("Password")) |v| blk: {
                        if (v.len == 0) break :blk;

                        if (dvui.menuItemLabel(@src(), "Copy Password", .{}, .{ .expand = .horizontal }) != null) {
                            dvui.clipboardTextSet(v);
                            dvui.toast(@src(), .{ .message = "Password copied to clipboard" });
                            local.cb_seconds_remaining = 20;
                            local.cb_ts = std.time.timestamp();
                            ctext.close();
                        }
                    }
                } else local.menu_active = false;
            }

            const evts = dvui.events();
            for (evts) |*e| {
                if (!dvui.eventMatchSimple(e, grid.data())) {
                    continue;
                }

                // Left click => select entry
                if (e.evt == .mouse and e.evt.mouse.action == .press) {
                    if (grid.pointToCell(dvui.currentWindow().mouse_pt)) |cell| {
                        //std.debug.print("klicked {d}\n", .{cell.row_num});
                        local.selected_row = cell.row_num;
                        local.selected_entry_id = local.index_map.get(cell.row_num);
                        local.selected_entry_guuid = group.uuid;
                    }
                }
            }
        }
    }
}

fn drawAdvanced(uniqueId: dvui.Id, local: anytype) !void {
    const local2 = struct {
        // Title, Username, URL, Last Modified
        const num_cols = 2;
        const equal_spacing = [num_cols]f32{ -1, -1 };
        var col_widths: [num_cols]f32 = @splat(100); // Default width to 100
    };

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    {
        var grid = dvui.grid(@src(), .colWidths(&local2.col_widths), .{}, .{
            .expand = .both,
            .background = true,
            .corner_radius = .all(0),
            //.border = dvui.Rect.all(2),
        });
        defer grid.deinit();

        var banded: dvui.GridWidget.CellStyle.HoveredRow = .{
            .cell_opts = .{
                .background = true,
                .color_fill_hover = dvui.themeGet().color(.control, .fill_hover),
            },
        };
        banded.processEvents(grid);

        const col_widths_src = local2.equal_spacing;

        dvui.columnLayoutProportional(
            &col_widths_src,
            &local2.col_widths,
            grid.data().contentRect().w,
        );

        dvui.gridHeading(@src(), grid, 0, "Key", local.headerResizeOptions(grid, 0), .{});
        dvui.gridHeading(@src(), grid, 1, "Value", local.headerResizeOptions(grid, 1), .{});

        if (local.selected_entry_id) |eid| blk: {
            if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
                // Make sure the group hasn't changed and the index is not out of bounds.
                if (local.selected_entry_guuid != group.uuid or eid >= group.entries.items.len) {
                    local.selected_entry_id = null;
                    local.selected_row = null;
                    break :blk;
                }

                const entry = group.entries.items[eid];

                for (entry.strings.items, 0..) |kv, row_num| {
                    var cell: dvui.GridWidget.Cell = .colRow(0, row_num);

                    {
                        defer cell.col_num += 1;
                        var cell_box = grid.bodyCell(@src(), cell, banded.cellOptions(cell));
                        defer cell_box.deinit();
                        dvui.labelNoFmt(
                            @src(),
                            kv.key,
                            .{},
                            banded.options(cell),
                        );
                    }

                    {
                        defer cell.col_num += 1;
                        var cell_box = grid.bodyCell(@src(), cell, banded.cellOptions(cell));
                        defer cell_box.deinit();
                        var text = dvui.textLayout(@src(), .{ .break_lines = true }, .{ .background = false });
                        defer text.deinit();
                        text.addText(kv.value, banded.options(cell));
                    }
                }
            }
        }
    }
}

fn drawGeneral(uniqueId: dvui.Id, local: anytype) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    if (local.selected_entry_id) |eid| blk: {
        if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
            // Make sure the group hasn't changed and the index is not out of bounds.
            if (local.selected_entry_guuid != group.uuid or eid >= group.entries.items.len) {
                local.selected_entry_id = null;
                local.selected_row = null;
                break :blk;
            }

            const entry = group.entries.items[eid];

            dvui.label(
                @src(),
                "{s}",
                .{
                    if (entry.get("Title")) |v| v else "",
                },
                .{},
            );

            var left_alignment = dvui.Alignment.init(@src(), 0);
            defer left_alignment.deinit();

            {
                var inner_hbox = dvui.box(
                    @src(),
                    .{ .dir = .horizontal },
                    .{
                        .expand = .horizontal,
                        .corner_radius = .all(0),
                    },
                );
                defer inner_hbox.deinit();

                dvui.label(
                    @src(),
                    "User Name",
                    .{},
                    .{
                        .gravity_y = 0.5,
                    },
                );
                left_alignment.spacer(@src(), 0);

                if (entry.get("UserName")) |v| blk2: {
                    if (v.len == 0) break :blk2;

                    var ttout: dvui.WidgetData = undefined;
                    if (dvui.button(
                        @src(),
                        v,
                        .{},
                        .{
                            .gravity_y = 0.5,
                            .data_out = &ttout,
                            .corner_radius = .all(0),
                        },
                    )) {
                        dvui.clipboardTextSet(v);
                        dvui.toast(@src(), .{ .message = "Username copied to clipboard" });
                        local.cb_seconds_remaining = 20;
                        local.cb_ts = std.time.timestamp();
                    }
                    dvui.tooltip(@src(), .{ .active_rect = ttout.borderRectScale().r }, "Copy Username to clipboard", .{}, .{});
                }
            }

            {
                var inner_hbox = dvui.box(
                    @src(),
                    .{ .dir = .horizontal },
                    .{
                        .expand = .horizontal,
                        .corner_radius = .all(0),
                    },
                );
                defer inner_hbox.deinit();

                dvui.label(
                    @src(),
                    "URL",
                    .{},
                    .{
                        .gravity_y = 0.5,
                    },
                );
                left_alignment.spacer(@src(), 0);

                if (entry.get("URL")) |url| {
                    dvui.link(@src(), .{
                        .label = url,
                        .url = url,
                    }, .{
                        .gravity_y = 0.5,
                    });
                }
            }

            {
                var inner_hbox = dvui.box(
                    @src(),
                    .{ .dir = .horizontal },
                    .{
                        .expand = .horizontal,
                        .corner_radius = .all(0),
                    },
                );
                defer inner_hbox.deinit();

                dvui.label(
                    @src(),
                    "Password",
                    .{},
                    .{
                        .gravity_y = 0.5,
                    },
                );

                left_alignment.spacer(@src(), 0);

                if (entry.get("Password")) |v| blk2: {
                    if (v.len == 0) break :blk2;

                    var ttout: dvui.WidgetData = undefined;
                    if (dvui.button(
                        @src(),
                        "*****",
                        .{},
                        .{
                            .gravity_y = 0.5,
                            .data_out = &ttout,
                            .corner_radius = .all(0),
                        },
                    )) {
                        dvui.clipboardTextSet(v);
                        dvui.toast(@src(), .{ .message = "Password copied to clipboard" });
                        local.cb_seconds_remaining = 20;
                        local.cb_ts = std.time.timestamp();
                    }
                    dvui.tooltip(@src(), .{ .active_rect = ttout.borderRectScale().r }, "Copy password to clipboard", .{}, .{});
                }
            }

            {
                var inner_hbox = dvui.box(
                    @src(),
                    .{ .dir = .horizontal },
                    .{
                        .expand = .horizontal,
                        .corner_radius = .all(0),
                    },
                );
                defer inner_hbox.deinit();

                dvui.label(
                    @src(),
                    "Notes",
                    .{},
                    .{
                        .gravity_y = 0.5,
                    },
                );

                left_alignment.spacer(@src(), 0);

                if (entry.get("Notes")) |v| blk2: {
                    if (v.len == 0) break :blk2;

                    var notes_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
                    defer notes_scroll.deinit();

                    var tl = dvui.textLayout(
                        @src(),
                        .{},
                        .{
                            .expand = .both,
                            .corner_radius = .all(0),
                        },
                    );
                    defer tl.deinit();

                    tl.addText(v, .{});
                }
            }
        }
    }
}

fn contextWindow(uniqueId: dvui.Id, local: anytype) void {
    var tbox = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .h = 360 },
        .max_size_content = .height(360),
        .expand = .horizontal,
        //.border = dvui.Rect.all(1),
        .corner_radius = .all(0),
        .gravity_y = 1.0,
    });
    defer tbox.deinit();

    {
        var tabs = dvui.tabs(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer tabs.deinit();
        for (0..GridType.num_grids) |tab_num| {
            const this_tab: GridType = @enumFromInt(tab_num);

            if (tabs.addTabLabel(local.tabSelected(this_tab), local.tabName(this_tab))) {
                local.active_grid = this_tab;
            }
        }
    }

    switch (local.active_grid) {
        .general => try drawGeneral(uniqueId, &local),
        .advanced => try drawAdvanced(uniqueId, &local),
    }
}

// Status bar displaying additional information like the
// number of entries displayed or the time remaining until
// the clipboard is cleared.
fn statusBar(uniqueId: dvui.Id, local: anytype) void {
    var sbox = dvui.box(@src(), .{
        .dir = .horizontal,
    }, .{
        .min_size_content = .{ .h = 30 },
        .expand = .horizontal,
        //.border = dvui.Rect.all(1),
        .gravity_y = 1.0,
        .corner_radius = .all(0),
    });
    defer sbox.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
        dvui.label(@src(), "Selected Group: {s}, #Entries: {d}", .{ group.name, local.row_num }, .{
            .gravity_y = 0.5,
        });
    }

    if (local.cb_seconds_remaining) |*rem| blk: {
        const curr = std.time.timestamp();
        if (curr >= local.cb_ts.? + rem.*) {
            local.cb_seconds_remaining = null;
            local.cb_ts = null;
            dvui.clipboardTextSet("\x00"); // empty clip board
            break :blk;
        }

        const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
        const left = @as(i32, @intCast(@rem(millis, 1000)));

        {
            var mslabel = dvui.LabelWidget.init(@src(), "Clipboard: {d}s", .{local.cb_ts.? + rem.* - curr}, .{}, .{
                .gravity_x = 1.0,
                .gravity_y = 0.5,
            });
            defer mslabel.deinit();

            mslabel.draw();

            if (dvui.timerDoneOrNone(mslabel.data().id)) {
                const wait = 1000 * (1000 - left);
                dvui.timer(mslabel.data().id, wait);
            }
        }
    }
}

// Logic

fn getEntryIndexFromRowNum(
    group: *const kdbx.Group,
    row_num: usize,
    search: []const u8,
    allocator: std.mem.Allocator,
) ?usize {
    if (group.entries.items.len >= row_num) return null;

    var idx2: usize = 0;
    for (group.entries.items, 0..) |e, idx| {
        if (!searchTextMatchesEntry(e, search, allocator)) continue;
        if (idx2 == row_num) return idx;
        idx2 += 1;
    }

    return null;
}

fn searchTextMatchesEntry(e: kdbx.Entry, text: []const u8, allocator: std.mem.Allocator) bool {
    if (text.len == 0) return true;

    const title = e.get("Title") orelse "";
    const username = e.get("UserName") orelse "";
    const url = e.get("URL") orelse "";

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(allocator);
    arr.appendSlice(allocator, title) catch return true;
    arr.appendSlice(allocator, username) catch return true;
    arr.appendSlice(allocator, url) catch return true;

    for (arr.items) |*item| item.* = std.ascii.toLower(item.*);

    if (std.mem.indexOf(u8, arr.items, text) != null) {
        return true;
    }

    return false;
}
