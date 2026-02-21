const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const kdbx = @import("kdbx");
const root = @import("root");
const clipboard = @import("clipboard");

pub fn draw(uniqueId: dvui.Id) void {
    const local = struct {
        // Title, Username, URL, Last Modified
        const num_cols = 3;
        const equal_spacing = [num_cols]f32{ -1, -1, -1 };
        var col_widths: [num_cols]f32 = @splat(100); // Default width to 100

        var highlighted_row: ?usize = null;

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

        var selected_entry_id: ?usize = null;
        var selected_entry_guuid: ?u128 = null;
    };

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    // This is the context window for an entry which is placed on the bottom
    // (below the table).
    {
        var outer_vbox = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .min_size_content = .{ .h = 180 },
            .expand = .both,
            .border = dvui.Rect.all(1),
            .gravity_y = 1.0,
        });
        defer outer_vbox.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        if (local.selected_entry_id) |eid| blk: {
            if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
                // Make sure the group hasn't changed and the index is not out of bounds.
                if (local.selected_entry_guuid != group.uuid or eid >= group.entries.items.len) {
                    local.selected_entry_id = null;
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
                    var inner_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer inner_hbox.deinit();

                    dvui.label(@src(), "User Name", .{}, .{});
                    left_alignment.spacer(@src(), 0);

                    dvui.label(@src(), "{s}", .{
                        if (entry.get("UserName")) |v| v else "",
                    }, .{});
                }

                {
                    var inner_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer inner_hbox.deinit();

                    dvui.label(@src(), "URL", .{}, .{});
                    left_alignment.spacer(@src(), 0);

                    if (entry.get("URL")) |url| {
                        dvui.link(@src(), .{
                            .label = url,
                            .url = url,
                        }, .{});
                    }
                }

                {
                    var inner_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer inner_hbox.deinit();

                    dvui.label(@src(), "Password", .{}, .{});

                    left_alignment.spacer(@src(), 0);

                    dvui.label(@src(), "*****", .{}, .{});
                }
            }
        }
    }

    {
        var grid = dvui.grid(@src(), .colWidths(&local.col_widths), .{}, .{
            .expand = .both,
            .background = true,
            .border = dvui.Rect.all(2),
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

        // for loop
        if (dvui.dataGet(null, uniqueId, "group", *kdbx.Group)) |group| {
            for (group.entries.items, 0..) |item, row_num| {
                var cell: dvui.GridWidget.Cell = .colRow(0, row_num);

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, banded.cellOptions(cell));
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        if (item.get("Title")) |name| name else "",
                        .{},
                        banded.options(cell),
                    );
                }

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, banded.cellOptions(cell));
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        if (item.get("UserName")) |name| name else "",
                        .{},
                        banded.options(cell),
                    );
                }

                {
                    defer cell.col_num += 1;
                    var cell_box = grid.bodyCell(@src(), cell, banded.cellOptions(cell));
                    defer cell_box.deinit();
                    dvui.labelNoFmt(
                        @src(),
                        if (item.get("URL")) |name| name else "",
                        .{},
                        banded.options(cell),
                    );
                }
            }

            // Mouse / Keyboard handling

            // Right click => context menu
            {
                const ctext = dvui.context(@src(), .{ .rect = grid.data().borderRectScale().r }, .{});
                defer ctext.deinit();

                if (ctext.activePoint()) |cp| {
                    var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
                    defer fw2.deinit();

                    if (dvui.menuItemLabel(@src(), "Copy Username", .{}, .{ .expand = .horizontal }) != null) {
                        clipboard.write("hello") catch {};
                        ctext.close();
                        //if (grid.pointToCell(cp.)) |cell| {
                        //    const e = group.entries.items[cell.row_num];
                        //    std.debug.print("{s}\n", .{e.get("UserName").?});
                        //}
                    }
                    _ = dvui.menuItemLabel(@src(), "Copy Password", .{}, .{ .expand = .horizontal });
                }
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
                        local.selected_entry_id = cell.row_num;
                        local.selected_entry_guuid = group.uuid;
                    }
                }
            }
        }
    }
}
