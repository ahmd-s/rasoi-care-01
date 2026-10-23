# Razorpay staging setup

The customer app uses Razorpay Standard Checkout. The backend creates the order
from its own service and shop catalog prices, verifies the checkout signature,
and confirms the captured amount with Razorpay before it creates bookings or
shop orders. The Razorpay Key Secret is never included in an APK.

## Staging

In the Render dashboard, open the **staging backend service** (`rasoi-care-01`)
and add these environment variables using the **Test Mode** credentials from
Razorpay Dashboard → Account & Settings → API Keys:

| Variable | Value |
| --- | --- |
| `RAZORPAY_MODE` | `test` |
| `RAZORPAY_KEY_ID` | Test Key ID (`rzp_test_...`) |
| `RAZORPAY_KEY_SECRET` | Matching Test Key Secret |

Save the variables and redeploy the staging backend. Never paste the secret in
chat, source files, Flutter `--dart-define`, `local.properties`, or an APK.

The code defaults to test mode and rejects a live Key ID unless
`RAZORPAY_MODE=live` is set deliberately. Keep staging in test mode. Test
payments use Razorpay's simulated checkout and do not transfer real money.

## Before production

Do not switch the staging service to live keys. The production backend needs
its own protected environment variables, a separately reviewed live rollout,
Razorpay automatic capture enabled (the server can also capture an authorized
payment), webhook recovery for payments completed when the app loses its
callback, and a customer APK built with the production API URL and release
signing certificate. Care Coins are currently omitted from online checkout.
