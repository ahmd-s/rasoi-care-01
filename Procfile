# Single worker, single thread — deliberate and load-bearing, not a
# placeholder: rate-limit buckets, auth-backoff counters, and cancellation
# OTP codes live in this process's memory (see app.py's rate-limit section).
# A second worker would split that state and silently disarm all of it.
# Scale out only after moving that state to a shared store (Redis/DB).
web: gunicorn app:app --bind 0.0.0.0:$PORT --workers 1 --threads 1
