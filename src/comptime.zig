//! Compile-time structural contract helpers.

pub fn requireDecl(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(@typeName(T) ++ " is missing declaration: " ++ name);
    }
}

pub fn requireFn(
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    requireDecl(T, name);

    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expected) {
        @compileError(
            @typeName(T) ++ "." ++ name ++ " has type " ++ @typeName(Actual) ++
                ", expected " ++ @typeName(Expected),
        );
    }
}
