const std = @import("std");
const LazyPath = std.Build.LazyPath;
const mem = std.mem;
const path = std.fs.path;
const LinkMode = std.builtin.LinkMode;

const Configure = @import("util").Configure;
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cfg: Configure = .init(b, .default);
    const is_native = target.query.isNative();
    const os = target.result.os.tag;
    const endian = target.result.cpu.arch.endian();

    const session = b.option(bool, "session", "Enable session support (auto)") orelse
        (is_native and cfg.exists("libudev"));
    const xwayland = b.option(bool, "xwayland", "Enable Xwayland support (auto)") orelse
        (is_native and cfg.exists("xwayland"));

    const options = .{
        .linkage = b.option(LinkMode, "linkage", "Library linkage type") orelse .static,
        .session = session,
        .@"drm-backend" = b.option(bool, "drm-backend", "Build the DRM backend (auto)") orelse
            (is_native and session and cfg.exists("hwdata")),
        .@"libinput-backend" = b.option(bool, "libinput-backend", "Build the libinput backend (auto)") orelse
            (is_native and session and cfg.atleastVersion("libinput", "1.19.0")),
        .@"x11-backend" = b.option(bool, "x11-backend", "Build the X11 backend (auto)") orelse
            (is_native and cfg.exists("xcb") and cfg.exists("xcb-xinput")),
        .xwayland = xwayland,
        .@"gles2-renderer" = b.option(bool, "gles2-renderer", "Build the GLES2 renderer (auto)") orelse
            (is_native and cfg.exists("egl") and cfg.exists("gbm") and cfg.exists("glesv2") and (cfg.evalHeaderConstant("EGL/eglext.h", "EGL_EGLEXT_VERSION") orelse 0) >= 20210604),
        .@"vulkan-renderer" = b.option(bool, "vulkan-renderer", "Build the Vulkan renderer (auto)") orelse
            (is_native and cfg.atleastVersion("vulkan", "1.2.182") and cfg.hasHeader("vulkan/vulkan.h")),
        .@"gbm-allocator" = b.option(bool, "gbm-allocator", "Build the GBM allocator (auto)") orelse
            (is_native and cfg.atleastVersion("gbm", "21.1")),
        .@"udmabuf-allocator" = b.option(bool, "udmabuf-allocator", "Build the udmabuf allocator (auto)") orelse
            (is_native and cfg.hasHeader("linux/udmabuf.h")),
        .@"color-management" = b.option(bool, "color-management", "Enable color management via lcms2 (auto)") orelse true,
        .@"xcb-errors" = b.option(bool, "xcb-errors", "Use xcb-errors utility library (auto)") orelse
            (is_native and cfg.exists("xcb-errors")),
        .libliftoff = b.option(bool, "libliftoff", "Enable libliftoff for DRM atomic (auto)") orelse true,
        .icon_directory = b.option([]const u8, "icon-directory", "Location for cursors"),
        .@"xwayland-path" = if (xwayland)
            (b.option([]const u8, "xwayland-path", "Path to Xwayland binary") orelse
                cfg.variable("xwayland", "xwayland") orelse "/usr/bin/Xwayland")
        else
            null,
        .@"hwdata-dir" = b.option([]const u8, "hwdata-dir", "Path to hwdata data dir") orelse
            cfg.variable("hwdata", "pkgdatadir") orelse "/usr/share/hwdata",
    };

    const pkgs = .{
        .wayland_protocols = if (!b.systemIntegrationOption("wayland_protocols", .{}))
            b.lazyDependency("wayland_protocols", .{}) orelse return
        else
            null,
        .wayland = if (!b.systemIntegrationOption("wayland", .{}))
            b.lazyDependency("wayland", .{ .target = target, .optimize = optimize })
        else
            null,
        .pixman = if (!b.systemIntegrationOption("pixman", .{}))
            b.lazyDependency("pixman", .{ .target = target, .optimize = optimize })
        else
            null,
        .xkbcommon = if (!b.systemIntegrationOption("xkbcommon", .{}))
            b.lazyDependency("xkbcommon", .{ .target = target, .optimize = optimize })
        else
            null,
        .libdrm = if (!b.systemIntegrationOption("libdrm", .{}))
            b.lazyDependency("libdrm", .{ .target = target, .optimize = optimize })
        else
            null,
        .libliftoff = if (options.@"drm-backend" and options.libliftoff and !b.systemIntegrationOption("libliftoff", .{}))
            b.lazyDependency("libliftoff", .{ .target = target, .optimize = optimize })
        else
            null,
        .libdisplay_info = if (options.@"drm-backend" and !b.systemIntegrationOption("libdisplay_info", .{}))
            b.lazyDependency("libdisplay_info", .{ .target = target, .optimize = optimize })
        else
            null,
        .libseat = if (options.session and !b.systemIntegrationOption("libseat", .{}))
            b.lazyDependency("libseat", .{ .target = target, .optimize = optimize })
        else
            null,
        .lcms2 = if (options.@"color-management" and !b.systemIntegrationOption("lcms2", .{}))
            b.lazyDependency("lcms2", .{ .target = target, .optimize = optimize })
        else
            null,
    };

    const upstream = b.lazyDependency("wlroots_c", .{}) orelse return;
    const version: std.SemanticVersion = try .parse(manifest.version);

    const config_wf = b.addWriteFiles();
    _ = config_wf.add("wlr/version.h", b.fmt(
        \\#ifndef WLR_VERSION_H
        \\#define WLR_VERSION_H
        \\#define WLR_VERSION_STR "{s}"
        \\#define WLR_VERSION_MAJOR {d}
        \\#define WLR_VERSION_MINOR {d}
        \\#define WLR_VERSION_MICRO {d}
        \\#define WLR_VERSION_NUM ((WLR_VERSION_MAJOR << 16) | (WLR_VERSION_MINOR << 8) | WLR_VERSION_MICRO)
        \\int wlr_version_get_major(void);
        \\int wlr_version_get_minor(void);
        \\int wlr_version_get_micro(void);
        \\#endif
        \\
    , .{ manifest.version, version.major, version.minor, version.patch }));

    const wlr_config_h = b.addConfigHeader(.{ .style = .blank, .include_path = "wlr/config.h" }, .{
        .WLR_HAS_DRM_BACKEND = @intFromBool(options.@"drm-backend"),
        .WLR_HAS_LIBINPUT_BACKEND = @intFromBool(options.@"libinput-backend"),
        .WLR_HAS_X11_BACKEND = @intFromBool(options.@"x11-backend"),
        .WLR_HAS_GLES2_RENDERER = @intFromBool(options.@"gles2-renderer"),
        .WLR_HAS_VULKAN_RENDERER = @intFromBool(options.@"vulkan-renderer"),
        .WLR_HAS_GBM_ALLOCATOR = @intFromBool(options.@"gbm-allocator"),
        .WLR_HAS_UDMABUF_ALLOCATOR = @intFromBool(options.@"udmabuf-allocator"),
        .WLR_HAS_XWAYLAND = @intFromBool(options.xwayland),
        .WLR_HAS_SESSION = @intFromBool(options.session),
        .WLR_HAS_COLOR_MANAGEMENT = @intFromBool(options.@"color-management"),
    });

    const internal_config_h = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .HAVE_XCB_ERRORS = options.@"xcb-errors",
        .HAVE_EGL = options.@"gles2-renderer",
        .HAVE_LIBLIFTOFF = options.libliftoff,
        .HAVE_LIBLIFTOFF_0_5 = options.libliftoff,
        .HAVE_LIBINPUT_BUSTYPE = options.@"libinput-backend" and cfg.atleastVersion("libinput", "1.26.0"),
        .HAVE_LIBINPUT_SWITCH_KEYPAD_SLIDE = options.@"libinput-backend" and cfg.atleastVersion("libinput", "1.30.901"),
        .HAVE_EVENTFD = cfg.hasHeader("sys/eventfd.h"),
        .XWAYLAND_PATH = options.@"xwayland-path",
        .HAVE_XWAYLAND_LISTENFD = options.xwayland and mem.eql(u8, cfg.variable("xwayland", "have_listenfd") orelse "", "true"),
        .HAVE_XWAYLAND_NO_TOUCH_POINTER_EMULATION = options.xwayland and std.mem.eql(u8, cfg.variable("xwayland", "have_no_touch_pointer_emulation") orelse "", "true"),
        .HAVE_XWAYLAND_FORCE_XRANDR_EMULATION = options.xwayland and std.mem.eql(u8, cfg.variable("xwayland", "have_force_xrandr_emulation") orelse "", "true"),
        .HAVE_XWAYLAND_TERMINATE_DELAY = options.xwayland and std.mem.eql(u8, cfg.variable("xwayland", "have_terminate_delay") orelse "", "true"),
        .ICONDIR = options.icon_directory orelse b.pathJoin(&.{ b.install_prefix, "share/icons" }),
    });

    // Protocol generation
    const wp: std.Build.LazyPath = if (pkgs.wayland_protocols) |dep|
        dep.namedLazyPath("root")
    else
        .{ .cwd_relative = cfg.variable("wayland-protocols", "pkgdatadir") orelse
            return error.MissingWaylandProtocols };

    const wf = b.addWriteFiles();
    var proto_c_files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (protocols.system) |subpath|
        try genProtocol(b, wf, &proto_c_files, wp.path(b, subpath), path.stem(subpath));
    for (protocols.custom) |subpath|
        try genProtocol(b, wf, &proto_c_files, upstream.path(subpath), path.stem(subpath));

    // Module
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCMacro("WLR_PRIVATE", "");
    mod.addCMacro("WLR_USE_UNSTABLE", "");
    mod.addCMacro("WLR_LITTLE_ENDIAN", if (endian == .little) "1" else "0");
    mod.addCMacro("WLR_BIG_ENDIAN", if (endian == .big) "1" else "0");
    if (!os.isBSD()) mod.addCMacro("_POSIX_C_SOURCE", "200809L");
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(wf.getDirectory());
    mod.addIncludePath(config_wf.getDirectory());
    mod.addConfigHeader(internal_config_h);
    mod.addConfigHeader(wlr_config_h);
    if (pkgs.wayland) |dep| {
        mod.linkLibrary(dep.artifact("wayland-server"));
        mod.linkLibrary(dep.artifact("wayland-client"));
    } else {
        mod.linkSystemLibrary("wayland-server", .{});
        mod.linkSystemLibrary("wayland-client", .{});
    }
    if (pkgs.pixman) |dep| mod.linkLibrary(dep.artifact("pixman-1")) else mod.linkSystemLibrary("pixman-1", .{});
    if (pkgs.xkbcommon) |dep| mod.linkLibrary(dep.artifact("xkbcommon")) else mod.linkSystemLibrary("xkbcommon", .{});
    if (pkgs.libdrm) |dep| mod.linkLibrary(dep.artifact("drm")) else mod.linkSystemLibrary("libdrm", .{});

    mod.addCSourceFiles(.{ .root = upstream.path(""), .files = srcs.core, .flags = flags });
    mod.addCSourceFiles(.{ .root = wf.getDirectory(), .files = proto_c_files.items, .flags = flags });
    mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = if (os == .linux and cfg.hasHeaderSymbol("linux/dma-buf.h", "DMA_BUF_IOCTL_IMPORT_SYNC_FILE"))
            &.{"render/dmabuf_linux.c"}
        else
            &.{"render/dmabuf_fallback.c"},
        .flags = flags,
    });

    if (options.@"color-management") {
        mod.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{"render/color_lcms2.c"}, .flags = flags });
        if (pkgs.lcms2) |dep| mod.linkLibrary(dep.artifact("lcms2")) else mod.linkSystemLibrary("lcms2", .{});
    } else mod.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{"render/color_fallback.c"}, .flags = flags });

    inline for (simple_features) |feat| if (@field(options, feat.option)) {
        if (feat.version_check) |vc| if (!cfg.atleastVersion(vc[0], vc[1])) return error.MissingDependency;
        if (feat.sources.len > 0) mod.addCSourceFiles(.{ .root = upstream.path(""), .files = feat.sources, .flags = flags });
        inline for (feat.deps) |lib| mod.linkSystemLibrary(lib, .{});
    };

    if (options.session) {
        if (pkgs.libseat) |dep|
            mod.linkLibrary(dep.artifact("seat"))
        else
            mod.linkSystemLibrary("libseat", .{});
    }

    if (options.@"drm-backend") {
        mod.addCSourceFiles(.{ .root = upstream.path(""), .files = srcs.drm, .flags = flags });
        mod.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{"types/wlr_drm_lease_v1.c"},
            .flags = flags,
        });

        if (pkgs.libdisplay_info) |dep|
            mod.linkLibrary(dep.artifact("display-info"))
        else
            mod.linkSystemLibrary("libdisplay-info", .{});

        const pnpids_wf = b.addWriteFiles();
        const gen = b.addRunArtifact(b.addExecutable(.{
            .name = "gen_pnpids",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen_pnpids.zig"),
                .target = b.graph.host,
            }),
        }));
        gen.addArg(b.fmt("{s}/pnp.ids", .{options.@"hwdata-dir"}));
        _ = pnpids_wf.addCopyFile(gen.captureStdOut(.{}), "pnpids.c");
        mod.addCSourceFiles(.{ .root = pnpids_wf.getDirectory(), .files = &.{"pnpids.c"}, .flags = flags });
        if (options.libliftoff) {
            mod.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{"backend/drm/libliftoff.c"}, .flags = flags });
            if (pkgs.libliftoff) |dep| mod.linkLibrary(dep.artifact("liftoff")) else mod.linkSystemLibrary("libliftoff", .{});
        }
    }

    if (options.@"gles2-renderer") {
        const shader_wf = b.addWriteFiles();
        const embed_tool = b.addExecutable(.{
            .name = "embed",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/embed.zig"),
                .target = b.graph.host,
            }),
        });

        inline for (shaders.gles2) |shader| {
            const embed = b.addRunArtifact(embed_tool);
            embed.addArg(comptime dotToUnderscore(shader) ++ "_src");
            embed.addFileArg(upstream.path("render/gles2/shaders/" ++ shader));
            _ = shader_wf.addCopyFile(embed.captureStdOut(.{}), comptime dotToUnderscore(shader) ++ "_src.h");
        }

        mod.addIncludePath(shader_wf.getDirectory());
        mod.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs.gles2,
            .flags = flags,
        });
        mod.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{"render/egl.c"},
            .flags = flags,
        });
        inline for (.{ "glesv2", "egl", "gbm" }) |lib|
            mod.linkSystemLibrary(lib, .{});
    }

    if (options.@"vulkan-renderer") {
        if (!cfg.atleastVersion("vulkan", "1.2.182") or !cfg.hasHeader("vulkan/vulkan.h")) return error.MissingDependency;
        const vk_wf = b.addWriteFiles();
        const glslang_quiet = blk: {
            var code: u8 = undefined;
            _ = b.runAllowFail(&.{ "glslang", "--quiet", "--version" }, &code, .ignore) catch break :blk false;
            break :blk true;
        };
        inline for (shaders.vulkan) |shader| {
            const glslang = b.addSystemCommand(&.{"glslang"});
            glslang.addArg("-V");
            if (glslang_quiet) glslang.addArg("--quiet");
            glslang.addArgs(&.{ "--vn", comptime dotToUnderscore(shader) ++ "_data" });
            glslang.addFileArg(upstream.path("render/vulkan/shaders/" ++ shader));
            glslang.addArg("-o");
            _ = vk_wf.addCopyFile(glslang.addOutputFileArg(shader ++ ".h"), "render/vulkan/shaders/" ++ shader ++ ".h");
        }
        mod.addIncludePath(vk_wf.getDirectory());
        mod.addCSourceFiles(.{ .root = upstream.path(""), .files = srcs.vulkan, .flags = flags });
        mod.linkSystemLibrary("vulkan", .{});
    }

    if (options.xwayland) {
        if (!cfg.atleastVersion("xcb-xfixes", "1.15")) return error.MissingDependency;
        mod.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs.xwayland,
            .flags = flags,
        });
        inline for (.{ "xcb", "xcb-composite", "xcb-ewmh", "xcb-icccm", "xcb-render", "xcb-res", "xcb-xfixes" }) |lib|
            mod.linkSystemLibrary(lib, .{});
        if (options.@"xcb-errors") mod.linkSystemLibrary("xcb-errors", .{});
    }

    const lib = b.addLibrary(.{
        .name = "wlroots",
        .root_module = mod,
        .linkage = options.linkage,
        .version = version,
    });
    if (options.linkage == .dynamic) lib.version_script = upstream.path("wlroots.syms");
    lib.installHeadersDirectory(upstream.path("include/wlr"), "wlr", .{});
    lib.installHeader(config_wf.getDirectory().path(b, "wlr/version.h"), "wlr/version.h");
    lib.installConfigHeader(wlr_config_h);
    lib.installHeadersDirectory(wf.getDirectory(), "", .{ .include_extensions = &.{".h"} });
    b.installArtifact(lib);
}

