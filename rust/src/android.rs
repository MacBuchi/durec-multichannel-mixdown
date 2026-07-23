//! Android-only ndk_context handshake.
//!
//! cpal's AAudio backend (0.17+) talks to `android.media.AudioManager` over
//! JNI and gets its JavaVM/Context from the `ndk_context` global. That global
//! is normally set by ndk-glue/android-activity before `main` — infrastructure
//! a Flutter app does not have: Dart `dlopen`s this library, `JNI_OnLoad`
//! never fires, and the first play tap dies in
//! `ndk_context::android_context()` (issue #88, shipped broken in
//! v0.12.10–v0.12.12).
//!
//! So MainActivity hands us the pointers explicitly: `System.loadLibrary`
//! in its companion object exports this symbol to the JVM, `onCreate` calls
//! it with the **application** context (activity contexts die on rotation).
//! Raw `jni-sys` instead of the `jni` crate on purpose — two vtable calls do
//! not justify tracking a second, fast-moving JNI API here.

use jni_sys::{jobject, JNIEnv};

/// Called from MainActivity.onCreate. Idempotent: activities are recreated
/// on rotation/theme change, but `ndk_context::initialize_android_context`
/// asserts on double-init, so only the first call does anything.
///
/// # Safety
/// `env` and `context` are live JNI pointers for the duration of the call —
/// guaranteed by the JVM for a `native` method invocation.
#[no_mangle]
pub unsafe extern "system" fn Java_de_macbuchi_durecmix_MainActivity_initNdkContext(
    env: *mut JNIEnv,
    _class: jobject,
    context: jobject,
) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // jni-sys 0.4 groups the vtable by the JNI version that introduced
        // each entry — hence the `.v1_1` hop (same access pattern the `jni`
        // crate's own call macros generate).
        let mut vm = std::ptr::null_mut();
        if ((**env).v1_1.GetJavaVM)(env, &mut vm) != jni_sys::JNI_OK {
            // Leave the global unset: cpal's playback error path then reports
            // a build failure instead of us aborting mid-JNI.
            return;
        }
        // The context jobject is a local ref that dies when onCreate returns;
        // ndk_context stores the raw pointer for the process lifetime, so it
        // must be promoted to a (deliberately never released) global ref.
        let global = ((**env).v1_1.NewGlobalRef)(env, context);
        if global.is_null() {
            return;
        }
        ndk_context::initialize_android_context(vm.cast(), global.cast());
    });
}
