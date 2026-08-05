// VFR Radio — shared-key proxy (Cloudflare Worker, Rust / workers-rs).
//
// Holds the class Anthropic key SERVER-SIDE (never in the site), gates access
// with a class passcode, rate-limits per IP so nobody drains the prepaid $20,
// and forwards graded-call requests to the Claude Messages API. Deploy is free
// and needs no credit card — see worker/README.md.
//
// Secrets (set with `wrangler secret put`):
//   ANTHROPIC_API_KEY  — the class's prepaid key (auto-reload OFF = hard cap)
//   CLASS_PASSCODE     — the passcode you hand students
// Binding (set in wrangler.toml): KV namespace `RATE_LIMIT`.

use worker::*;

const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";
const MAX_PER_HOUR: u32 = 40; // per IP; the $20 balance is the ultimate backstop

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

#[event(fetch)]
async fn fetch(mut req: Request, env: Env, _ctx: Context) -> Result<Response> {
    if req.method() == Method::Options {
        return cors(Response::empty()?);
    }
    if req.method() != Method::Post {
        return deny(405, "POST only");
    }

    // 1. Passcode gate.
    let expected = env.secret("CLASS_PASSCODE").map(|s| s.to_string()).ok();
    let provided = req.headers().get("x-class-passcode")?.unwrap_or_default();
    match expected {
        Some(exp) if !exp.is_empty() && provided == exp => {}
        _ => return deny(401, "Bad or missing class passcode."),
    }

    // 2. Per-IP rate limit (coarse; KV is eventually consistent, which is fine
    //    for keeping a shared demo key from being hammered).
    let ip = req
        .headers()
        .get("cf-connecting-ip")?
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
            return deny(429, "Rate limit reached — take a short break, or use your own key.");
        }
        let _ = kv
            .put(&key, (count + 1).to_string())?
            .expiration_ttl(3600)
            .execute()
            .await;
    }

    // 3. Forward the graded-call request to Claude with the class key.
    let api_key = match env.secret("ANTHROPIC_API_KEY") {
        Ok(k) => k.to_string(),
        Err(_) => return deny(500, "Proxy misconfigured: no API key."),
    };
    let body = req.text().await.unwrap_or_default();

    let mut headers = Headers::new();
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
