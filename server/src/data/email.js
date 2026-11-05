// Transactional email: templates (plain HTML, no React), recipient routing, throttling, suppression,
// unsubscribe tokens and the provider call. Port of send-transactional-email + handle-email-unsubscribe,
// without Lovable: the provider is chosen with EMAIL_PROVIDER (resend | sendgrid | log).
import { randomUUID } from "node:crypto";
import {
  BOL_INBOX, RECEIPT_INBOX, adjustmentRecipients, canUploadBol, canUploadReceipt, encodePath, isGroupeQl, isUuid,
  validBolPath, validReceiptPath,
} from "./guard.js";
import { HttpError } from "./handler.js";

const TZ = "America/Toronto";
export const HOURLY_LIMIT = 20;
// A claim still 'pending' after this long means the server died between claim and send: it expires to 'failed' so a retry can go through.
export const STALE_PENDING_MS = 10 * 60_000;
const SITE = "Groupe QL — Transport";

export const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const when = (iso) => new Date(iso || Date.now()).toLocaleString("fr-CA", { timeZone: TZ });

const STYLE = {
  body: "background:#ffffff;font-family:-apple-system,'Segoe UI',Arial,sans-serif;margin:0",
  wrap: "padding:24px 28px;max-width:560px",
  h1: "font-size:22px;font-weight:bold;color:#0f172a;margin:0 0 16px",
  p: "font-size:14px;color:#334155;line-height:1.6;margin:0 0 16px",
  meta: "background:#f1f5f9;border-radius:8px;padding:14px 18px;margin:16px 0",
  row: "font-size:14px;color:#0f172a;margin:3px 0;line-height:1.5",
  item: "border:1px solid #e2e8f0;border-radius:8px;padding:10px 16px;margin:8px 0",
  img: "max-width:100%;height:auto;border-radius:8px;border:1px solid #e2e8f0",
  footer: "font-size:11px;color:#94a3b8;margin:0",
  btn: "background:#0f172a;color:#ffffff;padding:10px 18px;border-radius:8px;text-decoration:none;font-size:14px",
};
const shell = (title, inner, unsubUrl) =>
  `<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>${esc(title)}</title></head><body style="${STYLE.body}"><div style="${STYLE.wrap}">${inner}<hr style="border:none;border-top:1px solid #e2e8f0;margin:24px 0 12px"><p style="${STYLE.footer}">Envoyé automatiquement par ${SITE}.${unsubUrl ? ` <a href="${esc(unsubUrl)}" style="color:#94a3b8">Se désabonner</a>` : ""}</p></div></body></html>`;
const metaRow = (label, value) => `<p style="${STYLE.row}"><strong>${label} :</strong> ${esc(value || "—")}</p>`;

function fileEmail(kind, d, unsubUrl) {
  const bol = kind === "bol";
  const title = bol ? "Nouveau BOL reçu" : "Nouveau reçu reçu";
  const intro = bol ? "Un BOL vient d'être téléversé via l'application Transport." : "Un chauffeur vient de téléverser un reçu via l'application Transport.";
  const url = d.receiptUrl;
  const html = shell(title, `<h1 style="${STYLE.h1}">${title}</h1><p style="${STYLE.p}">${intro}</p>
    <div style="${STYLE.meta}">${metaRow("Chauffeur", d.driverName)}${metaRow("Transporteur", d.carrierName)}${metaRow("Date", d.uploadedAt)}${d.note ? metaRow("Note", d.note) : ""}</div>
    ${url ? `<p style="text-align:center;margin:24px 0"><img src="${esc(url)}" alt="Aperçu" style="${STYLE.img}"></p><p style="text-align:center;margin:24px 0"><a href="${esc(url)}" style="${STYLE.btn}">Télécharger</a></p>` : `<p style="${STYLE.p}">(Aucun fichier joint)</p>`}`, unsubUrl);
  const text = [title, intro, "Chauffeur : " + (d.driverName || "—"), "Transporteur : " + (d.carrierName || "—"), "Date : " + (d.uploadedAt || "—"), d.note ? "Note : " + d.note : "", url ? "Fichier : " + url : ""].filter(Boolean).join("\n");
  return { html, text };
}

