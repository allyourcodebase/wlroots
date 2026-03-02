# wlroots zig

[wlroots](https://gitlab.freedesktop.org/wlroots/wlroots), packaged for the Zig build system.

## Using

First, update your `build.zig.zon`:

```
zig fetch --save git+https://github.com/allyourcodebase/wlroots.git
```

Then in your `build.zig`:

```zig
const dep = b.dependency("wlroots", .{ .target = target, .optimize = optimize });
exe.linkLibrary(dep.artifact("wlroots-0.18"));
```
