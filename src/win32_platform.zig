const std = @import("std");
const c = @cImport({
    @cInclude("windows.h");
    @cInclude("wingdi.h");
});
const app = @import("app.zig");

const BYTES_PER_PIXEL = 4;

var g_black_brush: c.HBRUSH = undefined;

/// Double-buffered backbuffer using GDI DIB sections
const Backbuffer = struct {
    memory: [*]u8 = undefined,
    width: i32 = 0,
    height: i32 = 0,
    pitch: i32 = 0,
    hdc: c.HDC = undefined,
    hbmp: c.HBITMAP = undefined,
    old_bmp: c.HGDIOBJ = undefined,

    fn init(self: *Backbuffer, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
        self.pitch = @divTrunc((width * BYTES_PER_PIXEL + 3), 4) * 4;

        self.hdc = c.CreateCompatibleDC(null);
        if (self.hdc == null) {
            std.debug.print("Failed to create compatible DC\n", .{});
            return;
        }

        var bmi: c.BITMAPINFO = undefined;
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        bmi.bmiHeader.biHeight = -height;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        self.hbmp = c.CreateDIBSection(self.hdc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);

        if (self.hbmp == null) {
            std.debug.print("Failed to create DIB section\n", .{});
            _ = c.DeleteDC(self.hdc);
            return;
        }

        self.memory = @ptrCast(bits);
        self.old_bmp = c.SelectObject(self.hdc, self.hbmp);
    }

    fn destroy(self: *Backbuffer) void {
        if (self.hdc != null) {
            _ = c.SelectObject(self.hdc, self.old_bmp);
            if (self.hbmp != null) {
                _ = c.DeleteObject(self.hbmp);
            }
            _ = c.DeleteDC(self.hdc);
        }
    }

    fn resize(self: *Backbuffer, new_width: i32, new_height: i32) void {
        if (new_width == self.width and new_height == self.height) return;
        if (new_width <= 0 or new_height <= 0) return;
        self.destroy();
        self.init(new_width, new_height);
    }
};

var g_hwnd: c.HWND = undefined;
var g_backbuffer: Backbuffer = undefined;
var g_running: bool = true;
var g_app_memory: app.AppMemory = undefined;

fn win32_wndproc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_DESTROY => {
            g_running = false;
            _ = c.PostQuitMessage(0);
            return 0;
        },
        c.WM_PAINT => {
            // Render to backbuffer and blit during paint
            if (g_backbuffer.hdc != null and g_backbuffer.width > 0 and g_backbuffer.height > 0) {
                var buffer = app.OffscreenBuffer{
                    .memory = g_backbuffer.memory,
                    .width = g_backbuffer.width,
                    .height = g_backbuffer.height,
                    .pitch = g_backbuffer.pitch,
                    .bytes_per_pixel = BYTES_PER_PIXEL,
                };
                app.updateAndRender(&g_app_memory, &buffer);
            }
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            if (g_backbuffer.hdc != null) {
                _ = c.BitBlt(hdc, 0, 0, g_backbuffer.width, g_backbuffer.height, g_backbuffer.hdc, 0, 0, c.SRCCOPY);
            }
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        c.WM_KEYDOWN => {
            const keycode = wparam;
            if (keycode == 13) {
                app.start() catch |err| {
                    std.debug.print("Application error: {any}\n", .{err});
                };
            }
            if (keycode == 27) {
                g_running = false;
            }
            return 0;
        },
        c.WM_SIZE => {
            const width = @as(i32, @intCast(lparam & 0xFFFF));
            const height = @as(i32, @intCast((lparam >> 16) & 0xFFFF));
            g_backbuffer.resize(width, height);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn main() !void {
    const class_name: [16]u16 = .{ 'U', 's', 'a', 'b', 'l', 'e', 'B', 'r', 'o', 'w', 's', 'e', 'r', 0, 0, 0 };

    var wc: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = win32_wndproc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = &class_name;

    // Create black brush manually
    g_black_brush = c.CreateSolidBrush(0x000000);
    defer _ = c.DeleteObject(g_black_brush);
    wc.hbrBackground = g_black_brush;

    if (c.RegisterClassW(&wc) == 0) {
        const err = c.GetLastError();
        std.debug.print("Failed to register window class, error: {d}\n", .{err});
        return error.WindowClassRegistrationFailed;
    }

    const window_title: [16]u16 = .{ 'U', 's', 'a', 'b', 'l', 'e', ' ', 'B', 'r', 'o', 'w', 's', 'e', 'r', 0, 0 };
    g_hwnd = c.CreateWindowExW(0, &class_name, &window_title, c.WS_OVERLAPPEDWINDOW, c.CW_USEDEFAULT, c.CW_USEDEFAULT, 800, 600, null, null, c.GetModuleHandleW(null), null);

    if (g_hwnd == null) {
        return error.WindowCreationFailed;
    }

    _ = c.ShowWindow(g_hwnd, c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(g_hwnd);

    g_backbuffer.init(800, 600);
    defer g_backbuffer.destroy();

    const persistent_storage_size = 32 * 1024 * 1024;
    const transient_storage_size = 64 * 1024 * 1024;
    const total_size = persistent_storage_size + transient_storage_size;
    const memory_block = try std.heap.page_allocator.alloc(u8, total_size);
    defer std.heap.page_allocator.free(memory_block);

    const all_bytes = memory_block[0..total_size];
    g_app_memory.persistent_storage = all_bytes[0..persistent_storage_size];
    g_app_memory.transient_storage = all_bytes[persistent_storage_size..];

    std.debug.print("Platform: Win32 GDI backbuffer\n", .{});

    var msg: c.MSG = undefined;
    while (g_running) {
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }

        if (!g_running) break;

        if (g_backbuffer.hdc != null and g_backbuffer.width > 0 and g_backbuffer.height > 0) {
            var buffer = app.OffscreenBuffer{
                .memory = g_backbuffer.memory,
                .width = g_backbuffer.width,
                .height = g_backbuffer.height,
                .pitch = g_backbuffer.pitch,
                .bytes_per_pixel = BYTES_PER_PIXEL,
            };

            app.updateAndRender(&g_app_memory, &buffer);

            // Force window repaint
            _ = c.InvalidateRect(g_hwnd, null, 0);

            if (g_hwnd != null) {
                var paint: c.PAINTSTRUCT = undefined;
                const hdc = c.BeginPaint(g_hwnd, &paint);
                _ = c.BitBlt(hdc, 0, 0, g_backbuffer.width, g_backbuffer.height, g_backbuffer.hdc, 0, 0, c.SRCCOPY);
                _ = c.EndPaint(g_hwnd, &paint);
            }
        }

        c.Sleep(1);
    }
}
