#include "CLibSSH2Shim.h"
#include <dispatch/dispatch.h>
#include <errno.h>
#include <libssh2.h>
#include <limits.h>
#include <os/lock.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Compatibility declaration for SSHApp's patch against libssh2 1.11.1.
 * App compilation intentionally uses the pristine pinned public header. Keep
 * this ID synchronized with scripts/libssh2-patches/0001-*. */
#define SSHAPP_LIBSSH2_CALLBACK_USERAUTH_BANNER 10

struct SSHAppSessionContext {
    void *io_context;
    SSHAppTransportSendCallback send_callback;
    SSHAppTransportReceiveCallback receive_callback;
    void *banner_context;
    SSHAppUserauthBannerCallback banner_callback;
    uint64_t authentication_wait_duration_milliseconds;
    void *interaction_context;
    SSHAppAuthenticationInteractionCallback interaction_callback;
    _Atomic uint64_t authentication_deadline_nanoseconds;
    _Atomic uint64_t authentication_operation_deadline_nanoseconds;
    LIBSSH2_SESSION *session;
    KbdInteractiveContext *keyboard_context;
};

uint64_t sshapp_uptime_nanoseconds(void) {
    struct timespec now;
#if defined(__APPLE__)
    // DispatchTime.uptimeNanoseconds uses the Darwin uptime clock, which stops
    // while the device sleeps. CLOCK_MONOTONIC does not share that behavior.
    if (clock_gettime(CLOCK_UPTIME_RAW, &now) != 0) return 0;
#else
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
#endif
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

/// Establish one deadline shared by banners and every keyboard-interactive
/// round. The return value is in the DispatchTime-compatible uptime domain.
static uint64_t begin_authentication_interaction(SSHAppSessionContext *context) {
    if (!context || !context->authentication_wait_duration_milliseconds) return 0;

    uint64_t duration_nanoseconds =
        context->authentication_wait_duration_milliseconds * NSEC_PER_MSEC;
    uint64_t now = sshapp_uptime_nanoseconds();
    uint64_t operation_deadline = atomic_load(
        &context->authentication_operation_deadline_nanoseconds
    );
    if (operation_deadline && now >= operation_deadline) return 0;
    uint64_t proposed = UINT64_MAX - now < duration_nanoseconds
        ? UINT64_MAX
        : now + duration_nanoseconds;
    uint64_t expected = 0;
    bool began = atomic_compare_exchange_strong(
        &context->authentication_deadline_nanoseconds,
        &expected,
        proposed
    );
    uint64_t deadline = began ? proposed : expected;

    if (began && context->interaction_callback) {
        context->interaction_callback(
            context->interaction_context,
            deadline
        );
    }

    if (context->session) {
        now = sshapp_uptime_nanoseconds();
        uint64_t remaining_nanoseconds = deadline > now ? deadline - now : 0;
        uint64_t remaining_milliseconds = remaining_nanoseconds / NSEC_PER_MSEC;
        if (!remaining_milliseconds) remaining_milliseconds = 1;
        libssh2_session_set_timeout(
            context->session,
            (long)remaining_milliseconds
        );
    }
    return deadline;
}

static ssize_t sshapp_transport_send_trampoline(
    libssh2_socket_t socket,
    const void *buffer,
    size_t length,
    int flags,
    void **abstract
) {
    (void)socket;
    (void)flags;
    SSHAppSessionContext *context = abstract ? (SSHAppSessionContext *)(*abstract) : NULL;
    if (!context || !context->send_callback) return -EINVAL;
    return context->send_callback(context->io_context, buffer, length);
}

static ssize_t sshapp_transport_receive_trampoline(
    libssh2_socket_t socket,
    void *buffer,
    size_t length,
    int flags,
    void **abstract
) {
    (void)socket;
    (void)flags;
    SSHAppSessionContext *context = abstract ? (SSHAppSessionContext *)(*abstract) : NULL;
    if (!context || !context->receive_callback) return -EINVAL;
    return context->receive_callback(context->io_context, buffer, length);
}

static void sshapp_userauth_banner_trampoline(
    LIBSSH2_SESSION *session,
    const char *message,
    size_t message_length,
    const char *language,
    size_t language_length,
    void **abstract
) {
    (void)session;
    SSHAppSessionContext *context = abstract ? (SSHAppSessionContext *)(*abstract) : NULL;
    if (!context || !context->banner_callback) return;
    if ((message_length && !message) || (language_length && !language)) return;

    (void)begin_authentication_interaction(context);
    context->banner_callback(
        context->banner_context,
        (const unsigned char *)message,
        message_length,
        (const unsigned char *)language,
        language_length
    );
}

SSHAppSessionContext *sshapp_session_context_create(
    void *io_context,
    SSHAppTransportSendCallback send_callback,
    SSHAppTransportReceiveCallback receive_callback,
    void *banner_context,
    SSHAppUserauthBannerCallback banner_callback,
    uint64_t authentication_wait_duration_milliseconds,
    void *interaction_context,
    SSHAppAuthenticationInteractionCallback interaction_callback
) {
    SSHAppSessionContext *context = calloc(1, sizeof(SSHAppSessionContext));
    if (!context) return NULL;
    context->io_context = io_context;
    context->send_callback = send_callback;
    context->receive_callback = receive_callback;
    context->banner_context = banner_context;
    context->banner_callback = banner_callback;
    context->authentication_wait_duration_milliseconds =
        authentication_wait_duration_milliseconds;
    context->interaction_context = interaction_context;
    context->interaction_callback = interaction_callback;
    atomic_init(&context->authentication_deadline_nanoseconds, 0);
    atomic_init(&context->authentication_operation_deadline_nanoseconds, 0);
    return context;
}

void sshapp_session_context_destroy(SSHAppSessionContext *context) {
    free(context);
}

void sshapp_configure_session_io(
    LIBSSH2_SESSION *session,
    SSHAppSessionContext *context
) {
    if (!session || !context) return;
    context->session = session;
    void **abstract = libssh2_session_abstract(session);
    if (abstract) *abstract = context;
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_SEND,
        (libssh2_cb_generic *)sshapp_transport_send_trampoline
    );
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_RECV,
        (libssh2_cb_generic *)sshapp_transport_receive_trampoline
    );
    libssh2_session_callback_set2(
        session,
        SSHAPP_LIBSSH2_CALLBACK_USERAUTH_BANNER,
        (libssh2_cb_generic *)sshapp_userauth_banner_trampoline
    );
}

