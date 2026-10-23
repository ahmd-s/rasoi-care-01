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

## Pay now or pay after service

The Customer picks one at checkout and the server enforces it:

- **Pay now**: the server creates a Razorpay order priced from the catalog,
  Checkout runs on the phone, and the server verifies the signature and the
  captured payment before any booking or shop order exists. The booking is then
  stored with `payment_mode = pay_now` and the paid amount.
- **Pay after service**: `POST /api/bookings/cart` with
  `paymentMode: "pay_after_service"` and no payment. The booking is stored as
  unpaid; its `payment` object shows `mode`, `status`, `invoicePaise`,
  `paidPaise` and `duePaise`. Shop kits are only sold prepaid, so a cart with
  kits must use Pay now. A request with neither a verified payment nor an
  explicit `pay_after_service` is refused (402).

`paidPaise` is only ever written by a server-verified Razorpay payment. The
client cannot send it, and the technician's payment-method label
(`PATCH /api/bookings/<id>/payment`) never marks anything paid.

## Technician invoice QR

After the technician completes the job, the final amount is known
(`total_amount` + customer-approved parts − anything already paid). The Partner
app asks the server for a QR (`POST /api/technician/bookings/<id>/payment-qr`):

- The server creates a single-use, fixed-amount Razorpay **UPI QR Code**
  (`POST /v1/payments/qr_codes`, `type: upi_qr`, `fixed_amount: true`,
  `payment_amount` = the exact due amount, `notes.booking_id`). Repeating the
  call returns the same live QR; if the due amount changed, the old QR is
  closed first. Only the assigned technician can create it, only for a
  Completed job.
- Status comes from `GET /api/technician/bookings/<id>/payment` (technician) or
  `GET /api/bookings/<id>/payment` (the booking's own customer). Each call asks
  Razorpay for the payments on that QR and credits one only if it is
  `captured`, in INR, for exactly the QR amount, and its payment id has not been
  credited anywhere else (unique index). Wrong-amount, uncaptured, replayed and
  other-booking payments are never credited. There is no "Mark paid" button.
- A QR expires after about 2 hours (Razorpay's cap for single-use QRs); the
  technician can show a new one.

### Account prerequisite (what the owner must do)

Razorpay's documentation states that `upi_qr` QR Codes are an **on-demand
feature that Razorpay Support must enable on the account** (QR Codes available in
India). The documentation does not state whether QR Codes work with **test-mode
keys**. Until that is confirmed for the account, the create call may fail; the
server then answers 503 with `code: "qr_not_enabled"` and the Partner app tells
the technician the account needs QR Codes enabled. No untracked or static QR is
ever substituted. To verify: ask Razorpay Support to enable QR Codes for the
account (and for test mode if needed), then complete one test job and scan the
QR with a UPI app (or use Razorpay's test tooling if offered for QR payments).
Webhooks are not used; status is read on demand, so the screens refresh while a
QR is showing and have a manual refresh.
