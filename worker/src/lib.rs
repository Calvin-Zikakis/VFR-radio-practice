// VFR Radio — shared-key proxy (Cloudflare Worker, Rust / workers-rs).
//
// Holds the class Anthropic key SERVER-SIDE (never in the site), gates access
// with a class passcode, rate-limits per IP, and serves three POST endpoints:
//
//   /  or /grade  → forward a graded-call request to the Claude Messages API
//   /stt          → speech-to-text via Workers AI Whisper (audio bytes → text)
//   /tts          → text-to-speech via Workers AI MeloTTS (text → base64 audio)
//
// Voice runs on Workers AI (free daily allowance, no credit card) so Firefox and
// Safari — which lack the browser Speech APIs — get voice both ways. Deploy is
// free and needs no card; see worker/README.md.
//
// Secrets (set with `wrangler secret put`):
//   ANTHROPIC_API_KEY  — the class's prepaid key (auto-reload OFF = hard cap)
//   CLASS_PASSCODE     — the passcode you hand students
// Bindings (wrangler.toml): KV namespace `RATE_LIMIT`, Workers AI `AI`.

use worker::*;

const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";
// Per IP. A full practice turn is up to 3 calls (grade + STT + TTS), so this is
// ~65 turns/hour — plenty for a long session, still a guard on the shared balance.
const MAX_PER_HOUR: u32 = 200;
const WHISPER_MODEL: &str = "@cf/openai/whisper";
const TTS_MODEL: &str = "@cf/myshell-ai/melotts";

fn cors(mut resp: Response) -> Result<Response> {
    let h = resp.headers_mut();
    h.set("Access-Control-Allow-Origin", "*")?;
    h.set("Access-Control-Allow-Methods", "POST, OPTIONS")?;
    h.set(
        "Access-Control-Allow-Headers",
        "content-type, x-class-passcode",
    )?;
    Ok(resp)
}

fn deny(status: u16, msg: &str) -> Result<Response> {
    cors(Response::error(msg, status)?)
}

fn json_ok(value: serde_json::Value) -> Result<Response> {
    cors(Response::from_json(&value)?)
}

/// Passcode gate. Returns Some(deny-response) when rejected.
fn check_passcode(req: &Request, env: &Env) -> Option<Result<Response>> {
    let expected = env.secret("CLASS_PASSCODE").map(|s| s.to_string()).ok();
    let provided = req
        .headers()
        .get("x-class-passcode")
        .ok()
        .flatten()
        .unwrap_or_default();
    match expected {
        Some(exp) if !exp.is_empty() && provided == exp => None,
        _ => Some(deny(401, "Bad or missing class passcode.")),
    }
}

/// Per-IP rate limit (coarse; KV is eventually consistent, which is fine for
/// keeping a shared demo key from being hammered). Returns Some(deny) if over.
async fn check_rate_limit(req: &Request, env: &Env) -> Option<Result<Response>> {
    let ip = req
        .headers()
        .get("cf-connecting-ip")
        .ok()
        .flatten()
        .unwrap_or_else(|| "unknown".into());
    if let Ok(kv) = env.kv("RATE_LIMIT") {
        let key = format!("rl:{ip}");
        let count: u32 = kv
            .get(&key)
            .text()
            .await
            .ok()
            .flatten()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if count >= MAX_PER_HOUR {
            return Some(deny(
                429,
                "Rate limit reached — take a short break, or use your own key.",
            ));
        }
        if let Ok(builder) = kv.put(&key, (count + 1).to_string()) {
            let _ = builder.expiration_ttl(3600).execute().await;
        }
    }
    None
}