void sshapp_session_context_set_keyboard_context(
    SSHAppSessionContext *context,
    KbdInteractiveContext *keyboard_context
) {
    if (context) context->keyboard_context = keyboard_context;
}

void sshapp_session_context_begin_authentication_operation(
    SSHAppSessionContext *context,
    uint64_t deadline_uptime_nanoseconds
) {
    if (!context) return;
    atomic_store(
        &context->authentication_operation_deadline_nanoseconds,
        deadline_uptime_nanoseconds
    );
}

void sshapp_session_context_end_authentication_operation(
    SSHAppSessionContext *context
) {
    if (!context) return;
    atomic_store(&context->authentication_operation_deadline_nanoseconds, 0);
}

int sshapp_keyboard_context_initialize(KbdInteractiveContext *context) {
    if (!context || context->state_lock) return EINVAL;
    os_unfair_lock *lock = calloc(1, sizeof(os_unfair_lock));
    if (!lock) return ENOMEM;
    os_unfair_lock initialized_lock = OS_UNFAIR_LOCK_INIT;
    *lock = initialized_lock;
    context->state_lock = lock;
    return 0;
}

void sshapp_keyboard_context_lock(KbdInteractiveContext *context) {
    if (context && context->state_lock) {
        os_unfair_lock_lock((os_unfair_lock *)context->state_lock);
    }
}

void sshapp_keyboard_context_unlock(KbdInteractiveContext *context) {
    if (context && context->state_lock) {
        os_unfair_lock_unlock((os_unfair_lock *)context->state_lock);
    }
}

