#include <CoreAudio/CoreAudio.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>

// MPVKit 0.41's CoreAudio backend registers hotplug_cb with a raw `struct ao *`
// context. CoreAudio may already have a notification queued when mpv removes
// that listener and frees the AO. The late callback then enters mp_msg_va with
// the freed AO/log pointer.
//
// Vendor/MPVCoreAudioPatched.o is the original MPVKit CoreAudio object with
// only these two imports renamed to the functions below. This avoids fragile
// process-wide DYLD interposition and guarantees that only libmpv's CoreAudio
// listener registrations pass through this lifetime guard.

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

static bool same_address(const AudioObjectPropertyAddress *lhs,
                         const AudioObjectPropertyAddress *rhs)
{
    return lhs->mSelector == rhs->mSelector &&
           lhs->mScope == rhs->mScope &&
           lhs->mElement == rhs->mElement;
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

OSStatus BiliAudioGuardAddPropListenerX(
    AudioObjectID object,
    const AudioObjectPropertyAddress *address,
    AudioObjectPropertyListenerProc callback,
    void *context)
{
    if (!address || !callback)
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

    OSStatus result = AudioObjectAddPropertyListener(
        object, address, guarded_listener, guard);
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
    return noErr;
}

OSStatus BiliAudioGuardRemovePropListenerX(
    AudioObjectID object,
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

    if (!guard) {
        return AudioObjectRemovePropertyListener(
            object, address, callback, context);
    }

    pthread_mutex_lock(&guard->lock);
    guard->removing = true;
    pthread_mutex_unlock(&guard->lock);

    OSStatus result = AudioObjectRemovePropertyListener(
        object, address, guarded_listener, guard);

    // mpv can free its AO as soon as this function returns. Wait for callbacks
    // that entered before `removing` was set. Keep the small retired guard
    // allocated because CoreAudio can still invoke an already-queued callback;
    // that callback will now see `removing` without dereferencing mpv's AO.
    pthread_mutex_lock(&guard->lock);
    while (guard->active_callbacks != 0)
        pthread_cond_wait(&guard->idle, &guard->lock);
    pthread_mutex_unlock(&guard->lock);
    return result;
}
