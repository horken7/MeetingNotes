// JNI bridge to whisper.cpp: load a model, transcribe a block of 16 kHz mono samples, cancel.
#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include "whisper.h"

#define TAG "MeetingNotesWhisper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

namespace {

struct Handle {
    whisper_context *ctx = nullptr;
    std::atomic<bool> cancel{false};
};

struct Progress {
    JNIEnv *env;
    jobject listener;
    jmethodID onProgress;
    std::thread::id thread;
};

void log_cb(ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) __android_log_print(ANDROID_LOG_WARN, TAG, "%s", text);
}

jbyteArray bytes(JNIEnv *env, const char *s) {
    // Return raw bytes: whisper can emit broken UTF-8, which NewStringUTF would abort on.
    const jsize n = s ? (jsize) strlen(s) : 0;
    jbyteArray out = env->NewByteArray(n);
    if (n > 0) env->SetByteArrayRegion(out, 0, n, reinterpret_cast<const jbyte *>(s));
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeInit(JNIEnv *env, jobject, jstring jpath) {
    whisper_log_set(log_cb, nullptr);
    const char *path = env->GetStringUTFChars(jpath, nullptr);
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;
    cp.flash_attn = true;
    whisper_context *ctx = whisper_init_from_file_with_params(path, cp);
    env->ReleaseStringUTFChars(jpath, path);
    if (!ctx) return 0;
    auto *h = new Handle();
    h->ctx = ctx;
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT void JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeFree(JNIEnv *, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return;
    whisper_free(h->ctx);
    delete h;
}

JNIEXPORT void JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeCancel(JNIEnv *, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (h) h->cancel = true;
}

// Returns an array of WhisperSegment, or null when whisper failed or was cancelled.
JNIEXPORT jobjectArray JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeTranscribe(
        JNIEnv *env, jobject, jlong handle, jfloatArray jsamples, jstring jlang, jint threads,
        jstring jvad, jstring jprompt, jobject listener) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return nullptr;
    h->cancel = false;

    const char *lang = env->GetStringUTFChars(jlang, nullptr);
    const char *vad = jvad ? env->GetStringUTFChars(jvad, nullptr) : nullptr;
    const char *prompt = jprompt ? env->GetStringUTFChars(jprompt, nullptr) : nullptr;
    const jsize n = env->GetArrayLength(jsamples);
    jfloat *samples = env->GetFloatArrayElements(jsamples, nullptr);

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = threads;
    p.language = lang;
    p.translate = false;
    p.no_context = false;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_special = false;
    p.print_timestamps = false;
    p.suppress_nst = true;
    p.initial_prompt = prompt;
    if (vad) {
        p.vad = true;
        p.vad_model_path = vad;
    }

    jclass lc = env->GetObjectClass(listener);
    Progress prog{env, listener, env->GetMethodID(lc, "onProgress", "(I)V"), std::this_thread::get_id()};
    p.progress_callback = [](whisper_context *, whisper_state *, int pct, void *ud) {
        auto *pr = static_cast<Progress *>(ud);
        if (std::this_thread::get_id() == pr->thread) pr->env->CallVoidMethod(pr->listener, pr->onProgress, pct);
    };
    p.progress_callback_user_data = &prog;
    p.abort_callback = [](void *ud) { return static_cast<Handle *>(ud)->cancel.load(); };
    p.abort_callback_user_data = h;

    const int rc = whisper_full(h->ctx, p, samples, n);

    env->ReleaseFloatArrayElements(jsamples, samples, JNI_ABORT);
    env->ReleaseStringUTFChars(jlang, lang);
    if (vad) env->ReleaseStringUTFChars(jvad, vad);
    if (prompt) env->ReleaseStringUTFChars(jprompt, prompt);

    if (rc != 0 || h->cancel) {
        LOGI("whisper_full returned %d (cancelled: %d)", rc, (int) h->cancel.load());
        return nullptr;
    }

    jclass sc = env->FindClass("com/horken7/meetingnotes/whisper/WhisperSegment");
    jmethodID ctor = env->GetMethodID(sc, "<init>", "(JJ[B)V");
    const int count = whisper_full_n_segments(h->ctx);
    jobjectArray out = env->NewObjectArray(count, sc, nullptr);
    for (int i = 0; i < count; i++) {
        // t0/t1 are in centiseconds.
        const jlong t0 = whisper_full_get_segment_t0(h->ctx, i) * 10;
        const jlong t1 = whisper_full_get_segment_t1(h->ctx, i) * 10;
        jbyteArray text = bytes(env, whisper_full_get_segment_text(h->ctx, i));
        jobject seg = env->NewObject(sc, ctor, t0, t1, text);
        env->SetObjectArrayElement(out, i, seg);
        env->DeleteLocalRef(seg);
        env->DeleteLocalRef(text);
    }
    return out;
}

// The language whisper used for the last transcription ("sv", "da", "en", ...).
JNIEXPORT jstring JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeLanguage(JNIEnv *env, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return nullptr;
    const int id = whisper_full_lang_id(h->ctx);
    const char *s = id >= 0 ? whisper_lang_str(id) : nullptr;
    return s ? env->NewStringUTF(s) : nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_horken7_meetingnotes_whisper_WhisperLib_nativeSystemInfo(JNIEnv *env, jobject) {
    return env->NewStringUTF(whisper_print_system_info());
}

}  // extern "C"