function adjustmentEmail(d, unsubUrl) {
  const items = Array.isArray(d.items) ? d.items : [];
  const intro = d.orderKind === "TO"
    ? "Un changement a été signalé au chargement. Veuillez ajuster le transfert."
    : "Un changement a été signalé sur le chantier. Veuillez ajuster la facture.";
  const html = shell("Écart signalé", `<h1 style="${STYLE.h1}">Écart signalé sur ${esc(d.orderNum || "—")}</h1><p style="${STYLE.p}">${intro}</p>
    <div style="${STYLE.meta}">${metaRow("Commande", (d.orderNum || "—") + " (" + (d.orderKind || "SO") + ")")}${metaRow("Transporteur", d.carrierName)}${metaRow("Signalé par", d.reporterName)}${metaRow("Date", d.reportedAt)}</div>
    ${items.map((it) => `<div style="${STYLE.item}"><p style="font-size:15px;font-weight:700;color:#0f172a;margin:0 0 4px">${esc(it.item || "Article")}</p><p style="${STYLE.row}">Prévu : <strong>${esc(it.from || "—")}</strong> → Réel : <strong>${esc(it.to || "—")}</strong></p>${it.reason ? `<p style="${STYLE.row}">Raison : ${esc(it.reason)}</p>` : ""}</div>`).join("")}
    ${d.note ? `<p style="${STYLE.p}"><strong>Note :</strong> ${esc(d.note)}</p>` : ""}
    ${d.photoUrl ? `<p style="text-align:center;margin:16px 0"><img src="${esc(d.photoUrl)}" alt="Photo" style="${STYLE.img}"></p>` : ""}`, unsubUrl);
  const text = ["Écart signalé sur " + (d.orderNum || "—"), intro, "Transporteur : " + (d.carrierName || "—"), "Signalé par : " + (d.reporterName || "—"),
    ...items.map((it) => "- " + (it.item || "Article") + " : " + (it.from || "—") + " → " + (it.to || "—") + (it.reason ? " (" + it.reason + ")" : "")),
    d.note ? "Note : " + d.note : "", d.photoUrl ? "Photo : " + d.photoUrl : ""].filter(Boolean).join("\n");
  return { html, text };
}

const FIELD_LABELS = {
  ship_date: ["Date d'expédition", "Ship date"], event_start_date: ["Date de l'événement", "Event date"], truck: ["Camion", "Truck"],
  carrier: ["Transporteur", "Carrier"], customer: ["Client", "Customer"], address: ["Adresse", "Address"], phone: ["Téléphone", "Phone"],
  city: ["Ville", "City"], shipping_location: ["Lieu d'expédition", "Shipping location"], receiving_location: ["Lieu de réception", "Receiving location"],
  service_type: ["Type de service", "Service type"], status_note: ["Statut", "Status"], memo: ["Mémo", "Memo"],
};
const fieldLabel = (f) => {
  if (FIELD_LABELS[f]) return FIELD_LABELS[f][0] + " / " + FIELD_LABELS[f][1];
  const m = /^(item|custom):(.*)$/.exec(f);
  return m ? (m[1] === "item" ? "Article / Item : " : "") + m[2] : f;
};
function orderChangeEmail(d, unsubUrl) {
  const rows = Array.isArray(d.changes) ? d.changes : [];
  const test = d.testMode
    ? `<div style="${STYLE.item};background:#fef9c3"><p style="${STYLE.row}"><strong>TEST</strong> — destinataires prévus / intended recipients : ${esc((d.intended || []).map((r) => r.email + " (" + (r.roles || []).join("/") + ")").join(", ") || "—")}</p></div>`
    : "";
  const html = shell("Commande modifiée / Order changed", `<h1 style="${STYLE.h1}">Commande modifiée — ${esc(d.orderNum)}</h1>
    ${test}<p style="${STYLE.p}">La commande a été modifiée par <strong>${esc(d.changedBy)}</strong> le ${esc(d.changedAt)}.<br>Order <strong>${esc(d.orderNum)}</strong> was changed by <strong>${esc(d.changedBy)}</strong> on ${esc(d.changedAt)}.</p>
    <div style="${STYLE.meta}">${metaRow("Commande / Order", d.orderNum + " (" + d.orderKind + ")")}${metaRow("Client / Customer", d.customer)}${metaRow("Transporteur / Carrier", d.carrierName)}</div>
    ${rows.map((r) => `<div style="${STYLE.item}"><p style="font-size:15px;font-weight:700;color:#0f172a;margin:0 0 4px">${esc(fieldLabel(r.field))}</p><p style="${STYLE.row}">Avant / Before : <strong>${esc(r.old || "—")}</strong> → Après / After : <strong>${esc(r.new || "—")}</strong></p></div>`).join("")}
    ${d.reason ? `<p style="${STYLE.p}"><strong>Raison / Reason :</strong> ${esc(d.reason)}</p>` : ""}
    ${d.ticketUrl ? `<p style="text-align:center;margin:24px 0"><a href="${esc(d.ticketUrl)}" style="${STYLE.btn}">Voir le bon de commande / View picking ticket</a></p>` : ""}
    <p style="${STYLE.footer}">Sent automatically by ${SITE}. Unsubscribe link below.</p>`, unsubUrl);
  const text = [
    (d.testMode ? "[TEST] " : "") + "Commande modifiée / Order changed — " + d.orderNum,
    "Modifiée par / Changed by : " + d.changedBy + " (" + d.changedAt + ")",
    "Transporteur / Carrier : " + (d.carrierName || "—"),
    ...rows.map((r) => "- " + fieldLabel(r.field) + " : " + (r.old || "—") + " → " + (r.new || "—")),
    d.reason ? "Raison / Reason : " + d.reason : "", d.ticketUrl ? "Bon de commande / Picking ticket : " + d.ticketUrl : "",
    d.testMode ? "TEST — destinataires prévus / intended: " + (d.intended || []).map((r) => r.email).join(", ") : "",
  ].filter(Boolean).join("\n");
  return { html, text };
}

