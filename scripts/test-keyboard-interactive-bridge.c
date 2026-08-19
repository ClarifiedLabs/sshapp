#include <dispatch/dispatch.h>
#include <libssh2.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "CLibSSH2Shim.h"

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "keyboard bridge test failed: %s (line %d)\n", message, __LINE__); \
        exit(1); \
    } \
} while (0)

typedef struct {
    KbdInteractiveContext keyboard;
    SSHAppSessionContext *session;
    dispatch_semaphore_t prompts_ready;
    dispatch_semaphore_t responses_ready;
    int interaction_count;
    uint64_t interaction_deadline_nanoseconds;
} TestBridge;

typedef struct {
    SSHAppSessionContext *session;
    const char *name;
    int name_length;
    const char *instruction;
    int instruction_length;
    int prompt_count;
    LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts;
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses;
} RoundCall;

static void interaction_started(void *opaque, uint64_t deadline_nanoseconds) {
    TestBridge *bridge = (TestBridge *)opaque;
    bridge->interaction_count++;
    bridge->interaction_deadline_nanoseconds = deadline_nanoseconds;
}

static void initialize_bridge(
    TestBridge *bridge,
    uint64_t response_timeout_milliseconds,
    uint64_t interaction_duration_milliseconds
) {
    memset(bridge, 0, sizeof(*bridge));
    bridge->prompts_ready = dispatch_semaphore_create(0);
    bridge->responses_ready = dispatch_semaphore_create(0);
    bridge->keyboard.prompts_ready = bridge->prompts_ready;
    bridge->keyboard.responses_ready = bridge->responses_ready;
    bridge->keyboard.response_timeout_milliseconds = response_timeout_milliseconds;
    CHECK(sshapp_keyboard_context_initialize(&bridge->keyboard) == 0,
          "context synchronization initialization");
    bridge->session = sshapp_session_context_create(
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        interaction_duration_milliseconds,
        bridge,
        interaction_started
    );
    CHECK(bridge->session != NULL, "session context allocation");
    sshapp_session_context_set_keyboard_context(bridge->session, &bridge->keyboard);
}

static void destroy_bridge(TestBridge *bridge) {
    sshapp_session_context_set_keyboard_context(bridge->session, NULL);
    sshapp_session_context_destroy(bridge->session);
    sshapp_keyboard_context_destroy(&bridge->keyboard);
}

static void *invoke_round(void *opaque) {
    RoundCall *call = (RoundCall *)opaque;
    void *abstract = call->session;
    kbd_interactive_trampoline(
        call->name,
        call->name_length,
        call->instruction,
        call->instruction_length,
        call->prompt_count,
        call->prompts,
        call->responses,
        &abstract
    );
    return NULL;
}

static void wait_for_round(TestBridge *bridge) {
    CHECK(
        dispatch_semaphore_wait(
            bridge->prompts_ready,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)
        ) == 0,
        "prompt round delivery"
    );
}

static void submit_responses(
    TestBridge *bridge,
    const char *const *responses,
    int response_count
) {
    sshapp_keyboard_context_lock(&bridge->keyboard);
    CHECK(bridge->keyboard.round_active != 0, "round remains active while submitting");
    CHECK(bridge->keyboard.num_prompts == response_count, "response count matches prompts");
    for (int index = 0; index < response_count; index++) {
        size_t length = strlen(responses[index]);
        bridge->keyboard.responses[index] = malloc(length ? length : 1);
        CHECK(bridge->keyboard.responses[index] != NULL, "response allocation");
        if (length) {
            memcpy(bridge->keyboard.responses[index], responses[index], length);
        }
        bridge->keyboard.response_lengths[index] = length;
    }
    bridge->keyboard.response_count = response_count;
    dispatch_semaphore_signal(bridge->responses_ready);
    sshapp_keyboard_context_unlock(&bridge->keyboard);
}

static double uptime_seconds(void) {
    return (double)sshapp_uptime_nanoseconds() / 1000000000.0;
}