#[event(fetch)]
async fn fetch(mut req: Request, env: Env, _ctx: Context) -> Result<Response> {
    if req.method() == Method::Options {
        return cors(Response::empty()?);
    }
    if req.method() != Method::Post {
        return deny(405, "POST only");
    }

    if let Some(resp) = check_passcode(&req, &env) {
        return resp;
    }
    if let Some(resp) = check_rate_limit(&req, &env).await {
        return resp;
    }

    match req.path().as_str() {
        "/stt" => handle_stt(&mut req, &env).await,
        "/tts" => handle_tts(&mut req, &env).await,
        _ => handle_grade(&mut req, &env).await, // "/", "/grade", anything else
    }
}

/// Forward the graded-call request to Claude with the class key.
async fn handle_grade(req: &mut Request, env: &Env) -> Result<Response> {
    let api_key = match env.secret("ANTHROPIC_API_KEY") {
        Ok(k) => k.to_string(),
        Err(_) => return deny(500, "Proxy misconfigured: no API key."),
    };
    let body = req.text().await.unwrap_or_default();

    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    headers.set("x-api-key", &api_key)?;
    headers.set("anthropic-version", "2023-06-01")?;

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    let upstream = Request::new_with_init(ANTHROPIC_URL, &init)?;

    match Fetch::Request(upstream).send().await {
        Ok(mut resp) => {
            let status = resp.status_code();
            let text = resp.text().await.unwrap_or_default();
            let mut out = Response::ok(text)?.with_status(status);
            out.headers_mut().set("content-type", "application/json")?;
            cors(out)
        }
        Err(_) => deny(502, "Upstream request failed."),
    }
}

// Workers AI inputs MUST be typed structs, not serde_json::Value: serde-wasm-
// bindgen serializes a JSON object as a JS Map (which the model ignores),
// whereas a #[derive(Serialize)] struct becomes a real JS object.
#[derive(serde::Serialize)]
struct WhisperInput {
    audio: Vec<u8>,
}
#[derive(serde::Serialize)]
struct MeloInput<'a> {
    prompt: &'a str,
    lang: &'a str,
}

/// Speech-to-text: audio bytes in the POST body → { "text": "..." }.
async fn handle_stt(req: &mut Request, env: &Env) -> Result<Response> {
    let ai = match env.ai("AI") {
        Ok(ai) => ai,
        Err(_) => return deny(500, "Proxy misconfigured: no AI binding."),
    };
    let audio = req.bytes().await.unwrap_or_default();
    if audio.is_empty() {
        return deny(400, "Empty audio.");
    }
    // Whisper takes the audio file as an array of byte values.
    match ai
        .run::<_, serde_json::Value>(WHISPER_MODEL, WhisperInput { audio })
        .await
    {
        Ok(v) => {
            let text = v.get("text").and_then(|t| t.as_str()).unwrap_or("").trim();
            json_ok(serde_json::json!({ "text": text }))
        }
        Err(e) => deny(502, &format!("Transcription failed: {e}")),
    }
}

/// Text-to-speech: { "text": "..." } → { "audio": "<base64 mp3>" } (MeloTTS).
async fn handle_tts(req: &mut Request, env: &Env) -> Result<Response> {
    let ai = match env.ai("AI") {
        Ok(ai) => ai,
        Err(_) => return deny(500, "Proxy misconfigured: no AI binding."),
    };
    let payload: serde_json::Value = req.json().await.unwrap_or(serde_json::Value::Null);
    let text = payload.get("text").and_then(|t| t.as_str()).unwrap_or("");
    if text.trim().is_empty() {
        return deny(400, "Empty text.");
    }
    match ai
        .run::<_, serde_json::Value>(TTS_MODEL, MeloInput { prompt: text, lang: "en" })
        .await
    {
        // MeloTTS returns { audio: "<base64 mp3>" }; pass it straight through.
        Ok(v) => {
            let audio = v.get("audio").and_then(|a| a.as_str()).unwrap_or("");
            if audio.is_empty() {
                return deny(502, "Speech synthesis returned no audio.");
            }
            json_ok(serde_json::json!({ "audio": audio }))
        }
        Err(e) => deny(502, &format!("Speech synthesis failed: {e}")),
    }
}
