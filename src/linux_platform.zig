const std = @import("std");
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("sys/shm.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("time.h");
});
const app = @import("app.zig");
const types = @import("types.zig");

const BYTES_PER_PIXEL = 4;
const TARGET_FPS = 60;
const TARGET_SECONDS_PER_FRAME: f32 = 1.0 / @as(f32, TARGET_FPS);
const XImage = c.XImage;

/// Call the destroy function through the XImage function-pointer table.
/// XDestroyImage is a macro in C — Zig's @cImport can't resolve it cleanly.
fn xDestroyImage(img: *XImage) void {
    if (img.f.destroy_image) |destroy_fn| {
        _ = destroy_fn(img);
    }
}

// ---------------------------------------------------------------------------
// Temporary X error handler for SHM attach probe (issue #25)
// ---------------------------------------------------------------------------
var g_shm_attach_error: bool = false;

fn shmAttachErrorHandler(
    _: ?*c.Display,
    _: [*c]c.XErrorEvent,
) callconv(.c) c_int {
    g_shm_attach_error = true;
    return 0;
}

/// A single SHM-backed (or malloc-backed) pixel buffer.
const ShmBuffer = struct {
    ximage: *XImage,
    shm_info: c.XShmSegmentInfo,
    memory: [*]u8,
    pitch: i32,
    using_shm: bool,

    /// Initialize in-place. Must NOT be returned by value — XShmCreateImage
    /// stores a pointer to shm_info, so moving the struct invalidates it.
    fn init(self: *ShmBuffer, display: *c.Display, visual: *c.Visual, depth: c_int, w: i32, h: i32) void {
        self.using_shm = false;
        self.shm_info = std.mem.zeroes(c.XShmSegmentInfo);

        // Try MIT-SHM first for zero-copy blitting
        const shm_image: ?*XImage = c.XShmCreateImage(
            display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            null,
            &self.shm_info,
            @intCast(w),
            @intCast(h),
        );

        if (shm_image) |img| {
            const size: usize = @intCast(img.bytes_per_line * img.height);
            const shm_id = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o777);
            if (shm_id != -1) {
                const shm_addr = c.shmat(shm_id, null, 0);
                const shmat_failed = shm_addr == @as(*anyopaque, @ptrFromInt(std.math.maxInt(usize)));
                if (!shmat_failed) {
                    self.shm_info.shmid = shm_id;
                    self.shm_info.shmaddr = @ptrCast(shm_addr);
                    img.data = @ptrCast(shm_addr);
                    self.shm_info.readOnly = 0;

                    // Install a temporary error handler to catch async XShmAttach
                    // failures (#25). XShmAttach returning nonzero only means the
                    // request was queued; the server error (if any) arrives later.
                    g_shm_attach_error = false;
                    const prev_handler = c.XSetErrorHandler(shmAttachErrorHandler);
                    const attach_ok = c.XShmAttach(display, &self.shm_info) != 0;
                    _ = c.XSync(display, 0); // flush & wait for any error event
                    _ = c.XSetErrorHandler(prev_handler);

                    if (attach_ok and !g_shm_attach_error) {
                        self.ximage = img;
                        self.memory = @ptrCast(shm_addr);
                        self.pitch = img.bytes_per_line;
                        self.using_shm = true;
                        _ = c.shmctl(shm_id, c.IPC_RMID, null);
                        // Clear to white so the first Expose doesn't blit garbage
                        @memset(self.memory[0..size], 0xFF);
                        return;
                    }

                    // XShmAttach failed — detach the shared memory before giving up (#27)
                    _ = c.shmdt(shm_addr);
                }
                _ = c.shmctl(shm_id, c.IPC_RMID, null);
            }
            xDestroyImage(img);
        }

        // Fallback: plain XImage with malloc'd buffer
        const alloc_size = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * BYTES_PER_PIXEL;
        const raw = std.c.malloc(alloc_size) orelse @panic("out of memory for backbuffer");
        const raw_ptr: [*]u8 = @ptrCast(raw);

        const fallback_image: ?*XImage = c.XCreateImage(
            display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            0,
            @ptrCast(raw),
            @intCast(w),
            @intCast(h),
            32,
            0,
        );

        self.ximage = fallback_image orelse @panic("XCreateImage failed");
        self.memory = raw_ptr;
        self.pitch = self.ximage.bytes_per_line;
        // Clear to white so the first Expose doesn't blit garbage
        @memset(self.memory[0..alloc_size], 0xFF);
    }

    fn destroy(self: *ShmBuffer, display: *c.Display) void {
        if (self.using_shm) {
            // Drain any pending XShmPutImage blit before detaching (#26)
            _ = c.XSync(display, 0);
            _ = c.XShmDetach(display, &self.shm_info);
            _ = c.shmdt(self.shm_info.shmaddr);
        }
        xDestroyImage(self.ximage);
    }
};