fn genProtocol(b: *std.Build, wf: *std.Build.Step.WriteFile, c_files: *std.ArrayListUnmanaged([]const u8), xml: LazyPath, basename: []const u8) !void {
    inline for (.{
        .{ "private-code", "{s}-protocol.c" },
        .{ "server-header", "{s}-protocol.h" },
        .{ "client-header", "{s}-client-protocol.h" },
        .{ "enum-header", "wayland-protocols/{s}-enum.h" },
    }) |entry| {
        const mode, const fmt = entry;
        const name = b.fmt(fmt, .{basename});
        const cmd = b.addSystemCommand(&.{ "wayland-scanner", mode });
        cmd.addFileArg(xml);
        _ = wf.addCopyFile(cmd.addOutputFileArg(name), name);
        if (comptime mem.eql(u8, mode, "private-code")) try c_files.append(b.allocator, name);
    }
}

inline fn dotToUnderscore(comptime name: []const u8) [name.len]u8 {
    var buf: [name.len]u8 = undefined;
    for (name, 0..) |c, i| buf[i] = if (c == '.') '_' else c;
    return buf;
}

const simple_features: []const struct { option: []const u8, sources: []const []const u8, deps: []const []const u8, version_check: ?struct { []const u8, []const u8 } } = &.{
    .{ .option = "session", .sources = &.{"backend/session/session.c"}, .deps = &.{"libudev"}, .version_check = null },
    .{ .option = "libinput-backend", .sources = srcs.libinput, .deps = &.{"libinput"}, .version_check = .{ "libinput", "1.19.0" } },
    .{ .option = "x11-backend", .sources = srcs.x11, .deps = &.{ "xcb", "xcb-dri3", "xcb-present", "xcb-render", "xcb-renderutil", "xcb-shm", "xcb-xfixes", "xcb-xinput" }, .version_check = null },
    .{ .option = "gbm-allocator", .sources = &.{"render/allocator/gbm.c"}, .deps = &.{"gbm"}, .version_check = .{ "gbm", "21.1" } },
    .{ .option = "udmabuf-allocator", .sources = &.{"render/allocator/udmabuf.c"}, .deps = &.{}, .version_check = null },
};

