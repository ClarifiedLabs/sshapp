#include "CLibSSH2Shim.h"
#include <dispatch/dispatch.h>
#include <libssh2.h>
#include <stdlib.h>
#include <string.h>

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

void kbd_interactive_trampoline(
    const char *name, int name_len,
    const char *instruction, int instruction_len,
    int num_prompts,
    const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
    void **abstract
) {
    (void)name; (void)name_len;
    (void)instruction; (void)instruction_len;

    KbdInteractiveContext *ctx = (KbdInteractiveContext *)(*abstract);
    if (!ctx) return;

    // Copy prompt info into the context struct for Swift to read
    ctx->num_prompts = num_prompts;

    if (num_prompts > 0) {
        ctx->prompt_texts = (char **)calloc(num_prompts, sizeof(char *));
        ctx->prompt_echos = (unsigned char *)calloc(num_prompts, sizeof(unsigned char));
        ctx->responses = (char **)calloc(num_prompts, sizeof(char *));

        // On allocation failure, don't dereference NULL. Present zero prompts
        // to Swift so the auth round completes empty (and fails cleanly)
        // instead of crashing the app under memory pressure.
        if (!ctx->prompt_texts || !ctx->prompt_echos || !ctx->responses) {
            free(ctx->prompt_texts);
            free(ctx->prompt_echos);
            free(ctx->responses);
            ctx->prompt_texts = NULL;
            ctx->prompt_echos = NULL;
            ctx->responses = NULL;
            ctx->num_prompts = 0;
            num_prompts = 0;
        }

        for (int i = 0; i < num_prompts; i++) {
            // Copy prompt text (may not be null-terminated)
            ctx->prompt_texts[i] = (char *)calloc(prompts[i].length + 1, 1);
            if (!ctx->prompt_texts[i]) {
                // Truncate this round to the prompts we could allocate.
                ctx->num_prompts = i;
                num_prompts = i;
                break;
            }
            memcpy(ctx->prompt_texts[i], prompts[i].text, prompts[i].length);
            ctx->prompt_echos[i] = prompts[i].echo;
        }
    }

    // Signal Swift that prompts are ready
    dispatch_semaphore_signal((dispatch_semaphore_t)ctx->prompts_ready);

    // Wait for Swift to fill in responses
    dispatch_semaphore_wait((dispatch_semaphore_t)ctx->responses_ready, DISPATCH_TIME_FOREVER);

    // Copy responses into libssh2's response array
    // libssh2 takes ownership and calls free() on each text pointer
    for (int i = 0; i < num_prompts; i++) {
        if (ctx->responses[i]) {
            size_t len = strlen(ctx->responses[i]);
            responses[i].text = strdup(ctx->responses[i]);
            responses[i].length = (unsigned int)len;
        } else {
            responses[i].text = strdup("");
            responses[i].length = 0;
        }
    }

    // Clean up context allocations (Swift already read them)
    for (int i = 0; i < num_prompts; i++) {
        free(ctx->prompt_texts[i]);
        free(ctx->responses[i]);
    }
    free(ctx->prompt_texts);
    free(ctx->prompt_echos);
    free(ctx->responses);
    ctx->prompt_texts = NULL;
    ctx->prompt_echos = NULL;
    ctx->responses = NULL;
    ctx->num_prompts = 0;
}
