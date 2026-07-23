# MPV CoreAudio lifetime patch

`MPVCoreAudioPatched.o` is the universal macOS
`audio_out_ao_coreaudio.c.o` object from MPVKit 0.41.0
(revision `613c0ccc3acf70e136aaff880a9b5fe8fdfaf5b8`).

Only two undefined symbol names differ from the upstream object:

- `_AudioObjectAddPropertyListener` → `_BiliAudioGuardAddPropListenerX`
- `_AudioObjectRemovePropertyListener` → `_BiliAudioGuardRemovePropListenerX`

The replacement names have exactly the same byte lengths as the originals.
Their implementations live in `MPVCoreAudioListenerGuard.c`.

The object is linked before the static `Libmpv.framework`, so its private
`audio_out_coreaudio` definition satisfies mpv's driver table and prevents the
unpatched CoreAudio object from being extracted from the archive.

When MPVKit is upgraded, regenerate this object from the matching
`Libmpv.xcframework`; never reuse it with a different MPVKit version.