export const TEMPLATES = {
  "order-change": {
    subject: (d) => `${d?.testMode ? "[TEST] " : ""}Commande modifiée / Order changed — ${d?.orderNum || ""}${d?.customer ? ` (${d.customer})` : ""}`,
    render: (d, u) => orderChangeEmail(d, u),
  },
  "receipt-uploaded": {
    subject: (d) => `Nouveau reçu — ${d?.driverName || "Chauffeur"}${d?.carrierName ? ` (${d.carrierName})` : ""}`,
    render: (d, u) => fileEmail("receipt", d, u),
  },
  "bol-uploaded": {
    subject: (d) => `Nouveau BOL — ${d?.driverName || "Chauffeur"}${d?.carrierName ? ` (${d.carrierName})` : ""}`,
    render: (d, u) => fileEmail("bol", d, u),
  },
  "order-adjustment": {
    subject: (d) => `Écart signalé — ${d?.orderNum || "Commande"}${d?.carrierName ? ` (${d.carrierName})` : ""}`,
    render: (d, u) => adjustmentEmail(d, u),
  },
};

// ------------------------------------------------------------------------------------ providers
/** provider.send({ from, to, subject, html, text, headers }) -> throws on failure. */
export function createProvider(cfg, fetchImpl = fetch) {
  const post = async (url, headers, body) => {
    const res = await fetchImpl(url, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
    if (!res.ok) throw new Error("email provider answered " + res.status);
  };
  switch (cfg.provider) {
    case "resend":
      return { name: "resend", send: (m) => post("https://api.resend.com/emails", { Authorization: "Bearer " + cfg.apiKey }, {
        from: m.from, to: [m.to], subject: m.subject, html: m.html, text: m.text, reply_to: cfg.replyTo || undefined, headers: m.headers }) };
    case "sendgrid":
      return { name: "sendgrid", send: (m) => post("https://api.sendgrid.com/v3/mail/send", { Authorization: "Bearer " + cfg.apiKey }, {
        personalizations: [{ to: [{ email: m.to }] }], from: parseFrom(m.from), subject: m.subject,
        reply_to: cfg.replyTo ? { email: cfg.replyTo } : undefined,
        content: [{ type: "text/plain", value: m.text }, { type: "text/html", value: m.html }], headers: m.headers }) };
    default:
      return { name: "log", send: async (m) => { console.log(JSON.stringify({ event: "email_not_sent_log_provider", to: m.to, subject: m.subject })); } };
  }
}
function parseFrom(from) {
  const m = /^(.*)<([^>]+)>\s*$/.exec(from);
  return m ? { name: m[1].trim().replace(/^"|"$/g, ""), email: m[2].trim() } : { email: from.trim() };
}

// ------------------------------------------------------------------------------------ job building
async function buildJob(template, input, session, store, baseUrl, publicSiteUrl = "") {
  const superUser = session.appRole === "superuser";
  if (template === "order-change") {
    if (!isUuid(input.changeId)) throw new HttpError(400, "changeId_required");
    const rows = await store.getOrderChange(input.changeId);
    if (!rows.length) throw new HttpError(404, "change_not_found");
    const first = rows[0];
    if (!superUser && first.changed_by !== session.carrier) throw new HttpError(403, "not_your_change");
    const n = first.notified_recipients ?? {};
    const ctx = first.context ?? {};
    return {
      recipients: Array.isArray(n.delivered) ? n.delivered : [],
      data: {
        orderNum: first.order_num, orderKind: first.order_kind, changedBy: first.changed_by, changedAt: when(first.changed_at), reason: first.reason,
        changes: rows.map((r) => ({ field: r.field, old: r.old_value, new: r.new_value })), carrierName: ctx.carrierName, customer: ctx.customer,
        testMode: Boolean(n.override), intended: n.intended ?? [], ticketUrl: publicSiteUrl ? publicSiteUrl.replace(/\/+$/, "") : "",
      },
      markTable: undefined, markId: undefined, meta: { changeId: first.change_id },
    };
  }
  if (template === "order-adjustment") {
    if (!isUuid(input.reportId)) throw new HttpError(400, "reportId_required");
    const row = await store.getAdjustment(input.reportId);
    if (!row) throw new HttpError(404, "report_not_found");
    if (!superUser && row.carrier_name !== session.carrier) throw new HttpError(403, "not_your_report");
    if (input.orderNum && String(input.orderNum) !== row.order_num) throw new HttpError(422, "order_mismatch");
    const photoOk = typeof row.photo_url === "string" && row.photo_url.startsWith(baseUrl + "/storage/v1/object/public/receipts/adjustments/");
    const locations = row.order_kind === "TO" && Array.isArray(row.transfer_locations) ? row.transfer_locations.map(String) : [];
    return {
      recipients: adjustmentRecipients(row.carrier_name, locations),
      data: {
        orderNum: row.order_num, orderKind: row.order_kind, carrierName: row.carrier_name, reporterName: row.reporter_name,
        items: Array.isArray(row.items) ? row.items : [], note: row.note, photoUrl: photoOk ? row.photo_url : undefined, reportedAt: when(row.created_at),
      },
      markTable: "order_adjustments", markId: row.id, meta: { reportId: row.id },
    };
  }
  if (template === "receipt-uploaded" || template === "bol-uploaded") {
    const bol = template === "bol-uploaded";
    if (input.kind !== (bol ? "bol" : "receipt")) throw new HttpError(422, "kind_mismatch");
    if (bol ? !canUploadBol(session) : !canUploadReceipt(session)) throw new HttpError(403, "role_not_allowed");
    const path = input.storagePath;
    if (bol ? !validBolPath(path) : !validReceiptPath(path)) throw new HttpError(422, "bad_storage_path");
    let row = null;
    if (input.receiptId !== undefined && input.receiptId !== null) {
      if (!isUuid(input.receiptId)) throw new HttpError(400, "receiptId_invalid");
      row = await store.getReceipt(input.receiptId);
      if (!row) throw new HttpError(404, "receipt_not_found");
      if (!superUser && row.carrier_name !== session.carrier) throw new HttpError(403, "not_your_receipt");
      if (row.storage_path !== path) throw new HttpError(422, "path_mismatch");
    }
    // The picture must really be stored (the log row is optional: the app still sends the email when logging failed).
    const file = await store.getFile("receipts", path);
    if (!file) throw new HttpError(404, "file_not_found");
    // No log row: the picture must have been uploaded by this very login (otherwise any receipt user could mail any stored file).
    if (!row && !superUser && file.uploaded_by !== session.carrier) throw new HttpError(403, "not_your_file");
    const url = baseUrl + "/storage/v1/object/public/receipts/" + encodePath(path);
    return {
      recipients: [bol ? BOL_INBOX : RECEIPT_INBOX],
      data: { driverName: row?.driver_name || "—", carrierName: row?.carrier_name || session.carrier, note: row?.note || "", receiptUrl: url, uploadedAt: when(row?.created_at) },
      markTable: row ? "receipts" : undefined, markId: row?.id, meta: { receiptId: row?.id ?? null, storagePath: path },
    };
  }
  throw new HttpError(404, "unknown_template");
}

/**
 * POST /functions/v1/send-transactional-email. Recipients are always derived on the server from the
 * stored row (the body's recipient is ignored) and must be @groupeql.com. Returns { status, body }.
 */
export async function sendTransactional({ body, session, store, provider, baseUrl, from, publicSiteUrl, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  const templateName = body?.templateName || body?.template_name;
  const idempotencyKey = String(body?.idempotencyKey || body?.idempotency_key || "");
  const input = body?.templateData && typeof body.templateData === "object" ? body.templateData : {};
  if (typeof templateName !== "string" || !Object.hasOwn(TEMPLATES, templateName)) return { status: 404, body: { error: "unknown_template" } };
  if (!idempotencyKey || idempotencyKey.length > 120) return { status: 400, body: { error: "idempotencyKey_required" } };

  const since = new Date(Date.now() - 3600_000).toISOString();
  const staleBefore = new Date(Date.now() - STALE_PENDING_MS).toISOString();

  const job = await buildJob(templateName, input, session, store, baseUrl, publicSiteUrl);
  if (job.recipients.length === 0 || !job.recipients.every(isGroupeQl)) throw new HttpError(422, "recipient_not_allowed");

  const tpl = TEMPLATES[templateName];
  const subject = tpl.subject(job.data);
  let sent = 0, suppressed = 0, duplicates = 0, throttled = false;

  for (const to of job.recipients.map((r) => r.toLowerCase())) {
    const key = idempotencyKey + ":" + to;
    const messageId = randomUUID();
    const meta = { ...job.meta, carrier: session.carrier, idempotency_key: key };
    // Insert-first: the claim is atomic (unique key + per-carrier lock), so concurrent retries cannot both send.
    const claim = await store.claimSend(
      { message_id: messageId, template_name: templateName, recipient_email: to, status: "pending", metadata: meta },
      { key, carrier: session.carrier, limit: HOURLY_LIMIT, sinceIso: since, staleBeforeIso: staleBefore },
    );
    if (claim.state === "duplicate") { duplicates++; continue; }
    if (claim.state === "throttled") { throttled = true; break; }
    const logId = claim.id;
    try {
      if (await store.isSuppressed(to)) { // fail closed: a lookup error throws and nothing is sent
        await store.updateSend(logId, { status: "suppressed" });
        suppressed++; continue;
      }
      const token = await store.unsubscribeTokenFor(to);
      if (token === "used") { await store.updateSend(logId, { status: "suppressed" }); suppressed++; continue; }
      const siteUnsub = publicSiteUrl ? publicSiteUrl.replace(/\/+$/, "") + "/#/unsubscribe?token=" + token : "";
      const oneClick = baseUrl + "/functions/v1/handle-email-unsubscribe?token=" + token;
      const { html, text } = tpl.render(job.data, siteUnsub);
      const headers = { "List-Unsubscribe": "<" + oneClick + ">", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" };
      let lastErr = null;
      for (let attempt = 0; attempt < 3; attempt++) {
        try { await provider.send({ from, to, subject, html, text, headers }); lastErr = null; break; }
        catch (e) { lastErr = e; if (attempt < 2) await sleep(500 * (attempt + 1)); }
      }
      if (lastErr) {
        await store.updateSend(logId, { status: "failed", error_message: String(lastErr.message).slice(0, 300) });
        throw new HttpError(502, "email_provider_error");
      }
      await store.updateSend(logId, { status: "sent" });
      sent++;
    } catch (e) {
      // never leave a 'pending' claim behind: it would turn every retry into a silent duplicate
      if (!(e instanceof HttpError)) await store.updateSend(logId, { status: "failed", error_message: String(e && e.message).slice(0, 300) }).catch(() => {});
      throw e;
    }
  }

  // only the server marks a row as emailed
  if ((sent > 0 || duplicates > 0) && job.markTable && job.markId) await store.markEmailSent(job.markTable, job.markId);
  if (throttled && sent === 0 && duplicates === 0) return { status: 429, body: { error: "too_many_emails", retryAfter: 3600 } };
  if (sent === 0 && duplicates === 0 && suppressed > 0) return { status: 200, body: { success: false, reason: "email_suppressed" } };
  return { status: 200, body: { success: true, queued: sent, duplicate: sent === 0 && duplicates > 0 } };
}

/** handle-email-unsubscribe. method GET validates, POST consumes. */
export async function handleUnsubscribe({ method, token, store }) {
  if (!token || typeof token !== "string" || token.length > 200) return { status: 400, body: { error: "Token is required" } };
  const rec = await store.getUnsubscribeToken(token);
  if (!rec) return { status: 404, body: { error: "Invalid or expired token" } };
  if (rec.used_at) return { status: 200, body: { valid: false, reason: "already_unsubscribed" } };
  if (method === "GET") return { status: 200, body: { valid: true } };
  const email = await store.useUnsubscribeToken(token);
  if (!email) return { status: 200, body: { success: false, reason: "already_unsubscribed" } };
  return { status: 200, body: { success: true } };
}
