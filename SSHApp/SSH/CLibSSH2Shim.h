#ifndef CLibSSH2Shim_h
#define CLibSSH2Shim_h

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

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

/// Swift-backed byte-stream callbacks used to carry libssh2 traffic over
/// Network.framework instead of a BSD network socket. Negative return values
/// use the usual errno convention (for example, -EAGAIN).
typedef ssize_t (*SSHAppTransportSendCallback)(
    void *io_context,
    const void *buffer,
    size_t length
);
typedef ssize_t (*SSHAppTransportReceiveCallback)(
    void *io_context,
    void *buffer,
    size_t length
);

/// Application-level RFC 4252 banner callback. Byte ranges are borrowed and
/// valid only until the callback returns.
typedef void (*SSHAppUserauthBannerCallback)(
    void *banner_context,
    const unsigned char *message,
    size_t message_length,
    const unsigned char *language,
    size_t language_length
);

/// Called exactly once when the first banner or keyboard-interactive challenge
/// starts the bounded interactive-authentication deadline.
typedef void (*SSHAppAuthenticationInteractionCallback)(
    void *interaction_context,
    uint64_t deadline_uptime_nanoseconds
);

typedef struct SSHAppSessionContext SSHAppSessionContext;

/// Current monotonic uptime in the same clock domain as DispatchTime uptime.
uint64_t sshapp_uptime_nanoseconds(void);

enum {
    SSHAPP_KBD_BRIDGE_OK = 0,
    SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED = 1,
    SSHAPP_KBD_BRIDGE_RESPONSE_COUNT_MISMATCH = 2,
    SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT = 3,
    SSHAPP_KBD_BRIDGE_INVALID_ROUND = 4
};

/// Shared context for one or more keyboard-interactive authentication rounds.
/// Lengths are authoritative; copied byte ranges are not NUL-terminated.
/// Semaphores are typed as void* so Swift can import this plain C struct.
typedef struct {
    unsigned char *name;
    size_t name_length;
    unsigned char *instruction;
    size_t instruction_length;
    int num_prompts;
    unsigned char **prompt_texts;
    size_t *prompt_lengths;
    unsigned char *prompt_echos;  // 1 = echo on, 0 = echo off
    unsigned char **responses;
    size_t *response_lengths;
    int response_count;
    int bridge_error;
    int cancelled;
    int round_active;
    uint64_t response_timeout_milliseconds;
    void *prompts_ready;     // dispatch_semaphore_t
    void *responses_ready;   // dispatch_semaphore_t
    void *state_lock;        // os_unfair_lock*
} KbdInteractiveContext;

/// Own the shared libssh2 session context. It keeps Network.framework I/O,
/// banner delivery, and the temporary keyboard-interactive context together.
SSHAppSessionContext *sshapp_session_context_create(
    void *io_context,
    SSHAppTransportSendCallback send_callback,
    SSHAppTransportReceiveCallback receive_callback,
    void *banner_context,
    SSHAppUserauthBannerCallback banner_callback,
    uint64_t authentication_wait_duration_milliseconds,
    void *interaction_context,
    SSHAppAuthenticationInteractionCallback interaction_callback
);
void sshapp_session_context_destroy(SSHAppSessionContext *context);
void sshapp_configure_session_io(
    LIBSSH2_SESSION *session,
    SSHAppSessionContext *context
);
void sshapp_session_context_set_keyboard_context(
    SSHAppSessionContext *context,
    KbdInteractiveContext *keyboard_context
);
/// Sets/clears the absolute standard deadline for the current auth operation.
void sshapp_session_context_begin_authentication_operation(
    SSHAppSessionContext *context,
    uint64_t deadline_uptime_nanoseconds
);
void sshapp_session_context_end_authentication_operation(
    SSHAppSessionContext *context
);

/// Initialize/destroy the synchronization protecting one bridge context.
int sshapp_keyboard_context_initialize(KbdInteractiveContext *context);
void sshapp_keyboard_context_destroy(KbdInteractiveContext *context);
void sshapp_keyboard_context_lock(KbdInteractiveContext *context);
void sshapp_keyboard_context_unlock(KbdInteractiveContext *context);

/// Wake both sides of a keyboard-interactive bridge and mark it cancelled.
void sshapp_keyboard_context_cancel(KbdInteractiveContext *context);

/// C callback trampoline for libssh2_userauth_keyboard_interactive().
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
