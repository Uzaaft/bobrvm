//! Typed construction for internal callback/userdata pairs.

pub fn Binding0(comptime Return: type) type {
    return struct {
        function: *const fn (?*anyopaque) Return,
        userdata: ?*anyopaque,

        pub fn initRaw(
            function: *const fn (?*anyopaque) Return,
            userdata: ?*anyopaque,
        ) @This() {
            return .{ .function = function, .userdata = userdata };
        }

        pub fn call(self: @This()) Return {
            return self.function(self.userdata);
        }
    };
}

pub fn Binding1(comptime Arg: type, comptime Return: type) type {
    return struct {
        function: *const fn (Arg, ?*anyopaque) Return,
        userdata: ?*anyopaque,

        pub fn initRaw(
            function: *const fn (Arg, ?*anyopaque) Return,
            userdata: ?*anyopaque,
        ) @This() {
            return .{ .function = function, .userdata = userdata };
        }

        pub fn call(self: @This(), arg: Arg) Return {
            return self.function(arg, self.userdata);
        }
    };
}

pub fn Binding2(comptime Arg0: type, comptime Arg1: type, comptime Return: type) type {
    return struct {
        function: *const fn (Arg0, Arg1, ?*anyopaque) Return,
        userdata: ?*anyopaque,

        pub fn initRaw(
            function: *const fn (Arg0, Arg1, ?*anyopaque) Return,
            userdata: ?*anyopaque,
        ) @This() {
            return .{ .function = function, .userdata = userdata };
        }

        pub fn call(self: @This(), arg0: Arg0, arg1: Arg1) Return {
            return self.function(arg0, arg1, self.userdata);
        }
    };
}

pub fn Handler0(
    comptime Context: type,
    comptime Return: type,
    comptime handler: fn (*Context) Return,
) type {
    return struct {
        fn erased(userdata: ?*anyopaque) Return {
            const context: *Context = @ptrCast(@alignCast(userdata orelse unreachable));
            return handler(context);
        }

        pub fn bind(context: *Context) Binding0(Return) {
            return .{ .function = erased, .userdata = context };
        }
    };
}

pub fn Handler1(
    comptime Context: type,
    comptime Arg: type,
    comptime Return: type,
    comptime handler: fn (*Context, Arg) Return,
) type {
    return struct {
        fn erased(arg: Arg, userdata: ?*anyopaque) Return {
            const context: *Context = @ptrCast(@alignCast(userdata orelse unreachable));
            return handler(context, arg);
        }

        pub fn bind(context: *Context) Binding1(Arg, Return) {
            return .{ .function = erased, .userdata = context };
        }
    };
}

pub fn Handler2(
    comptime Context: type,
    comptime Arg0: type,
    comptime Arg1: type,
    comptime Return: type,
    comptime handler: fn (*Context, Arg0, Arg1) Return,
) type {
    return struct {
        fn erased(arg0: Arg0, arg1: Arg1, userdata: ?*anyopaque) Return {
            const context: *Context = @ptrCast(@alignCast(userdata orelse unreachable));
            return handler(context, arg0, arg1);
        }

        pub fn bind(context: *Context) Binding2(Arg0, Arg1, Return) {
            return .{ .function = erased, .userdata = context };
        }
    };
}

test "typed handler binds its context to the erased function" {
    const testing = @import("std").testing;
    const Context = struct {
        total: u32 = 0,

        fn add(self: *@This(), amount: u32) void {
            self.total += amount;
        }
    };

    var context = Context{};
    const binding = Handler1(Context, u32, void, Context.add).bind(&context);
    binding.call(7);

    try testing.expectEqual(@as(u32, 7), context.total);
}
