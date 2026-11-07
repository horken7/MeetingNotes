// JNI bridge to llama.cpp: load a GGUF chat model, count tokens, generate one reply to a system + user message.
#include <jni.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "llama.h"

#define TAG "MeetingNotesLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

namespace {

struct Handle {
    FILE *file = nullptr;   // llama.cpp reads the model through it and doesn't close it
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    std::atomic<bool> cancel{false};
};

void log_cb(ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) __android_log_print(ANDROID_LOG_WARN, TAG, "%s", text);
}

std::string jstr(JNIEnv *env, jstring s) {
    if (!s) return {};
    const char *c = env->GetStringUTFChars(s, nullptr);
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &text, bool special) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, special, true);
    std::vector<llama_token> tokens(n > 0 ? n : 0);
    if (n > 0) llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, special, true);
    return tokens;
}

std::string chat_prompt(const llama_model *model, const std::string &system, const std::string &user) {
    const char *tmpl = llama_model_chat_template(model, nullptr);
    llama_chat_message msgs[2] = {{"system", system.c_str()}, {"user", user.c_str()}};
    std::vector<char> buf(2 * (system.size() + user.size()) + 1024);
    int n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t) buf.size());
    if (n > (int) buf.size()) {
        buf.resize(n + 1);
        n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t) buf.size());
    }
    if (n < 0) {
        // Unknown template: Gemma's format (it has no system role, so the instructions lead the user turn).
        return "<start_of_turn>user\n" + system + "\n\n" + user + "<end_of_turn>\n<start_of_turn>model\n";
    }
    return std::string(buf.data(), n);
}

// Holds back an incomplete UTF-8 sequence at the end, so the progress text never shows half a character.
size_t complete_utf8(const std::string &s) {
    size_t i = s.size();
    int back = 0;
    while (i > 0 && back < 4) {
        unsigned char c = s[i - 1];
        if ((c & 0xC0) != 0x80) {
            int need = (c & 0x80) == 0 ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : 4;
            return (back + 1 >= need) ? s.size() : i - 1;
        }
        i--;
        back++;
    }
    return s.size();
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativeLoad(JNIEnv *env, jobject, jstring jpath, jlong offset, jint nCtx, jint threads) {
    static bool inited = false;
    if (!inited) {
        llama_log_set(log_cb, nullptr);
        llama_backend_init();
        inited = true;
    }
    // The GGUF starts at [offset] of the file: inside the APK (stored uncompressed) or 0 for a downloaded file.
    std::string path = jstr(env, jpath);
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    llama_model *model = nullptr;
    FILE *file = nullptr;
    for (bool mmap : {true, false}) {
        // mmap needs the tensor data 32-byte aligned in the file, which an APK entry often isn't; then read it in.
        FILE *f = fopen(path.c_str(), "rb");
        if (!f) return 0;
        if (fseeko(f, (off_t) offset, SEEK_SET) == 0) {
            mp.load_mode = mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
            model = llama_model_load_from_file_ptr(f, mp);
        }
        if (model) {
            LOGI("loaded model (mmap: %d)", (int) mmap);
            file = f;
            break;
        }
        fclose(f);
    }
    if (!model) return 0;

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = nCtx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        fclose(file);
        return 0;
    }
    auto *h = new Handle();
    h->file = file;
    h->model = model;
    h->ctx = ctx;
    h->vocab = llama_model_get_vocab(model);
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT void JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativeFree(JNIEnv *, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return;
    llama_free(h->ctx);
    llama_model_free(h->model);
    if (h->file) fclose(h->file);
    delete h;
}

JNIEXPORT void JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativeCancel(JNIEnv *, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (h) h->cancel = true;
}

JNIEXPORT jint JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativeContextSize(JNIEnv *, jobject, jlong handle) {
    auto *h = reinterpret_cast<Handle *>(handle);
    return h ? (jint) llama_n_ctx(h->ctx) : 0;
}

// Tokens the chat prompt for this system + user message takes.
JNIEXPORT jint JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativePromptTokens(JNIEnv *env, jobject, jlong handle, jstring jsys, jstring juser) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return -1;
    return (jint) tokenize(h->vocab, chat_prompt(h->model, jstr(env, jsys), jstr(env, juser)), true).size();
}

// Generates the reply as UTF-8 bytes. Returns null when cancelled or when decoding failed;
// throws IllegalArgumentException when the prompt doesn't fit the context.
JNIEXPORT jbyteArray JNICALL
Java_com_horken7_meetingnotes_llama_LlamaLib_nativeGenerate(
        JNIEnv *env, jobject, jlong handle, jstring jsys, jstring juser, jint maxTokens, jfloat temperature, jobject listener) {
    auto *h = reinterpret_cast<Handle *>(handle);
    if (!h) return nullptr;
    h->cancel = false;

    jclass lc = env->GetObjectClass(listener);
    jmethodID onPrompt = env->GetMethodID(lc, "onPrompt", "(II)V");
    jmethodID onToken = env->GetMethodID(lc, "onText", "([B)V");

    const std::string prompt = chat_prompt(h->model, jstr(env, jsys), jstr(env, juser));
    std::vector<llama_token> tokens = tokenize(h->vocab, prompt, true);
    const int n_ctx = (int) llama_n_ctx(h->ctx);
    if ((int) tokens.size() + maxTokens > n_ctx) {
        jclass ex = env->FindClass("java/lang/IllegalArgumentException");
        std::string msg = "prompt has " + std::to_string(tokens.size()) + " tokens, context is " + std::to_string(n_ctx);
        env->ThrowNew(ex, msg.c_str());
        return nullptr;
    }

    llama_memory_clear(llama_get_memory(h->ctx), true);

    const int n_batch = (int) llama_n_batch(h->ctx);
    for (size_t i = 0; i < tokens.size(); i += n_batch) {
        if (h->cancel) return nullptr;
        const int n = (int) std::min<size_t>(n_batch, tokens.size() - i);
        if (llama_decode(h->ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
            LOGI("prompt decode failed at %zu", i);
            return nullptr;
        }
        env->CallVoidMethod(listener, onPrompt, (jint) (i + n), (jint) tokens.size());
    }

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(h->vocab), 256, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(1234));

    std::string out;
    size_t sent = 0;
    bool ok = true;
    char piece[256];
    for (int i = 0; i < maxTokens; i++) {
        if (h->cancel) { ok = false; break; }
        llama_token id = llama_sampler_sample(smpl, h->ctx, -1);
        if (llama_vocab_is_eog(h->vocab, id)) break;
        const int n = llama_token_to_piece(h->vocab, id, piece, sizeof(piece), 0, false);
        if (n > 0) out.append(piece, n);
        if (i % 8 == 0) {
            const size_t upto = complete_utf8(out);
            if (upto > sent) {
                jbyteArray b = env->NewByteArray((jsize) (upto - sent));
                env->SetByteArrayRegion(b, 0, (jsize) (upto - sent), reinterpret_cast<const jbyte *>(out.data() + sent));
                env->CallVoidMethod(listener, onToken, b);
                env->DeleteLocalRef(b);
                sent = upto;
            }
        }
        if (llama_decode(h->ctx, llama_batch_get_one(&id, 1)) != 0) { ok = false; break; }
    }
    llama_sampler_free(smpl);
    if (!ok) return nullptr;

    jbyteArray result = env->NewByteArray((jsize) out.size());
    env->SetByteArrayRegion(result, 0, (jsize) out.size(), reinterpret_cast<const jbyte *>(out.data()));
    return result;
}

}  // extern "C"
