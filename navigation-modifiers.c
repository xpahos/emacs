/* Read the Command modifier for hover feedback in NS Emacs. */
#include <CoreGraphics/CoreGraphics.h>
#include <emacs-module.h>

int plugin_is_GPL_compatible;

static emacs_value command_held(emacs_env *env, ptrdiff_t nargs,
                                emacs_value *args, void *data)
{
    (void)nargs;
    (void)args;
    (void)data;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return env->intern(env, (flags & kCGEventFlagMaskCommand) ? "t" : "nil");
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    if (runtime->size < (ptrdiff_t)sizeof(*runtime))
        return 1;
    emacs_env *env = runtime->get_environment(runtime);
    if (env->size < (ptrdiff_t)sizeof(*env))
        return 1;
    emacs_value args[] = {
        env->intern(env, "my-navigation-command-held-p"),
        env->make_function(env, 0, 0, command_held,
                           "Return non-nil while the macOS Command key is held.", NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, args);
    return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1;
}