/// Double-buffered backbuffer. The game writes into buffers[back] while the
/// X server reads from buffers[front]. After blitting, front and back swap.
const X11Backbuffer = struct {
    buffers: [2]ShmBuffer,
    front: u1,
    back: u1,
    width: i32,
    height: i32,
    display: *c.Display,
    visual: *c.Visual,
    depth: c_int,

    fn init(self: *X11Backbuffer, display: *c.Display, visual: *c.Visual, depth: c_int, w: i32, h: i32) void {
        self.display = display;
        self.visual = visual;
        self.depth = depth;
        self.width = w;
        self.height = h;
        self.front = 0;
        self.back = 1;
        self.buffers[0].init(display, visual, depth, w, h);
        self.buffers[1].init(display, visual, depth, w, h);
    }

    fn getRenderBuffer(self: *X11Backbuffer) struct { memory: [*]u8, pitch: i32 } {
        return .{
            .memory = self.buffers[self.back].memory,
            .pitch = self.buffers[self.back].pitch,
        };
    }

    fn blitAndSwap(self: *X11Backbuffer, window: c.Window, gc: c.GC) void {
        const buf = &self.buffers[self.back];
        if (buf.using_shm) {
            _ = c.XShmPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
                0,
            );
        } else {
            _ = c.XPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
            );
        }

        const tmp = self.front;
        self.front = self.back;
        self.back = tmp;
    }

    /// Blit the front buffer (for Expose repaints without swapping).
    fn blitFront(self: *X11Backbuffer, window: c.Window, gc: c.GC) void {
        const buf = &self.buffers[self.front];
        if (buf.using_shm) {
            _ = c.XShmPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
                0,
            );
        } else {
            _ = c.XPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
            );
        }
    }

    fn destroy(self: *X11Backbuffer) void {
        self.buffers[0].destroy(self.display);
        self.buffers[1].destroy(self.display);
    }

    /// Recreate both buffers at a new size. No-op if dimensions haven't changed.
    fn resize(self: *X11Backbuffer, new_w: i32, new_h: i32) void {
        if (new_w == self.width and new_h == self.height) return;
        if (new_w <= 0 or new_h <= 0) return;

        // Drain pending blits before destroying the old buffers (#26)
        _ = c.XSync(self.display, 0);
        self.destroy();
        self.init(self.display, self.visual, self.depth, new_w, new_h);
    }
};

// =============================================================================
// Clock helpers
// =============================================================================

fn getWallClock() c.struct_timespec {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) == -1) {
        @panic("clock_gettime(CLOCK_MONOTONIC) failed");
    }
    return ts;
}

fn secondsElapsed(start: c.struct_timespec, end: c.struct_timespec) f32 {
    const sec = end.tv_sec - start.tv_sec;
    const nsec = end.tv_nsec - start.tv_nsec;
    return @as(f32, @floatFromInt(sec)) + @as(f32, @floatFromInt(nsec)) / 1_000_000_000.0;
}

