#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// mpv 0.41's coreaudio AO unregisters its device listener immediately before
// freeing `struct ao`. CoreAudio can still have a callback already queued on a
// HAL notification queue, producing a use-after-free in hotplug_cb/mp_msg_va.
//
// Interpose only listeners whose callback is part of this app image (the
// statically linked libmpv). System/framework listeners are passed through.
// A retired guard is intentionally kept for the process lifetime: a very late
// CoreAudio callback can safely see `removing` without touching mpv's old ctx.

typedef struct MPVAudioListenerGuard {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    AudioObjectPropertyListenerProc callback;
    void *context;
    pthread_mutex_t lock;
    pthread_cond_t idle;
    unsigned active_callbacks;
    bool removing;
    struct MPVAudioListenerGuard *next;
} MPVAudioListenerGuard;

static pthread_mutex_t guards_lock = PTHREAD_MUTEX_INITIALIZER;
static MPVAudioListenerGuard *active_guards;
static _Thread_local bool resolving_callback_image;

static bool same_address(const AudioObjectPropertyAddress *lhs,
                         const AudioObjectPropertyAddress *rhs)
{
    return lhs->mSelector == rhs->mSelector &&
           lhs->mScope == rhs->mScope &&
           lhs->mElement == rhs->mElement;
}

static bool callback_belongs_to_app(AudioObjectPropertyListenerProc callback)
{
    // dladdr() can lazily initialise dyld/CoreFoundation state. That
    // initialisation may itself register a CoreAudio property listener and
    // therefore re-enter safe_add_listener(). Never run dladdr recursively:
    // the nested framework listener is unrelated to mpv and must pass through.
    if (!callback || resolving_callback_image)
        return false;

    resolving_callback_image = true;
    Dl_info info = {0};
    bool belongs = dladdr((const void *)callback, &info) != 0 &&
                   info.dli_fname != NULL &&
                   (strstr(info.dli_fname, "/bilibili.app/") != NULL ||
                    strstr(info.dli_fname, "bilibili.debug.dylib") != NULL);
    resolving_callback_image = false;
    return belongs;
}

static OSStatus guarded_listener(AudioObjectID object,
                                 UInt32 count,
                                 const AudioObjectPropertyAddress addresses[],
                                 void *context)
{
    MPVAudioListenerGuard *guard = context;
    pthread_mutex_lock(&guard->lock);
    if (guard->removing) {
        pthread_mutex_unlock(&guard->lock);
        return noErr;
    }
    guard->active_callbacks++;
    pthread_mutex_unlock(&guard->lock);

    OSStatus result = guard->callback(object, count, addresses, guard->context);

    pthread_mutex_lock(&guard->lock);
    guard->active_callbacks--;
    if (guard->active_callbacks == 0)
        pthread_cond_broadcast(&guard->idle);
    pthread_mutex_unlock(&guard->lock);
    return result;
}

static OSStatus safe_add_listener(AudioObjectID object,
                                  const AudioObjectPropertyAddress *address,
                                  AudioObjectPropertyListenerProc callback,
                                  void *context)
{
    if (!callback_belongs_to_app(callback))
        return AudioObjectAddPropertyListener(object, address, callback, context);

    MPVAudioListenerGuard *guard = calloc(1, sizeof(*guard));
    if (!guard)
        return AudioObjectAddPropertyListener(object, address, callback, context);
    guard->object = object;
    guard->address = *address;
    guard->callback = callback;
    guard->context = context;
    pthread_mutex_init(&guard->lock, NULL);
    pthread_cond_init(&guard->idle, NULL);

    OSStatus result = AudioObjectAddPropertyListener(object, address,
                                                     guarded_listener, guard);
    if (result != noErr) {
        pthread_cond_destroy(&guard->idle);
        pthread_mutex_destroy(&guard->lock);
        free(guard);
        return result;
    }

    pthread_mutex_lock(&guards_lock);
    guard->next = active_guards;
    active_guards = guard;
    pthread_mutex_unlock(&guards_lock);
    return result;
}

static OSStatus safe_remove_listener(AudioObjectID object,
                                     const AudioObjectPropertyAddress *address,
                                     AudioObjectPropertyListenerProc callback,
                                     void *context)
{
    pthread_mutex_lock(&guards_lock);
    MPVAudioListenerGuard **slot = &active_guards;
    MPVAudioListenerGuard *guard = NULL;
    while (*slot) {
        MPVAudioListenerGuard *candidate = *slot;
        if (candidate->object == object &&
            candidate->callback == callback &&
            candidate->context == context &&
            same_address(&candidate->address, address)) {
            guard = candidate;
            *slot = candidate->next;
            break;
        }
        slot = &candidate->next;
    }
    pthread_mutex_unlock(&guards_lock);

    if (!guard)
        return AudioObjectRemovePropertyListener(object, address,
                                                 callback, context);

    pthread_mutex_lock(&guard->lock);
    guard->removing = true;
    pthread_mutex_unlock(&guard->lock);

    OSStatus result = AudioObjectRemovePropertyListener(object, address,
                                                        guarded_listener, guard);

    // mpv may free its callback context as soon as this function returns.
    // Wait for callbacks which entered before `removing` was set. Do not free
    // the guard itself, so callbacks already queued inside CoreAudio remain safe.
    pthread_mutex_lock(&guard->lock);
    while (guard->active_callbacks != 0)
        pthread_cond_wait(&guard->idle, &guard->lock);
    pthread_mutex_unlock(&guard->lock);
    return result;
}

#define DYLD_INTERPOSE(replacementFunction, replacedFunction)                      \
    __attribute__((used)) static struct {                                           \
        const void *replacementPointer;                                             \
        const void *replacedPointer;                                                \
    } _interpose_##replacedFunction __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&replacementFunction,                          \
        (const void *)(unsigned long)&replacedFunction                              \
    }

DYLD_INTERPOSE(safe_add_listener, AudioObjectAddPropertyListener);
DYLD_INTERPOSE(safe_remove_listener, AudioObjectRemovePropertyListener);
