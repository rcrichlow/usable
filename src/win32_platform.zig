const std = @import("std");
const c = @cImport({
    @cInclude("windows.h");
    @cInclude("wingdi.h");
});
const app = @import("app.zig");
const types = @import("types.zig");

const BYTES_PER_PIXEL = 4;

var g_background_brush: c.HBRUSH = null;
var g_hwnd: c.HWND = null;
var g_backbuffer: Backbuffer = .{};
var g_running = true;
var g_app_memory: types.AppMemory = undefined;
var g_initial_url: []const u8 = "http://example.com";

const DibBuffer = struct {
    memory: [*]u8 = undefined,
    width: i32 = 0,
    height: i32 = 0,
    pitch: i32 = 0,
    hdc: c.HDC = null,
    hbmp: c.HBITMAP = null,
    old_bmp: c.HGDIOBJ = null,

    fn init(self: *DibBuffer, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
        self.pitch = @divTrunc((width * BYTES_PER_PIXEL + 3), 4) * 4;

        self.hdc = c.CreateCompatibleDC(null);
        if (self.hdc == null) {
            std.debug.print("Failed to create compatible DC\n", .{});
            return;
        }

        var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        bmi.bmiHeader.biHeight = -height;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        self.hbmp = c.CreateDIBSection(self.hdc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
        if (self.hbmp == null or bits == null) {
            std.debug.print("Failed to create DIB section\n", .{});
            if (self.hdc != null) {
                _ = c.DeleteDC(self.hdc);
                self.hdc = null;
            }
            self.hbmp = null;
            return;
        }

        self.memory = @ptrCast(bits);
        self.old_bmp = c.SelectObject(self.hdc, self.hbmp);
    }

    fn destroy(self: *DibBuffer) void {
        if (self.hdc != null) {
            if (self.old_bmp != null) {
                _ = c.SelectObject(self.hdc, self.old_bmp);
            }
            if (self.hbmp != null) {
                _ = c.DeleteObject(self.hbmp);
            }
            _ = c.DeleteDC(self.hdc);
        }

        self.width = 0;
        self.height = 0;
        self.pitch = 0;
        self.hdc = null;
        self.hbmp = null;
        self.old_bmp = null;
    }
};

const Backbuffer = struct {
    buffers: [2]DibBuffer = .{ .{}, .{} },
    front: u1 = 0,
    back: u1 = 1,
    width: i32 = 0,
    height: i32 = 0,

    fn init(self: *Backbuffer, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
        self.front = 0;
        self.back = 1;
        self.buffers[0].init(width, height);
        self.buffers[1].init(width, height);
    }

    fn destroy(self: *Backbuffer) void {
        self.buffers[0].destroy();
        self.buffers[1].destroy();
        self.width = 0;
        self.height = 0;
    }

    fn resize(self: *Backbuffer, new_width: i32, new_height: i32) void {
        if (new_width == self.width and new_height == self.height) return;
        if (new_width <= 0 or new_height <= 0) return;

        self.destroy();
        self.init(new_width, new_height);
    }

    fn isReady(self: *const Backbuffer) bool {
        return self.width > 0 and self.height > 0 and self.buffers[self.front].hdc != null and self.buffers[self.back].hdc != null;
    }

    fn getRenderBuffer(self: *Backbuffer) struct { memory: [*]u8, pitch: i32 } {
        return .{
            .memory = self.buffers[self.back].memory,
            .pitch = self.buffers[self.back].pitch,
        };
    }

    fn present(self: *Backbuffer) void {
        const tmp = self.front;
        self.front = self.back;
        self.back = tmp;
    }

    fn blitFront(self: *Backbuffer, hdc: c.HDC) void {
        const buf = &self.buffers[self.front];
        if (buf.hdc == null) return;

        _ = c.BitBlt(hdc, 0, 0, self.width, self.height, buf.hdc, 0, 0, c.SRCCOPY);
    }
};

fn currentOffscreenBuffer() types.OffscreenBuffer {
    const render = g_backbuffer.getRenderBuffer();
    return .{
        .memory = render.memory,
        .width = g_backbuffer.width,
        .height = g_backbuffer.height,
        .pitch = render.pitch,
        .bytes_per_pixel = BYTES_PER_PIXEL,
    };
}

fn requestPresent(hwnd: c.HWND) void {
    if (hwnd == null) return;
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
    _ = c.UpdateWindow(hwnd);
}

fn win32WndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            g_running = false;
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_ERASEBKGND => {
            return 1;
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            if (g_backbuffer.isReady()) {
                g_backbuffer.blitFront(hdc);
            }
            return 0;
        },
        c.WM_KEYDOWN => {
            const keycode: usize = @intCast(wparam);
            if (keycode == @as(usize, c.VK_F5) and g_backbuffer.isReady()) {
                var buffer = currentOffscreenBuffer();
                app.navigate(&g_app_memory, &buffer, g_initial_url);
                requestPresent(hwnd);
            }
            if (keycode == @as(usize, c.VK_ESCAPE)) {
                _ = c.DestroyWindow(hwnd);
            }
            return 0;
        },
        c.WM_SIZE => {
            var rect: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &rect) != 0) {
                g_backbuffer.resize(rect.right - rect.left, rect.bottom - rect.top);
            }
            return 0;
        },
        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn main() !void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("UsableBrowser");
    const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Usable Browser");

    if (std.process.argsAlloc(std.heap.page_allocator)) |args| {
        if (args.len > 1) {
            g_initial_url = std.heap.page_allocator.dupe(u8, args[1]) catch g_initial_url;
        }
        std.process.argsFree(std.heap.page_allocator, args);
    } else |_| {
        std.debug.print("Failed to parse args, using default URL\n", .{});
    }

    var wc: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = win32WndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = class_name;

    g_background_brush = c.CreateSolidBrush(0x00FFFFFF);
    defer {
        if (g_background_brush != null) {
            _ = c.DeleteObject(g_background_brush);
        }
    }
    wc.hbrBackground = g_background_brush;

    if (c.RegisterClassW(&wc) == 0) {
        const err = c.GetLastError();
        std.debug.print("Failed to register window class, error: {d}\n", .{err});
        return error.WindowClassRegistrationFailed;
    }

    var window_rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = 800,
        .bottom = 600,
    };
    _ = c.AdjustWindowRectEx(&window_rect, c.WS_OVERLAPPEDWINDOW, c.FALSE, 0);

    g_hwnd = c.CreateWindowExW(
        0,
        class_name,
        window_title,
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        window_rect.right - window_rect.left,
        window_rect.bottom - window_rect.top,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (g_hwnd == null) {
        return error.WindowCreationFailed;
    }

    var client_rect: c.RECT = undefined;
    if (c.GetClientRect(g_hwnd, &client_rect) == 0) {
        return error.WindowClientRectFailed;
    }

    g_backbuffer.init(client_rect.right - client_rect.left, client_rect.bottom - client_rect.top);
    defer g_backbuffer.destroy();

    const persistent_storage_size = 32 * 1024 * 1024;
    const transient_storage_size = 64 * 1024 * 1024;
    const total_size = persistent_storage_size + transient_storage_size;
    const memory_block = std.heap.page_allocator.alloc(u8, total_size) catch @panic("out of memory for app memory");
    defer std.heap.page_allocator.free(memory_block);
    const all_bytes = memory_block[0..total_size];

    const persistent = all_bytes[0..persistent_storage_size];
    const transient = all_bytes[persistent_storage_size..];

    var fixed_buffer = std.heap.FixedBufferAllocator.init(persistent);
    const arena = std.heap.ArenaAllocator.init(fixed_buffer.allocator());

    g_app_memory = .{
        .ft_library = undefined,
        .ft_face = undefined,
        .ft_is_initialized = false,
        .browser_state = .Idle,
        .current_url = &.{},
        .response_body = &.{},
        .error_message = &.{},
        .dom_tree = null,
        .layout_tree = null,
        .background_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .arena = arena,
        .persistent_storage = persistent,
        .transient_storage = transient,
    };

    std.debug.print("Platform: Win32 GDI double-buffered backbuffer\n", .{});

    _ = c.ShowWindow(g_hwnd, c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(g_hwnd);

    var msg: c.MSG = undefined;
    while (g_running) {
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                g_running = false;
                break;
            }

            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }

        if (!g_running) break;
        if (!g_backbuffer.isReady()) {
            c.Sleep(1);
            continue;
        }

        var buffer = currentOffscreenBuffer();
        app.updateAndRender(&g_app_memory, &buffer);
        g_backbuffer.present();
        requestPresent(g_hwnd);
        c.Sleep(1);
    }
}
