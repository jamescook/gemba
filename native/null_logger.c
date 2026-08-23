/*
 * One unavoidable exception to "no C glue": struct mLogger's
 * .log field is `void (*)(struct mLogger*, int, enum mLogLevel,
 * const char*, va_list)` - va_list has no Crystal FFI representation
 * at all, on any platform, so this one function can't be written in
 * Crystal. It genuinely never touches its va_list argument (mirrors
 * gemba-core's own null_log), so the fix is this single trivial C
 * function plus a tiny installer that keeps Crystal from ever having
 * to model mLogger or va_list itself.
 */
#include <mgba/core/log.h>

static void
gemba_null_log(struct mLogger *logger, int category, enum mLogLevel level,
               const char *format, va_list args)
{
    (void)logger; (void)category; (void)level; (void)format; (void)args;
}

static struct mLogger gemba_null_logger = {
    .log = gemba_null_log,
    .filter = NULL,
};

void
gemba_install_null_logger(void)
{
    mLogSetDefaultLogger(&gemba_null_logger);
}
