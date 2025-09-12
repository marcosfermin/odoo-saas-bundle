# API Reference

## Webhooks
### `POST /webhooks/billing` (Stripe/Paddle/Fallback)
- Stripe: `Stripe-Signature` HMAC header
- Paddle: RSA signature against Base64 public key
- Fallback: `X-Webhook-Secret` equals `WEBHOOK_SECRET`
- Actions: suspend/unsuspend + audit log

## Admin Actions (UI-backed)
- Tenants: create/delete/suspend/unsuspend
- Modules: install/upgrade/uninstall per tenant
- Backups: enqueue backup/restore
- Jobs: view list/details/results