static void test_complete_round_and_responses(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 1000, 0);

    unsigned char first_text[] = {'P', 'a', 's', 's', 0, 'w', 'o', 'r', 'd', ':', ' '};
    unsigned char second_text[] = "Code: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompts[2] = {
        {first_text, sizeof(first_text), 0},
        {second_text, sizeof(second_text) - 1, 1},
    };
    LIBSSH2_USERAUTH_KBDINT_RESPONSE output[2];
    RoundCall call = {
        bridge.session,
        "PAM",
        3,
        "Enter both factors",
        18,
        2,
        prompts,
        output,
    };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, invoke_round, &call) == 0, "round thread creation");
    wait_for_round(&bridge);

    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.round_active != 0, "round marked active");
    CHECK(bridge.keyboard.name_length == 3, "name explicit length");
    CHECK(memcmp(bridge.keyboard.name, "PAM", 3) == 0, "name bytes");
    CHECK(bridge.keyboard.instruction_length == 18, "instruction explicit length");
    CHECK(bridge.keyboard.num_prompts == 2, "all prompts copied");
    CHECK(bridge.keyboard.prompt_lengths[0] == sizeof(first_text), "embedded NUL length preserved");
    CHECK(memcmp(bridge.keyboard.prompt_texts[0], first_text, sizeof(first_text)) == 0,
          "embedded NUL prompt bytes preserved");
    CHECK(bridge.keyboard.prompt_echos[0] == 0 && bridge.keyboard.prompt_echos[1] == 1,
          "independent echo flags preserved");
    sshapp_keyboard_context_unlock(&bridge.keyboard);

    const char *responses[2] = {"secret", "123456"};
    submit_responses(&bridge, responses, 2);
    CHECK(pthread_join(thread, NULL) == 0, "round thread join");
    CHECK(output[0].length == 6 && memcmp(output[0].text, "secret", 6) == 0,
          "first explicit-length response");
    CHECK(output[1].length == 6 && memcmp(output[1].text, "123456", 6) == 0,
          "second explicit-length response");
    free(output[0].text);
    free(output[1].text);

    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.round_active == 0, "completed round deactivated");
    CHECK(bridge.keyboard.prompt_texts == NULL && bridge.keyboard.responses == NULL,
          "completed native round storage cleared");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

static void test_timeout_rejects_late_storage_access(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 20, 0);

    unsigned char text[] = "Password: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompt = {text, sizeof(text) - 1, 0};
    LIBSSH2_USERAUTH_KBDINT_RESPONSE output;
    RoundCall call = {bridge.session, "", 0, "", 0, 1, &prompt, &output};
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, invoke_round, &call) == 0, "timeout thread creation");
    wait_for_round(&bridge);
    CHECK(pthread_join(thread, NULL) == 0, "timeout thread join");

    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.bridge_error == SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT,
          "timeout bridge error");
    CHECK(bridge.keyboard.round_active == 0, "timed-out round deactivated");
    CHECK(bridge.keyboard.responses == NULL && bridge.keyboard.response_lengths == NULL,
          "timed-out response storage cleared");
    /* This is the same guard used by Swift before any response pointer access. */
    CHECK(bridge.keyboard.round_active == 0, "late response must be rejected before pointer access");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

static void test_cancellation_wakes_native_wait(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 2000, 0);

    unsigned char text[] = "Code: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompt = {text, sizeof(text) - 1, 0};
    LIBSSH2_USERAUTH_KBDINT_RESPONSE output;
    RoundCall call = {bridge.session, "", 0, "", 0, 1, &prompt, &output};
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, invoke_round, &call) == 0, "cancel thread creation");
    wait_for_round(&bridge);
    sshapp_keyboard_context_cancel(&bridge.keyboard);
    CHECK(pthread_join(thread, NULL) == 0, "cancel thread join");

    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.cancelled != 0, "cancel flag synchronized");
    CHECK(bridge.keyboard.round_active == 0, "cancelled round deactivated");
    CHECK(bridge.keyboard.responses == NULL, "cancelled round storage cleared");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