const flags: []const []const u8 = &.{
    "-Wundef",                "-Wmissing-include-dirs",          "-Wold-style-definition",
    "-Wpointer-arith",        "-Winit-self",                     "-Wstrict-prototypes",
    "-Wimplicit-fallthrough", "-Wendif-labels",                  "-Wstrict-aliasing=2",
    "-Woverflow",             "-Wmissing-prototypes",            "-Walloca",
    "-Wno-missing-braces",    "-Wno-missing-field-initializers", "-Wno-unused-parameter",
    "-Werror",                "-std=c11",
};

const shaders = .{
    .gles2 = &[_][]const u8{
        "common.vert",
        "quad.frag",
        "tex_rgba.frag",
        "tex_rgbx.frag",
        "tex_external.frag",
    },
    .vulkan = &[_][]const u8{
        "common.vert",
        "texture.frag",
        "quad.frag",
        "output.frag",
    },
};

const protocols = .{
    .system = &[_][]const u8{
        "stable/linux-dmabuf/linux-dmabuf-v1.xml",                    "stable/presentation-time/presentation-time.xml",                                 "stable/tablet/tablet-v2.xml",
        "stable/viewporter/viewporter.xml",                           "stable/xdg-shell/xdg-shell.xml",                                                 "staging/alpha-modifier/alpha-modifier-v1.xml",
        "staging/color-management/color-management-v1.xml",           "staging/color-representation/color-representation-v1.xml",                       "staging/content-type/content-type-v1.xml",
        "staging/cursor-shape/cursor-shape-v1.xml",                   "staging/drm-lease/drm-lease-v1.xml",                                             "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
        "staging/ext-idle-notify/ext-idle-notify-v1.xml",             "staging/ext-image-capture-source/ext-image-capture-source-v1.xml",               "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
        "staging/ext-session-lock/ext-session-lock-v1.xml",           "staging/ext-data-control/ext-data-control-v1.xml",                               "staging/ext-workspace/ext-workspace-v1.xml",
        "staging/fractional-scale/fractional-scale-v1.xml",           "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml",                             "staging/security-context/security-context-v1.xml",
        "staging/single-pixel-buffer/single-pixel-buffer-v1.xml",     "staging/xdg-activation/xdg-activation-v1.xml",                                   "staging/xdg-dialog/xdg-dialog-v1.xml",
        "staging/xdg-system-bell/xdg-system-bell-v1.xml",             "staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml",                             "staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml",
        "staging/xwayland-shell/xwayland-shell-v1.xml",               "staging/tearing-control/tearing-control-v1.xml",                                 "staging/ext-transient-seat/ext-transient-seat-v1.xml",
        "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",         "unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml", "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
        "unstable/pointer-gestures/pointer-gestures-unstable-v1.xml", "unstable/primary-selection/primary-selection-unstable-v1.xml",                   "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
        "unstable/text-input/text-input-unstable-v3.xml",             "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",                         "unstable/xdg-foreign/xdg-foreign-unstable-v1.xml",
        "unstable/xdg-foreign/xdg-foreign-unstable-v2.xml",           "unstable/xdg-output/xdg-output-unstable-v1.xml",
    },
    .custom = &[_][]const u8{
        "protocol/drm.xml",                                         "protocol/input-method-unstable-v2.xml",
        "protocol/server-decoration.xml",                           "protocol/virtual-keyboard-unstable-v1.xml",
        "protocol/wlr-data-control-unstable-v1.xml",                "protocol/wlr-export-dmabuf-unstable-v1.xml",
        "protocol/wlr-foreign-toplevel-management-unstable-v1.xml", "protocol/wlr-gamma-control-unstable-v1.xml",
        "protocol/wlr-layer-shell-unstable-v1.xml",                 "protocol/wlr-output-management-unstable-v1.xml",
        "protocol/wlr-output-power-management-unstable-v1.xml",     "protocol/wlr-screencopy-unstable-v1.xml",
        "protocol/wlr-virtual-pointer-unstable-v1.xml",
    },
};