void sshapp_keyboard_context_cancel(KbdInteractiveContext *context) {
    if (!context) return;
    sshapp_keyboard_context_lock(context);
    context->cancelled = 1;
    void *prompts_ready = context->prompts_ready;
    void *responses_ready = context->responses_ready;
    sshapp_keyboard_context_unlock(context);
    if (prompts_ready) {
        dispatch_semaphore_signal((dispatch_semaphore_t)prompts_ready);
    }
    if (responses_ready) {
        dispatch_semaphore_signal((dispatch_semaphore_t)responses_ready);
    }
}

int sshapp_userauth_publickey(
    LIBSSH2_SESSION *session,
    const char *username,
    const unsigned char *pubkeydata,
    size_t pubkeydata_len,
    SSHAppPublicKeySignCallback sign_callback,
    void *abstract
) {
    void *callback_abstract = abstract;
    return libssh2_userauth_publickey(
        session,
        username,
        pubkeydata,
        pubkeydata_len,
        sign_callback,
        &callback_abstract
    );
}

static unsigned char *copy_bytes(const void *source, size_t length) {
    if (!length) return NULL;
    if (!source) return NULL;
    unsigned char *copy = malloc(length);
    if (copy) memcpy(copy, source, length);
    return copy;
}

static void clear_keyboard_round(KbdInteractiveContext *context) {
    if (!context) return;
    free(context->name);
    free(context->instruction);
    for (int i = 0; i < context->num_prompts; i++) {
        if (context->prompt_texts) free(context->prompt_texts[i]);
        if (context->responses) free(context->responses[i]);
    }
    free(context->prompt_texts);
    free(context->prompt_lengths);
    free(context->prompt_echos);
    free(context->responses);
    free(context->response_lengths);
    context->name = NULL;
    context->name_length = 0;
    context->instruction = NULL;
    context->instruction_length = 0;
    context->num_prompts = 0;
    context->prompt_texts = NULL;
    context->prompt_lengths = NULL;
    context->prompt_echos = NULL;
    context->responses = NULL;
    context->response_lengths = NULL;
    context->response_count = 0;
}

void sshapp_keyboard_context_destroy(KbdInteractiveContext *context) {
    if (!context || !context->state_lock) return;
    os_unfair_lock *lock = (os_unfair_lock *)context->state_lock;
    os_unfair_lock_lock(lock);
    clear_keyboard_round(context);
    context->round_active = 0;
    os_unfair_lock_unlock(lock);
    context->state_lock = NULL;
    free(lock);
}

static int copy_keyboard_round(
    KbdInteractiveContext *context,
    const char *name,
    int name_length,
    const char *instruction,
    int instruction_length,
    int num_prompts,
    const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts
) {
    if (name_length < 0 || instruction_length < 0 || num_prompts < 0 ||
        (name_length && !name) || (instruction_length && !instruction) ||
        (num_prompts && !prompts)) {
        return SSHAPP_KBD_BRIDGE_INVALID_ROUND;
    }

    context->name_length = (size_t)name_length;
    context->instruction_length = (size_t)instruction_length;
    context->num_prompts = num_prompts;
    context->name = copy_bytes(name, context->name_length);
    context->instruction = copy_bytes(instruction, context->instruction_length);
    if ((context->name_length && !context->name) ||
        (context->instruction_length && !context->instruction)) {
        return SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED;
    }
    if (!num_prompts) return SSHAPP_KBD_BRIDGE_OK;

    context->prompt_texts = calloc((size_t)num_prompts, sizeof(unsigned char *));
    context->prompt_lengths = calloc((size_t)num_prompts, sizeof(size_t));
    context->prompt_echos = calloc((size_t)num_prompts, sizeof(unsigned char));
    context->responses = calloc((size_t)num_prompts, sizeof(unsigned char *));
    context->response_lengths = calloc((size_t)num_prompts, sizeof(size_t));
    if (!context->prompt_texts || !context->prompt_lengths ||
        !context->prompt_echos || !context->responses ||
        !context->response_lengths) {
        return SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED;
    }

    for (int i = 0; i < num_prompts; i++) {
        size_t length = prompts[i].length;
        if (length && !prompts[i].text) {
            return SSHAPP_KBD_BRIDGE_INVALID_ROUND;
        }
        context->prompt_lengths[i] = length;
        context->prompt_echos[i] = prompts[i].echo;
        context->prompt_texts[i] = copy_bytes(prompts[i].text, length);
        if (length && !context->prompt_texts[i]) {
            return SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED;
        }
    }
    return SSHAPP_KBD_BRIDGE_OK;
}

