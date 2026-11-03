// GymFlow : fonction « notify » (Supabase Edge Function, Deno).
//
// Appelée par la base (pg_net) quand quelqu'un reçoit un message, un
// message d'encouragement ou une demande d'ami alors qu'il n'utilise pas
// l'application. Elle demande à la base le contenu de la notification
// (public.push_payload, réservé à la clé de service), puis l'envoie à
// Firebase Cloud Messaging (API HTTP v1).
//
// Secrets à définir dans Supabase (Edge Functions -> Secrets) :
//   FCM_SERVICE_ACCOUNT : le contenu JSON COMPLET de la clé de compte de
//                         service Firebase.
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement.
//
// « Verify JWT » doit être DÉSACTIVÉ pour cette fonction : la base l'appelle
// sans jeton. Cela ne pose pas de problème : la fonction ne fait rien qu'un
// événement réel de la base n'ait déjà décidé (chaque événement n'est
// traité qu'une fois, voir private.push_log) et ne renvoie aucune donnée.

import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

const serviceAccount = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "{}");

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

let cached: { token: string; expiresAt: number } | null = null;

/** Jeton d'accès Google (OAuth 2, compte de service), gardé jusqu'à expiration. */
async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expiresAt - 60 > now) return cached.token;

  const key = await importPKCS8(serviceAccount.private_key, "RS256");
  const assertion = await new SignJWT({
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(serviceAccount.client_email)
    .setSubject(serviceAccount.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`OAuth Google : ${res.status} ${await res.text()}`);
  const json = await res.json();
  cached = { token: json.access_token, expiresAt: now + (json.expires_in ?? 3600) };
  return cached.token;
}

interface Payload {
  tokens: string[];
  title: string;
  body: string;
  route: string | null;
  ref: string | null;
}

async function send(token: string, access: string, p: Payload): Promise<void> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${access}`,
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: p.title, body: p.body },
          // Lu par l'application quand on touche la notification.
          data: { route: p.route ?? "", ref: p.ref ?? "" },
          android: {
            priority: "HIGH",
            notification: { channel_id: "gymflow_amis" },
          },
        },
      }),
    },
  );
  if (res.ok) return;
  const text = await res.text();
  // Application désinstallée ou jeton périmé : on l'oublie.
  if (res.status === 404 || text.includes("UNREGISTERED")) {
    await supabase.rpc("drop_push_token", { p_token: token });
    return;
  }
  console.error(`FCM ${res.status} : ${text}`);
}

Deno.serve(async (req) => {
  try {
    const { event } = await req.json();
    if (typeof event !== "string" || event.length > 100) {
      return new Response("requête invalide", { status: 400 });
    }
    const { data, error } = await supabase.rpc("push_payload", { p_event: event });
    if (error) {
      console.error("push_payload :", error.message);
      return new Response("erreur", { status: 500 });
    }
    const row: Payload | undefined = Array.isArray(data) ? data[0] : data;
    // Événement déjà traité, supprimé ou sans appareil : rien à faire.
    if (!row || !row.tokens || row.tokens.length === 0) {
      return new Response("rien à envoyer", { status: 200 });
    }
    const access = await accessToken();
    await Promise.all(row.tokens.map((t) => send(t, access, row)));
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("erreur", { status: 500 });
  }
});
