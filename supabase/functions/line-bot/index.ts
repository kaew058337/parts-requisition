// บอตไลน์ (Supabase Edge Function) — แทนส่วนไลน์ใน Code.gs
//  - POST จากไลน์ (webhook, ตรวจลายเซ็น x-line-signature): จดรหัสกลุ่ม, แชทส่วนตัว: /id และค้นหาพัสดุ
//  - ?job=daily  (เรียกโดย pg_cron ตอน 16:10, ต้องมี header x-cron-key): ส่งสรุป/แจ้งด่วนเข้ากลุ่ม
//  - ?job=test   (x-cron-key): ส่งสรุปเต็มเข้ากลุ่มทันที (ทดสอบ)   ?job=status : ดูสถานะการตั้งค่า
// Secrets: LINE_CHANNEL_SECRET, LINE_CHANNEL_TOKEN ; รหัสเรียกงานตั้งเวลาอยู่ในตาราง app_settings (cron_key)  (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY มีให้อัตโนมัติ)
const URL_ = Deno.env.get("SUPABASE_URL")!, KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = (Deno.env.get("LINE_CHANNEL_SECRET") ?? "").trim(), TOKEN = (Deno.env.get("LINE_CHANNEL_TOKEN") ?? "").trim();
const H = { "Content-Type": "application/json", apikey: KEY, Authorization: "Bearer " + KEY };

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: "POST", headers: H, body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}
async function getSet(key: string): Promise<string> {
  const r = await fetch(`${URL_}/rest/v1/app_settings?key=eq.${encodeURIComponent(key)}&select=value`, { headers: H });
  const j = await r.json();
  return (j && j[0] && j[0].value) || "";
}
async function setSet(key: string, value: string) {
  await fetch(`${URL_}/rest/v1/app_settings?on_conflict=key`, { method: "POST", headers: { ...H, Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({ key, value, updated_at: new Date().toISOString() }) });
}
async function log(action: string, detail: string) {
  await fetch(`${URL_}/rest/v1/activity_log`, { method: "POST", headers: H, body: JSON.stringify({ user_name: "ไลน์", action, doc_no: "", detail }) });
}
async function verify(body: string, sig: string): Promise<boolean> {
  if (!SECRET || !sig) return false;
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(body)));
  let s = ""; mac.forEach((b) => (s += String.fromCharCode(b)));
  return btoa(s) === sig;
}
async function line(path: string, payload: unknown) {
  const r = await fetch("https://api.line.me/v2/bot/message/" + path, { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + TOKEN }, body: JSON.stringify(payload) });
  if (!r.ok) throw new Error(`LINE ${r.status}: ${(await r.text()).slice(0, 200)}`);
}
const reply = (token: string, text: string) => token && TOKEN ? line("reply", { replyToken: token, messages: [{ type: "text", text: text.slice(0, 4500) }] }) : Promise.resolve();

async function onEvent(ev: any) {
  const src = ev.source ?? {}, gid = src.groupId || src.roomId || "";
  if (gid) {
    await setSet("line_last_group", gid);
    if (!(await getSet("line_target"))) await setSet("line_target", gid);   // ยังไม่เคยตั้งกลุ่มปลายทาง: ใช้กลุ่มแรกที่บอตเห็น
  }
  if (ev.type !== "message" || ev.message?.type !== "text") return;
  if (src.type && src.type !== "user") return;                // ตอบเฉพาะแชทส่วนตัว
  const text = String(ev.message.text ?? "").trim(), uid = src.userId ?? "";
  if (!text) return;
  if (/^\/id$/i.test(text)) return reply(ev.replyToken, "รหัสไลน์ของคุณ:\n" + uid + "\n\nส่งรหัสนี้ให้ผู้ดูแลระบบเพื่อเพิ่มสิทธิ์ค้นหา");
  const allow = (await getSet("line_search_users")).split(",").map((x) => x.trim()).filter(Boolean);
  if (!uid || !allow.includes(uid)) return reply(ev.replyToken, "ยังไม่ได้รับสิทธิ์ค้นหา\nพิมพ์ /id เพื่อรับรหัสของคุณ แล้วส่งให้ผู้ดูแลระบบ");
  let msg: string;
  try { msg = await rpc("fn_line_search_text", { q: text }); } catch (e) { msg = "⚠️ ค้นหาไม่สำเร็จ: " + (e as Error).message; }
  return reply(ev.replyToken, msg);
}

Deno.serve(async (req) => {
  const u = new URL(req.url), job = u.searchParams.get("job");
  try {
    if (job) {
      const CRON = await getSet("cron_key");
      if (!CRON || req.headers.get("x-cron-key") !== CRON) return new Response("forbidden", { status: 403 });
      if (job === "status") {
        return Response.json({ secret: !!SECRET, secretLen: SECRET.length, token: !!TOKEN, tokenLen: TOKEN.length, target: !!(await getSet("line_target")), lastGroup: await getSet("line_last_group"),
          users: (await getSet("line_search_users")).split(",").filter(Boolean).length });
      }
      const to = await getSet("line_target");
      if (!TOKEN || !to) return Response.json({ sent: false, why: "ยังไม่ได้ตั้ง LINE_CHANNEL_TOKEN หรือยังไม่มีกลุ่มปลายทาง" }, { status: 200 });
      const text: string = job === "test" ? (await rpc("fn_line_digest", { today: new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10), urgent_only: false })) : await rpc("fn_line_daily");
      if (!text) return Response.json({ sent: false, why: "ไม่มีเรื่องที่ต้องแจ้งวันนี้" });
      await line("push", { to, messages: [{ type: "text", text }] });
      await log("สรุปไลน์", "ส่งเข้ากลุ่มแล้ว: " + text.split("\n")[0]);
      return Response.json({ sent: true });
    }
    if (req.method !== "POST") return new Response("OK");
    const body = await req.text();
    if (!(await verify(body, req.headers.get("x-line-signature") ?? ""))) return new Response("bad signature", { status: 401 });
    await setSet("line_last_post", new Date().toISOString());
    for (const ev of JSON.parse(body).events ?? []) { try { await onEvent(ev); } catch (e) { console.error(e); } }
    return new Response("OK");
  } catch (e) {
    console.error(e);
    return new Response("error: " + (e as Error).message, { status: 500 });
  }
});