pub fn main() !void {
    const display = c.XOpenDisplay(null) orelse {
        std.debug.print("Failed to open X display\n", .{});
        return;
    };
    defer _ = c.XCloseDisplay(display);

    const screen = c.XDefaultScreen(display);
    const root_window = c.XRootWindow(display, screen);
    const visual = c.XDefaultVisual(display, screen);
    const depth = c.XDefaultDepth(display, screen);

    var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.background_pixel = 0xffffff; // white background
    attrs.event_mask = c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask | c.KeyReleaseMask;

    const window = c.XCreateWindow(
        display,
        root_window,
        0,
        0,
        800,
        600,
        0,
        depth,
        c.InputOutput,
        visual,
        c.CWBackPixel | c.CWEventMask,
        &attrs,
    );

    defer _ = c.XDestroyWindow(display, window);

    _ = c.XStoreName(display, window, "Usable Browser");
    _ = c.XMapWindow(display, window);
    _ = c.XSync(display, 0);

    const gc = c.XCreateGC(display, window, 0, null);
    defer _ = c.XFreeGC(display, gc);

    // Resolve keysyms to keycodes at startup so we aren't relying on
    // hardware-specific numeric values (#29).
    const keycode_f5: c_uint = c.XKeysymToKeycode(display, c.XK_F5);
    const keycode_escape: c_uint = c.XKeysymToKeycode(display, c.XK_Escape);

    // Get URL from command line args, fallback to example.com
    // Must duplicate the URL before args are freed to avoid use-after-free
    var initial_url: []const u8 = "http://example.com";
    if (std.process.argsAlloc(std.heap.page_allocator)) |args| {
        // args are freed at the END of main, not here
        if (args.len > 1) {
            // Copy URL to our own allocation before anything else uses page_allocator
            initial_url = std.heap.page_allocator.dupe(u8, args[1]) catch initial_url;
        }
        // Free args immediately since we've copied what we need
        std.process.argsFree(std.heap.page_allocator, args);
    } else |_| {
        std.debug.print("Failed to parse args, using default URL\n", .{});
    }

    var backbuffer: X11Backbuffer = undefined;
    backbuffer.init(display, visual, depth, 800, 600);
    defer backbuffer.destroy();

    const persistent_storage_size = 32 * 1024 * 1024;
    const transient_storage_size = 64 * 1024 * 1024;
    const total_size = persistent_storage_size + transient_storage_size;
    const memory_block = std.heap.page_allocator.alloc(u8, total_size) catch @panic("out of memory for app memory");
    defer std.heap.page_allocator.free(memory_block);
    const all_bytes = memory_block[0..total_size];

    const persistent = all_bytes[0..persistent_storage_size];
    const transient = all_bytes[persistent_storage_size..];

    var persistent_buffer = std.heap.FixedBufferAllocator.init(persistent);
    var transient_buffer = std.heap.FixedBufferAllocator.init(transient);
    const persistent_arena = std.heap.ArenaAllocator.init(persistent_buffer.allocator());
    const transient_arena = std.heap.ArenaAllocator.init(transient_buffer.allocator());

    var app_memory: types.AppMemory = .{
        .ft_library = undefined,
        .ft_face = undefined,
        .ft_is_initialized = false,
        .ft_init_failed = false,
        .browser_state = .Idle,
        .current_url = &.{},
        .response_body = &.{},
        .error_message = &.{},
        .dom_tree = null,
        .layout_tree = null,
        .background_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, // white
        .text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .persistent_arena = persistent_arena,
        .transient_arena = transient_arena,
        .persistent_storage = persistent,
        .transient_storage = transient,
    };

    if (backbuffer.buffers[0].using_shm) {
        std.debug.print("Platform: using MIT-SHM double-buffered backbuffer\n", .{});
    } else {
        std.debug.print("Platform: using XPutImage fallback for backbuffer\n", .{});
    }

    var render = backbuffer.getRenderBuffer();
    var buffer = types.OffscreenBuffer{
        .memory = render.memory,
        .width = backbuffer.width,
        .height = backbuffer.height,
        .pitch = render.pitch,
        .bytes_per_pixel = BYTES_PER_PIXEL,
    };

    var running = true;
    var last_clock = getWallClock();
    while (running) {
        while (c.XPending(display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(display, &event);

            switch (event.type) {
                c.Expose => {
                    backbuffer.blitFront(window, gc);
                },
                c.KeyPress => {
                    const keycode = event.xkey.keycode;
                    std.debug.print("Key pressed: {d}\n", .{keycode});
                    if (keycode == keycode_f5) {
                        app.navigate(&app_memory, &buffer, initial_url);
                    }
                    if (keycode == keycode_escape) {
                        running = false;
                    }
                },
                c.ConfigureNotify => {
                    const width = event.xconfigure.width;
                    const height = event.xconfigure.height;
                    std.debug.print("Window resized: {d}x{d}\n", .{ width, height });
                    backbuffer.resize(width, height);
                    render = backbuffer.getRenderBuffer();
                    buffer.memory = render.memory;
                    buffer.pitch = render.pitch;
                    buffer.width = backbuffer.width;
                    buffer.height = backbuffer.height;

                    // Rebuild layout from the existing DOM using the transient arena,
                    // so resize reflow does not refetch or reparse the page.
                    if (app_memory.browser_state == .Loaded) {
                        app.reflow(&app_memory, &buffer);
                    }
                },
                else => {},
            }
        }

        render = backbuffer.getRenderBuffer();
        buffer.memory = render.memory;
        buffer.pitch = render.pitch;

        app.updateAndRender(&app_memory, &buffer);
        backbuffer.blitAndSwap(window, gc);
        _ = c.XFlush(display);

        // Cap at ~60 fps — sleep only the remaining time after frame work
        const work_elapsed = secondsElapsed(last_clock, getWallClock());
        if (work_elapsed < TARGET_SECONDS_PER_FRAME) {
            const sleep_s = TARGET_SECONDS_PER_FRAME - work_elapsed;
            const sleep_ns: u64 = @intFromFloat(sleep_s * 1_000_000_000.0);
            std.Thread.sleep(sleep_ns);
        }
        last_clock = getWallClock();
    }
}
