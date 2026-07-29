#include <CoreAudio/CoreAudio.h>

// MPVKit 0.41 registers hotplug_cb with a raw `struct ao *` context. The AO's
// audio unit/log can already be torn down while CoreAudio still considers the
// listener active, so even a callback that starts before listener removal can
// enter hotplug_cb/mp_msg_va with invalid state.
//
// Vendor/MPVCoreAudioPatched.o redirects only ao_coreaudio.c's listener calls
// to these functions. Do not register the unsafe callback at all. The app owns
// display-wake/audio recovery and asks the live mpv client to reselect its
// output device from the main actor instead of letting a HAL worker retain an
// unowned internal mpv pointer.

OSStatus BiliAudioGuardAddPropListenerX(
    AudioObjectID object,
    const AudioObjectPropertyAddress *address,
    AudioObjectPropertyListenerProc callback,
    void *context)
{
    (void)object;
    (void)address;
    (void)callback;
    (void)context;
    return noErr;
}

OSStatus BiliAudioGuardRemovePropListenerX(
    AudioObjectID object,
    const AudioObjectPropertyAddress *address,
    AudioObjectPropertyListenerProc callback,
    void *context)
{
    (void)object;
    (void)address;
    (void)callback;
    (void)context;
    return noErr;
}