const srcs = .{
    .core = &[_][]const u8{
        "util/addon.c",                              "util/array.c",                              "util/box.c",                                 "util/env.c",                                 "util/global.c",
        "util/log.c",                                "util/matrix.c",                             "util/mem.c",                                 "util/rect_union.c",                          "util/region.c",
        "util/set.c",                                "util/shm.c",                                "util/time.c",                                "util/token.c",                               "util/transform.c",
        "util/utf8.c",                               "util/version.c",                            "xcursor/wlr_xcursor.c",                      "xcursor/xcursor.c",                          "render/color.c",
        "render/dmabuf.c",                           "render/drm_format_set.c",                   "render/drm_syncobj.c",                       "render/pass.c",                              "render/pixel_format.c",
        "render/swapchain.c",                        "render/wlr_renderer.c",                     "render/wlr_texture.c",                       "render/pixman/pass.c",                       "render/pixman/pixel_format.c",
        "render/pixman/renderer.c",                  "render/allocator/allocator.c",              "render/allocator/shm.c",                     "render/allocator/drm_dumb.c",                "backend/backend.c",
        "backend/multi/backend.c",                   "backend/headless/backend.c",                "backend/headless/output.c",                  "backend/wayland/backend.c",                  "backend/wayland/output.c",
        "backend/wayland/seat.c",                    "backend/wayland/pointer.c",                 "backend/wayland/tablet_v2.c",                "types/data_device/wlr_data_device.c",        "types/data_device/wlr_data_offer.c",
        "types/data_device/wlr_data_source.c",       "types/data_device/wlr_drag.c",              "types/ext_image_capture_source_v1/base.c",   "types/ext_image_capture_source_v1/output.c", "types/ext_image_capture_source_v1/foreign_toplevel.c",
        "types/ext_image_capture_source_v1/scene.c", "types/output/cursor.c",                     "types/output/output.c",                      "types/output/render.c",                      "types/output/state.c",
        "types/output/swapchain.c",                  "types/scene/drag_icon.c",                   "types/scene/subsurface_tree.c",              "types/scene/surface.c",                      "types/scene/wlr_scene.c",
        "types/scene/output_layout.c",               "types/scene/xdg_shell.c",                   "types/scene/layer_shell_v1.c",               "types/seat/wlr_seat_keyboard.c",             "types/seat/wlr_seat_pointer.c",
        "types/seat/wlr_seat_touch.c",               "types/seat/wlr_seat.c",                     "types/tablet_v2/wlr_tablet_v2_pad.c",        "types/tablet_v2/wlr_tablet_v2_tablet.c",     "types/tablet_v2/wlr_tablet_v2_tool.c",
        "types/tablet_v2/wlr_tablet_v2.c",           "types/xdg_shell/wlr_xdg_popup.c",           "types/xdg_shell/wlr_xdg_positioner.c",       "types/xdg_shell/wlr_xdg_shell.c",            "types/xdg_shell/wlr_xdg_surface.c",
        "types/xdg_shell/wlr_xdg_toplevel.c",        "types/buffer/buffer.c",                     "types/buffer/client.c",                      "types/buffer/dmabuf.c",                      "types/buffer/readonly_data.c",
        "types/buffer/resource.c",                   "types/wlr_alpha_modifier_v1.c",             "types/wlr_color_management_v1.c",            "types/wlr_color_representation_v1.c",        "types/wlr_compositor.c",
        "types/wlr_content_type_v1.c",               "types/wlr_cursor.c",                        "types/wlr_cursor_shape_v1.c",                "types/wlr_damage_ring.c",                    "types/wlr_data_control_v1.c",
        "types/wlr_drm.c",                           "types/wlr_export_dmabuf_v1.c",              "types/wlr_ext_data_control_v1.c",            "types/wlr_ext_foreign_toplevel_list_v1.c",   "types/wlr_ext_image_copy_capture_v1.c",
        "types/wlr_ext_workspace_v1.c",              "types/wlr_fixes.c",                         "types/wlr_foreign_toplevel_management_v1.c", "types/wlr_fractional_scale_v1.c",            "types/wlr_gamma_control_v1.c",
        "types/wlr_idle_inhibit_v1.c",               "types/wlr_idle_notify_v1.c",                "types/wlr_input_device.c",                   "types/wlr_input_method_v2.c",                "types/wlr_keyboard.c",
        "types/wlr_keyboard_group.c",                "types/wlr_keyboard_shortcuts_inhibit_v1.c", "types/wlr_layer_shell_v1.c",                 "types/wlr_linux_dmabuf_v1.c",                "types/wlr_linux_drm_syncobj_v1.c",
        "types/wlr_output_layer.c",                  "types/wlr_output_layout.c",                 "types/wlr_output_management_v1.c",           "types/wlr_output_power_management_v1.c",     "types/wlr_output_swapchain_manager.c",
        "types/wlr_pointer_constraints_v1.c",        "types/wlr_pointer_gestures_v1.c",           "types/wlr_pointer.c",                        "types/wlr_presentation_time.c",              "types/wlr_primary_selection_v1.c",
        "types/wlr_primary_selection.c",             "types/wlr_region.c",                        "types/wlr_relative_pointer_v1.c",            "types/wlr_screencopy_v1.c",                  "types/wlr_security_context_v1.c",
        "types/wlr_server_decoration.c",             "types/wlr_session_lock_v1.c",               "types/wlr_shm.c",                            "types/wlr_single_pixel_buffer_v1.c",         "types/wlr_subcompositor.c",
        "types/wlr_switch.c",                        "types/wlr_tablet_pad.c",                    "types/wlr_tablet_tool.c",                    "types/wlr_tearing_control_v1.c",             "types/wlr_text_input_v3.c",
        "types/wlr_touch.c",                         "types/wlr_transient_seat_v1.c",             "types/wlr_viewporter.c",                     "types/wlr_virtual_keyboard_v1.c",            "types/wlr_virtual_pointer_v1.c",
        "types/wlr_xcursor_manager.c",               "types/wlr_xdg_activation_v1.c",             "types/wlr_xdg_decoration_v1.c",              "types/wlr_xdg_dialog_v1.c",                  "types/wlr_xdg_foreign_v1.c",
        "types/wlr_xdg_foreign_v2.c",                "types/wlr_xdg_foreign_registry.c",          "types/wlr_xdg_output_v1.c",                  "types/wlr_xdg_system_bell_v1.c",             "types/wlr_xdg_toplevel_icon_v1.c",
        "types/wlr_xdg_toplevel_tag_v1.c",
    },
    .drm = &[_][]const u8{
        "backend/drm/atomic.c", "backend/drm/backend.c", "backend/drm/drm.c",        "backend/drm/fb.c",
        "backend/drm/legacy.c", "backend/drm/monitor.c", "backend/drm/properties.c", "backend/drm/renderer.c",
        "backend/drm/util.c",
    },
    .libinput = &[_][]const u8{
        "backend/libinput/backend.c",     "backend/libinput/events.c", "backend/libinput/keyboard.c",
        "backend/libinput/pointer.c",     "backend/libinput/switch.c", "backend/libinput/tablet_pad.c",
        "backend/libinput/tablet_tool.c", "backend/libinput/touch.c",
    },
    .x11 = &[_][]const u8{ "backend/x11/backend.c", "backend/x11/input_device.c", "backend/x11/output.c" },
    .gles2 = &[_][]const u8{
        "render/gles2/pass.c",     "render/gles2/pixel_format.c",
        "render/gles2/renderer.c", "render/gles2/texture.c",
    },
    .vulkan = &[_][]const u8{
        "render/vulkan/pass.c",    "render/vulkan/pixel_format.c", "render/vulkan/renderer.c",
        "render/vulkan/texture.c", "render/vulkan/util.c",         "render/vulkan/vulkan.c",
    },
    .xwayland = &[_][]const u8{
        "xwayland/selection/dnd.c",      "xwayland/selection/incoming.c",
        "xwayland/selection/outgoing.c", "xwayland/selection/selection.c",
        "xwayland/server.c",             "xwayland/shell.c",
        "xwayland/sockets.c",            "xwayland/xwayland.c",
        "xwayland/xwm.c",
    },
};
