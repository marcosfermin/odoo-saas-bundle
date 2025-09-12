# Operations — Billing Webhooks

Endpoint: `POST /webhooks/billing`

## Stripe
- Set endpoint in Stripe dashboard
- Set `STRIPE_SIGNING_SECRET` (HMAC)
- Events: `invoice.payment_succeeded` (unsuspend), `invoice.payment_failed` (suspend)

## Paddle
- Export RSA public key → Base64 → `PADDLE_PUBLIC_KEY_BASE64`
- Verify signatures
- Same actions as Stripe

## Fallback
`X-Webhook-Secret` header equals `WEBHOOK_SECRET`

## Audit & Alerts
All webhook actions audited; alerts on suspend/unsuspend.
