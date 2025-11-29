const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const kdbx = @import("kdbx");
const root = @import("root");

pub fn draw(uniqueId: dvui.Id) void {
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
    };

    const banded: dvui.GridWidget.CellStyle.Banded = .{
        .opts = .{
            .margin = dvui.TextLayoutWidget.defaults.margin,
            .padding = dvui.TextLayoutWidget.defaults.padding,
        },
        .alt_cell_opts = .{
            .color_fill = dvui.themeGet().color(.control, .fill_press),
            .background = true,
        },
    };
    const banded_centered = banded.optionsOverride(.{ .gravity_x = 0.5, .expand = .horizontal });
    _ = banded_centered;

    var grid = dvui.grid(@src(), .colWidths(&local.col_widths), .{}, .{
        .expand = .both,
        .background = true,
        .border = dvui.Rect.all(2),
    });
    defer grid.deinit();

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
    }
}