void kbd_interactive_trampoline(
    const char *name, int name_len,
    const char *instruction, int instruction_len,
    int num_prompts,
    const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
    void **abstract
) {
    SSHAppSessionContext *session_context = abstract ? (SSHAppSessionContext *)(*abstract) : NULL;
    KbdInteractiveContext *context = session_context ? session_context->keyboard_context : NULL;
    if (!context || (num_prompts > 0 && !responses)) return;

    for (int i = 0; i < num_prompts; i++) {
        responses[i].text = NULL;
        responses[i].length = 0;
    }

    sshapp_keyboard_context_lock(context);
    if (context->cancelled) {
        sshapp_keyboard_context_unlock(context);
        return;
    }

    clear_keyboard_round(context);
    context->bridge_error = copy_keyboard_round(
        context,
        name,
        name_len,
        instruction,
        instruction_len,
        num_prompts,
        prompts
    );
    context->round_active = context->bridge_error == SSHAPP_KBD_BRIDGE_OK;
    int bridge_error = context->bridge_error;
    sshapp_keyboard_context_unlock(context);

    uint64_t interaction_deadline = begin_authentication_interaction(session_context);
    dispatch_semaphore_signal((dispatch_semaphore_t)context->prompts_ready);

    if (bridge_error != SSHAPP_KBD_BRIDGE_OK) {
        sshapp_keyboard_context_lock(context);
        context->round_active = 0;
        clear_keyboard_round(context);
        sshapp_keyboard_context_unlock(context);
        return;
    }

    dispatch_time_t response_deadline;
    if (interaction_deadline) {
        uint64_t now = sshapp_uptime_nanoseconds();
        uint64_t remaining = interaction_deadline > now
            ? interaction_deadline - now
            : 0;
        response_deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)remaining);
    } else {
        uint64_t operation_deadline = atomic_load(
            &session_context->authentication_operation_deadline_nanoseconds
        );
        if (operation_deadline) {
            uint64_t now = sshapp_uptime_nanoseconds();
            uint64_t remaining = operation_deadline > now
                ? operation_deadline - now
                : 0;
            response_deadline = dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)remaining
            );
        } else {
            response_deadline = dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)context->response_timeout_milliseconds * NSEC_PER_MSEC
            );
        }
    }
    bool response_timed_out = dispatch_semaphore_wait(
        (dispatch_semaphore_t)context->responses_ready,
        response_deadline
    ) != 0;

    sshapp_keyboard_context_lock(context);
    if (response_timed_out && context->bridge_error == SSHAPP_KBD_BRIDGE_OK) {
        context->bridge_error = SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT;
    }

    if (!context->cancelled &&
        context->round_active &&
        context->bridge_error == SSHAPP_KBD_BRIDGE_OK) {
        if (context->response_count != num_prompts) {
            context->bridge_error = SSHAPP_KBD_BRIDGE_RESPONSE_COUNT_MISMATCH;
        } else {
            for (int i = 0; i < num_prompts; i++) {
                size_t length = context->response_lengths[i];
                if (length > UINT_MAX || (length && !context->responses[i])) {
                    context->bridge_error = SSHAPP_KBD_BRIDGE_INVALID_ROUND;
                    break;
                }
                responses[i].text = (char *)copy_bytes(context->responses[i], length);
                if (length && !responses[i].text) {
                    context->bridge_error = SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED;
                    break;
                }
                responses[i].length = (unsigned int)length;
            }
        }
    }

    context->round_active = 0;
    clear_keyboard_round(context);
    sshapp_keyboard_context_unlock(context);
}
