// Supabase Edge Function: admin-users
// Owner-only account administration that needs the service-role key:
//   create partner account, reset a partner's password, ban/unban login.
// The caller's JWT is checked against the database (owner + unlocked private
// area) before any admin action runs. The service-role key never leaves the server.
//
// Deploy:  supabase functions deploy admin-users
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type Body =
  | { action: "create_partner"; email: string; password: string; full_name: string }
  | { action: "reset_password"; user_id: string; password: string }
  | { action: "set_login_enabled"; user_id: string; enabled: boolean };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  // Public key: the app sends it in the "apikey" header; env var as fallback.
  const anonKey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  // Admin key: built-in service role key, or a secret named SERVICE_KEY (sb_secret_...).
  const serviceKey = Deno.env.get("SERVICE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!url || !anonKey) return json({ error: "Function is missing project URL/API key" }, 500);
  if (!serviceKey) {
    return json({ error: "Add an Edge Function secret named SERVICE_KEY with your secret (sb_secret_...) key" }, 500);
  }

  // 1) Verify the caller is the owner with an unlocked private area.
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader, "x-device-id": req.headers.get("x-device-id") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: status, error: statusErr } = await asCaller.rpc("private_status");
  if (statusErr || !status?.is_owner) return json({ error: "Owner access required" }, 403);
  if (!status.unlocked) return json({ error: "PRIVATE_LOCKED: Unlock the Owner Private Area first" }, 403);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request body" }, 400);
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const validPassword = (p: unknown) => typeof p === "string" && p.length >= 8 && p.length <= 72;

  async function assertPartner(userId: string) {
    const { data, error } = await admin.from("profiles").select("role").eq("id", userId).single();
    if (error || !data) throw new Error("User not found");
    if (data.role !== "partner") throw new Error("Only partner accounts can be changed here");
  }

  async function audit(action: string, entityId: string) {
    // Written with service role; actor recorded through caller's identity lookup.
    const { data: caller } = await asCaller.auth.getUser();
    await admin.schema("private").from("audit_logs").insert({
      actor_id: caller.user?.id ?? null,
      action,
      entity: "auth_user",
      entity_id: entityId,
    });
  }

  try {
    switch (body.action) {
      case "create_partner": {
        const email = String(body.email ?? "").trim().toLowerCase();
        const fullName = String(body.full_name ?? "").trim();
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Enter a valid email" }, 400);
        if (!fullName) return json({ error: "Name is required" }, 400);
        if (!validPassword(body.password)) return json({ error: "Password must be 8–72 characters" }, 400);

        const { data, error } = await admin.auth.admin.createUser({
          email,
          password: body.password,
          email_confirm: true,
          user_metadata: { full_name: fullName },
        });
        if (error) return json({ error: error.message }, 400);
        // Trigger created an inactive partner profile; activate with read-only defaults.
        const { error: pErr } = await admin.from("profiles")
          .update({ is_active: true, full_name: fullName, can_create_sale: false, can_override_price: false })
          .eq("id", data.user.id);
        if (pErr) return json({ error: "Account created but profile activation failed" }, 500);
        await audit("partner_created", data.user.id);
        return json({ user_id: data.user.id });
      }
      case "reset_password": {
        if (!validPassword(body.password)) return json({ error: "Password must be 8–72 characters" }, 400);
        await assertPartner(body.user_id);
        const { error } = await admin.auth.admin.updateUserById(body.user_id, { password: body.password });
        if (error) return json({ error: error.message }, 400);
        // Force re-login everywhere.
        await admin.from("profiles").update({ sessions_valid_after: new Date().toISOString() }).eq("id", body.user_id);
        await audit("partner_password_reset", body.user_id);
        return json({ ok: true });
      }
      case "set_login_enabled": {
        await assertPartner(body.user_id);
        const { error } = await admin.auth.admin.updateUserById(body.user_id, {
          ban_duration: body.enabled ? "none" : "876000h",
        });
        if (error) return json({ error: error.message }, 400);
        await audit(body.enabled ? "partner_login_enabled" : "partner_login_disabled", body.user_id);
        return json({ ok: true });
      }
      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : "Request failed" }, 400);
  }
});