static void test_rounds_share_first_interaction_deadline(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 1000, 500);

    unsigned char text[] = "Approve: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompt = {text, sizeof(text) - 1, 1};
    LIBSSH2_USERAUTH_KBDINT_RESPONSE first_output;
    RoundCall first = {bridge.session, "First", 5, "", 0, 1, &prompt, &first_output};
    pthread_t first_thread;
    double started = uptime_seconds();
    CHECK(pthread_create(&first_thread, NULL, invoke_round, &first) == 0,
          "first deadline thread creation");
    wait_for_round(&bridge);
    usleep(350000);
    const char *approval[1] = {"yes"};
    submit_responses(&bridge, approval, 1);
    CHECK(pthread_join(first_thread, NULL) == 0, "first deadline thread join");
    free(first_output.text);

    LIBSSH2_USERAUTH_KBDINT_RESPONSE second_output;
    RoundCall second = {bridge.session, "Second", 6, "", 0, 1, &prompt, &second_output};
    pthread_t second_thread;
    CHECK(pthread_create(&second_thread, NULL, invoke_round, &second) == 0,
          "second deadline thread creation");
    wait_for_round(&bridge);
    CHECK(pthread_join(second_thread, NULL) == 0, "second deadline thread join");
    double elapsed = uptime_seconds() - started;

    CHECK(bridge.interaction_count == 1, "interaction deadline starts exactly once");
    double delivered_deadline =
        (double)bridge.interaction_deadline_nanoseconds / 1000000000.0;
    CHECK(delivered_deadline - started > 0.40 && delivered_deadline - started < 0.60,
          "absolute configured deadline delivered");
    CHECK(elapsed < 0.70, "second round uses remaining first-deadline time");
    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.bridge_error == SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT,
          "second round reaches shared deadline");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

static void test_late_challenge_cannot_start_interaction_deadline(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 1000, 500);
    sshapp_session_context_begin_authentication_operation(
        bridge.session,
        sshapp_uptime_nanoseconds() - 1
    );

    unsigned char text[] = "Too late: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompt = {text, sizeof(text) - 1, 0};
    LIBSSH2_USERAUTH_KBDINT_RESPONSE output;
    RoundCall round = {bridge.session, "Late", 4, "", 0, 1, &prompt, &output};
    pthread_t thread;
    double started = uptime_seconds();
    CHECK(pthread_create(&thread, NULL, invoke_round, &round) == 0,
          "late challenge thread creation");
    wait_for_round(&bridge);
    CHECK(pthread_join(thread, NULL) == 0, "late challenge thread join");

    CHECK(bridge.interaction_count == 0, "late challenge rejected interaction deadline");
    CHECK(uptime_seconds() - started < 0.20, "late challenge timed out immediately");
    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.bridge_error == SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT,
          "late challenge reports response timeout");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

static void test_noninteractive_round_uses_remaining_operation_deadline(void) {
    TestBridge bridge;
    initialize_bridge(&bridge, 1000, 0);
    sshapp_session_context_begin_authentication_operation(
        bridge.session,
        sshapp_uptime_nanoseconds() + 100000000ULL
    );

    unsigned char text[] = "Password: ";
    LIBSSH2_USERAUTH_KBDINT_PROMPT prompt = {text, sizeof(text) - 1, 0};
    LIBSSH2_USERAUTH_KBDINT_RESPONSE output;
    RoundCall round = {bridge.session, "Login", 5, "", 0, 1, &prompt, &output};
    pthread_t thread;
    double started = uptime_seconds();
    CHECK(pthread_create(&thread, NULL, invoke_round, &round) == 0,
          "noninteractive deadline thread creation");
    wait_for_round(&bridge);
    CHECK(pthread_join(thread, NULL) == 0,
          "noninteractive deadline thread join");
    double elapsed = uptime_seconds() - started;

    CHECK(bridge.interaction_count == 0, "noninteractive round has no long deadline");
    CHECK(elapsed > 0.05 && elapsed < 0.30,
          "noninteractive round uses operation remaining time");
    sshapp_keyboard_context_lock(&bridge.keyboard);
    CHECK(bridge.keyboard.bridge_error == SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT,
          "noninteractive round reports response timeout");
    sshapp_keyboard_context_unlock(&bridge.keyboard);
    destroy_bridge(&bridge);
}

int main(void) {
    test_complete_round_and_responses();
    test_timeout_rejects_late_storage_access();
    test_cancellation_wakes_native_wait();
    test_rounds_share_first_interaction_deadline();
    test_late_challenge_cannot_start_interaction_deadline();
    test_noninteractive_round_uses_remaining_operation_deadline();
    puts("keyboard-interactive bridge tests passed");
    return 0;
}
