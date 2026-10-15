"""Vision AI — secure server-side image validation (Stage A).

Uploaded photos are untrusted. Every image is decoded with Pillow, judged by
its real content (never the declared MIME type or file extension), checked for
size / dimensions / frame count, then re-encoded as a fresh baseline JPEG with
all metadata (EXIF, GPS, ICC, XMP, comments) dropped. Only the re-encoded
bytes ever leave this module, and only in memory: nothing is written to disk
or the database. The SHA-256 of each *original* upload is returned so a result
can be tied to a photo set without keeping the photo.
"""
import base64
import binascii
import hashlib
import io
import os
import warnings

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_IMAGES = 5
MIN_IMAGES = 1


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


# Per-image and aggregate ceilings on the *decoded upload*. The Partner app
# resizes to ~1280 px / q80 (roughly 200-400 KB), so these leave generous room
# while keeping five photos well under Flask's 16 MB request cap.
MAX_IMAGE_BYTES = _env_int("VISION_AI_MAX_IMAGE_BYTES", 1_500_000)
MAX_TOTAL_BYTES = _env_int("VISION_AI_MAX_TOTAL_BYTES", 6_000_000)
MAX_PIXELS = _env_int("VISION_AI_MAX_PIXELS", 24_000_000)
MAX_DIMENSION = _env_int("VISION_AI_MAX_DIMENSION", 8_000)
MIN_DIMENSION = 64
OUTPUT_LONG_EDGE = 1280
OUTPUT_QUALITY = 80

ALLOWED_FORMATS = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}


class ImageRejected(Exception):
    """An upload was refused. `code` is machine-readable, `message` is safe to
    show; `index` is the 0-based position in the submission (None = whole
    submission)."""

    def __init__(self, code, message, index=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.index = index


class ValidatedImage:
    __slots__ = ("jpeg", "sha256", "width", "height")

    def __init__(self, jpeg, sha256, width, height):
        self.jpeg = jpeg
        self.sha256 = sha256
        self.width = width
        self.height = height


def _decode_base64(value, index):
    if not isinstance(value, str) or not value:
        raise ImageRejected("invalid_image_data", "Image data must be a base64 string.", index)
    # Reject before decoding anything oversized: base64 is 4/3 of the payload.
    if len(value) > (MAX_IMAGE_BYTES * 4) // 3 + 8:
        raise ImageRejected("image_too_large", "Image is too large.", index)
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ImageRejected("invalid_image_data", "Image data is not valid base64.", index)


def _validate_one(raw, declared_mime, index):
    if len(raw) > MAX_IMAGE_BYTES:
        raise ImageRejected("image_too_large", "Image is too large.", index)
    if len(raw) < 100:
        raise ImageRejected("invalid_image", "Image is empty or corrupt.", index)
    # Pillow is told the pixel ceiling too, as a second line of defence behind
    # our own pre-decode check below.
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            probe = Image.open(io.BytesIO(raw))
            fmt = probe.format
            width, height = probe.size
            frames = getattr(probe, "n_frames", 1)
            probe.verify()  # structural check; invalidates `probe`
    except (UnidentifiedImageError, Image.DecompressionBombError,
            Image.DecompressionBombWarning, OSError, ValueError, SyntaxError):
        raise ImageRejected("invalid_image", "Image could not be read; it may be corrupt or unsupported.", index)
    if fmt not in ALLOWED_FORMATS:
        raise ImageRejected("unsupported_image_type", "Only JPEG, PNG and WebP photos are accepted.", index)
    if declared_mime is not None and declared_mime != ALLOWED_FORMATS[fmt]:
        # The real content wins; a mismatch is either a bug or an evasion attempt.
        raise ImageRejected("mime_mismatch", "Image type does not match its content.", index)
    if frames and frames > 1:
        raise ImageRejected("animated_image", "Animated images are not accepted.", index)
    if width < MIN_DIMENSION or height < MIN_DIMENSION:
        raise ImageRejected("image_too_small", "Image is too small to inspect.", index)
    if width > MAX_DIMENSION or height > MAX_DIMENSION or width * height > MAX_PIXELS:
        raise ImageRejected("image_dimensions_too_large", "Image dimensions are too large.", index)

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            img = Image.open(io.BytesIO(raw))
            img.load()
            # Bake the camera orientation in BEFORE metadata is dropped, so a
            # portrait photo is not stored sideways.
            img = ImageOps.exif_transpose(img)
            if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
                rgba = img.convert("RGBA")
                flat = Image.new("RGB", rgba.size, (255, 255, 255))
                flat.paste(rgba, mask=rgba.getchannel("A"))
                img = flat
            else:
                img = img.convert("RGB")
            img.thumbnail((OUTPUT_LONG_EDGE, OUTPUT_LONG_EDGE), Image.LANCZOS)
            out = io.BytesIO()
            # No exif=/icc_profile=/comment= arguments: nothing from the
            # source is carried across, which is what strips EXIF and GPS.
            img.save(out, format="JPEG", quality=OUTPUT_QUALITY, optimize=True)
    except (Image.DecompressionBombError, Image.DecompressionBombWarning, OSError, ValueError, SyntaxError):
        raise ImageRejected("invalid_image", "Image could not be processed.", index)
    return ValidatedImage(out.getvalue(), hashlib.sha256(raw).hexdigest(), img.width, img.height)


def validate_images(items):
    """Validates a submission's `images` list (each {"data": base64,
    "mimeType": optional str}) and returns a list of ValidatedImage.
    Raises ImageRejected on the first problem."""
    if not isinstance(items, list):
        raise ImageRejected("invalid_images", "images must be a list.")
    if len(items) < MIN_IMAGES:
        raise ImageRejected("no_images", "At least one photo is required.")
    if len(items) > MAX_IMAGES:
        raise ImageRejected("too_many_images", f"At most {MAX_IMAGES} photos are allowed.")

    decoded, total = [], 0
    for i, item in enumerate(items):
        if not isinstance(item, dict):
            raise ImageRejected("invalid_images", "Each image must be an object.", i)
        mime = item.get("mimeType")
        if mime is not None and not isinstance(mime, str):
            raise ImageRejected("invalid_images", "mimeType must be a string.", i)
        raw = _decode_base64(item.get("data"), i)
        total += len(raw)
        if total > MAX_TOTAL_BYTES:
            raise ImageRejected("images_too_large", "The photos together are too large.")
        decoded.append((raw, mime))

    out, seen = [], set()
    for i, (raw, mime) in enumerate(decoded):
        image = _validate_one(raw, mime, i)
        if image.sha256 in seen:
            raise ImageRejected("duplicate_image", "The same photo was included more than once.", i)
        seen.add(image.sha256)
        out.append(image)
    return out
