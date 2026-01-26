#ifndef CLibSSH2Shim_h
#define CLibSSH2Shim_h

#include <stddef.h>

/// Forward-declare the libssh2 types we need (avoids requiring libssh2.h in bridging header)
typedef struct _LIBSSH2_SESSION LIBSSH2_SESSION;
typedef struct _LIBSSH2_USERAUTH_KBDINT_PROMPT LIBSSH2_USERAUTH_KBDINT_PROMPT;
typedef struct _LIBSSH2_USERAUTH_KBDINT_RESPONSE LIBSSH2_USERAUTH_KBDINT_RESPONSE;

typedef int (*SSHAppPublicKeySignCallback)(
    LIBSSH2_SESSION *session,
    unsigned char **sig,
    size_t *sig_len,
    const unsigned char *data,
    size_t data_len,
    void **abstract
);

/// Shared context for keyboard-interactive authentication.
/// Passed via the libssh2 session abstract pointer.
/// Semaphores are typed as void* to avoid dispatch_semaphore_t (ObjC object type)
/// which prevents Swift from importing this struct.
typedef struct {
    int num_prompts;
    char **prompt_texts;
    unsigned char *prompt_echos;  // 1 = echo on, 0 = echo off
    char **responses;
    void *prompts_ready;     // dispatch_semaphore_t — signaled when prompts are available
    void *responses_ready;   // dispatch_semaphore_t — signaled when Swift fills responses
} KbdInteractiveContext;

/// C callback trampoline for libssh2_userauth_keyboard_interactive().
/// This function is passed as the response_callback parameter.
void kbd_interactive_trampoline(
    const char *name, int name_len,
    const char *instruction, int instruction_len,
    int num_prompts,
    const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
    void **abstract
);

/// Wrapper around libssh2_userauth_publickey() that lets Swift pass an opaque
/// context pointer directly while libssh2 still receives the void** it expects.
int sshapp_userauth_publickey(
    LIBSSH2_SESSION *session,
    const char *username,
    const unsigned char *pubkeydata,
    size_t pubkeydata_len,
    SSHAppPublicKeySignCallback sign_callback,
    void *abstract
);

#endif /* CLibSSH2Shim_h */
