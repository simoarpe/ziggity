//! In-app git credentials: the two-step username/password prompt shown when an
//! HTTPS network op fails to authenticate, the secrets' lifecycle (stored,
//! wiped), and building the askpass-wired environment a credential-bearing op
//! runs with. Free functions over `*App`; the credential state lives on App.
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");

const App = app_mod.App;
const AsyncOp = app_mod.AsyncOp;

pub fn gitCredentialsSet(app: *const App) bool {
    return app.git_username != null and app.git_password != null and app.exe_path != null;
}

/// Forget (and wipe) any stored credentials. Called on logout-style resets and
/// at shutdown so secrets do not linger in freed memory.
pub fn clearGitCredentials(app: *App) void {
    if (app.git_username) |u| {
        @memset(u, 0);
        app.allocator.free(u);
        app.git_username = null;
    }
    if (app.git_password) |p| {
        @memset(p, 0);
        app.allocator.free(p);
        app.git_password = null;
    }
}

/// Whether a failed network op's output indicates an authentication problem
/// (rather than e.g. a diverged remote or a network error), so the credential
/// prompt should open. Matches git's English messages.
pub fn isAuthFailure(output: []const u8) bool {
    const needles = [_][]const u8{
        "could not read Username",
        "could not read Password",
        "Authentication failed",
        "terminal prompts disabled",
        "Invalid username or password",
        "Permission denied (publickey",
        "fatal: Authentication",
    };
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(output, n) != null) return true;
    }
    return false;
}

/// A short, actionable suffix for the failure summary when the host rejected a
/// password because it requires a token — by far the most common HTTPS auth
/// failure (GitHub, GitLab, etc. dropped password auth). Empty for other causes.
pub fn tokenHintSuffix(output: []const u8) []const u8 {
    const token_needles = [_][]const u8{
        "Password authentication is not supported",
        "Support for password authentication was removed",
        "Invalid username or token",
        "token", // e.g. "you must use a personal access token"
    };
    for (token_needles) |n| {
        if (std.ascii.indexOfIgnoreCase(output, n) != null)
            return " — use a personal access token, not a password";
    }
    return "";
}

/// Open the two-step credential prompt (username, then masked password) and
/// remember `op` so it can be re-run once both fields are entered.
pub fn startCredentialPrompt(app: *App, op: AsyncOp) !void {
    app.credential_retry_op = op;
    app.credential_step = .username;
    app.credential_user.clearRetainingCapacity();
    app.input_buffer.clearRetainingCapacity();
    app.prompt_cursor = 0;
    app.prompt_scroll = 0;
    app.mode = .credential_prompt;
    try app.setMessage("authentication required", .{});
}

pub fn handleCredentialPromptKey(app: *App, key: vaxis.Key) !void {
    // While pasting (e.g. a token with a trailing newline), esc/enter are pasted
    // content, not cancel/advance; the single-line field drops pasted newlines.
    if (app.pasting) {
        if (app.isEnterKey(key) or app.isEscapeKey(key)) return;
        _ = try app.editLine(&app.input_buffer, &app.prompt_cursor, key);
        return;
    }
    if (app.isEscapeKey(key)) {
        cancelCredentialPrompt(app);
        return;
    }
    if (app.isEnterKey(key)) {
        try advanceCredentialPrompt(app);
        return;
    }
    _ = try app.editLine(&app.input_buffer, &app.prompt_cursor, key);
}

/// Title shown on the credential popup, by step.
pub fn credentialTitle(app: *const App) []const u8 {
    return switch (app.credential_step) {
        .username => "Username",
        .password => "Password / token",
    };
}

/// Whether the current credential field should be rendered masked.
pub fn credentialMask(app: *const App) bool {
    return app.credential_step == .password;
}

pub fn cancelCredentialPrompt(app: *App) void {
    app.mode = .normal;
    app.credential_retry_op = null;
    // Wipe both the in-progress username and the active field.
    @memset(app.credential_user.items, 0);
    app.credential_user.clearRetainingCapacity();
    @memset(app.input_buffer.items, 0);
    app.input_buffer.clearRetainingCapacity();
    app.setMessage("authentication cancelled", .{}) catch {};
}

/// Advance the credential prompt: stash the username and move to the password
/// field, or store both and re-run the pending op.
pub fn advanceCredentialPrompt(app: *App) !void {
    switch (app.credential_step) {
        .username => {
            app.credential_user.clearRetainingCapacity();
            try app.credential_user.appendSlice(app.allocator, std.mem.trim(u8, app.input_buffer.items, " \t\r\n"));
            @memset(app.input_buffer.items, 0);
            app.input_buffer.clearRetainingCapacity();
            app.prompt_cursor = 0;
            app.prompt_scroll = 0;
            app.credential_step = .password;
        },
        .password => {
            clearGitCredentials(app);
            app.git_username = try app.allocator.dupe(u8, app.credential_user.items);
            app.git_password = try app.allocator.dupe(u8, app.input_buffer.items);
            // Wipe the working buffers now the values are stored.
            @memset(app.credential_user.items, 0);
            app.credential_user.clearRetainingCapacity();
            @memset(app.input_buffer.items, 0);
            app.input_buffer.clearRetainingCapacity();
            app.mode = .normal;
            if (app.credential_retry_op) |op| {
                app.credential_retry_op = null;
                try app.requestAsync(op);
            }
        },
    }
}

/// Clone the shared environment and add the askpass wiring + secrets for a
/// credential-bearing network op. The clone is owned by `gpa` (the async page
/// allocator) and freed by the worker; the shared environment is left untouched,
/// so concurrent git threads never see a mutated map.
pub fn buildCredentialEnv(app: *const App, gpa: std.mem.Allocator) !std.process.Environ.Map {
    var env = try app.git.environ.clone(gpa);
    errdefer env.deinit();
    try env.put(app_mod.askpass_env_marker, "1");
    try env.put("GIT_ASKPASS", app.exe_path.?);
    try env.put("SSH_ASKPASS", app.exe_path.?);
    try env.put("SSH_ASKPASS_REQUIRE", "force");
    try env.put(app_mod.askpass_env_user, app.git_username.?);
    try env.put(app_mod.askpass_env_pass, app.git_password.?);
    // Make the credentials the user just entered authoritative: clear any
    // configured credential helper for this one invocation. git consults a
    // helper (e.g. macOS osxkeychain) BEFORE our askpass, so a stale cached
    // entry would otherwise shadow the entered token and keep failing no matter
    // what is typed — the classic "it keeps asking" loop. An empty
    // `credential.helper` resets the helper list; injected via GIT_CONFIG_* so
    // it affects only this process and never touches the user's real git config.
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "credential.helper");
    try env.put("GIT_CONFIG_VALUE_0", "");
    return env;
}
