"""Vision AI Stage A — secure image validation. All images are synthetic."""
import base64
import hashlib
import io
import random

import pytest
from PIL import Image

import vision_images as vi


def _img(w=320, h=240, seed=1, mode="RGB"):
    rnd = random.Random(seed)
    im = Image.new(mode, (w, h))
    px = im.load()
    for x in range(0, w, 8):
        for y in range(0, h, 8):
            c = tuple(rnd.randrange(256) for _ in range(len(mode)))
            for dx in range(8):
                for dy in range(8):
                    if x + dx < w and y + dy < h:
                        px[x + dx, y + dy] = c
    return im


def _bytes(im, fmt="JPEG", **kw):
    out = io.BytesIO()
    im.save(out, format=fmt, **kw)
    return out.getvalue()


def _item(raw, mime=None):
    d = {"data": base64.b64encode(raw).decode()}
    if mime:
        d["mimeType"] = mime
    return d


def _reject(items):
    with pytest.raises(vi.ImageRejected) as e:
        vi.validate_images(items)
    return e.value


# ---------------------------------------------------------------- accepted
@pytest.mark.parametrize("fmt,mime", [("JPEG", "image/jpeg"), ("PNG", "image/png"), ("WEBP", "image/webp")])
def test_valid_formats_are_reencoded_as_jpeg(fmt, mime):
    raw = _bytes(_img(), fmt)
    [out] = vi.validate_images([_item(raw, mime)])
    assert out.jpeg[:3] == b"\xff\xd8\xff"
    assert Image.open(io.BytesIO(out.jpeg)).format == "JPEG"
    assert out.sha256 == hashlib.sha256(raw).hexdigest()   # hash of the ORIGINAL upload


def test_mime_type_is_optional():
    assert len(vi.validate_images([_item(_bytes(_img()))])) == 1


def test_one_to_five_images():
    items = [_item(_bytes(_img(seed=i))) for i in range(5)]
    assert len(vi.validate_images(items)) == 5


def test_large_photos_are_downscaled_to_1280():
    [out] = vi.validate_images([_item(_bytes(_img(3000, 2000), quality=70))])
    assert max(out.width, out.height) == 1280
    im = Image.open(io.BytesIO(out.jpeg))
    assert im.size == (out.width, out.height)


def test_small_photos_are_not_upscaled():
    [out] = vi.validate_images([_item(_bytes(_img(400, 300)))])
    assert (out.width, out.height) == (400, 300)


def test_alpha_png_is_flattened():
    rgba = Image.new("RGBA", (200, 200), (255, 0, 0, 0))
    [out] = vi.validate_images([_item(_bytes(rgba, "PNG"))])
    assert Image.open(io.BytesIO(out.jpeg)).mode == "RGB"


# --------------------------------------------------------- metadata removal
def _exif_with_gps():
    exif = Image.Exif()
    exif[0x010F] = "SecretCameraMaker"          # Make
    exif[0x0132] = "2026:10:15 10:00:00"        # DateTime
    gps = exif.get_ifd(0x8825)
    gps[1], gps[2] = "N", (18.0, 31.0, 12.0)    # latitude ref + value
    gps[3], gps[4] = "E", (73.0, 51.0, 3.0)
    return exif


def test_exif_and_gps_are_stripped():
    raw = _bytes(_img(), exif=_exif_with_gps())
    assert b"SecretCameraMaker" in raw and Image.open(io.BytesIO(raw)).getexif().get_ifd(0x8825)
    [out] = vi.validate_images([_item(raw)])
    clean = Image.open(io.BytesIO(out.jpeg))
    assert not dict(clean.getexif())
    assert not clean.getexif().get_ifd(0x8825)
    assert b"SecretCameraMaker" not in out.jpeg and b"Exif" not in out.jpeg


def test_png_text_chunks_and_comments_are_stripped():
    from PIL import PngImagePlugin
    info = PngImagePlugin.PngInfo()
    info.add_text("Comment", "owner-address-12-MG-Road")
    raw = _bytes(_img(), "PNG", pnginfo=info)
    assert b"owner-address" in raw
    [out] = vi.validate_images([_item(raw)])
    assert b"owner-address" not in out.jpeg


def test_exif_orientation_is_applied_before_stripping():
    exif = Image.Exif()
    exif[0x0112] = 6                       # rotate 90 CW to display
    raw = _bytes(_img(200, 100), exif=exif)
    [out] = vi.validate_images([_item(raw)])
    assert (out.width, out.height) == (100, 200)


def test_trailing_payload_after_the_image_is_dropped():
    raw = _bytes(_img()) + b"<script>alert(1)</script>MALICIOUS-TRAILER"
    [out] = vi.validate_images([_item(raw)])
    assert b"MALICIOUS-TRAILER" not in out.jpeg


# ---------------------------------------------------------------- rejected
def test_wrong_counts():
    assert _reject([]).code == "no_images"
    assert _reject([_item(_bytes(_img(seed=i))) for i in range(6)]).code == "too_many_images"
    assert _reject("nope").code == "invalid_images"
    assert _reject([{"data": "x"}, "str"]).code in ("invalid_image_data", "invalid_images")


@pytest.mark.parametrize("data", ["", None, 123, "not base64!!", "aGVsbG8"])
def test_bad_base64(data):
    e = _reject([{"data": data}])
    assert e.code in ("invalid_image_data", "invalid_image") and e.index == 0


def test_content_decides_the_type_not_the_label():
    e = _reject([_item(b"<html>" + b"x" * 500, "image/jpeg")])
    assert e.code == "invalid_image"
    e = _reject([_item(b"GIF89a" + b"\x00" * 500, "image/gif")])
    assert e.code in ("invalid_image", "unsupported_image_type")


def test_unsupported_real_formats():
    assert _reject([_item(_bytes(_img(), "GIF"))]).code == "unsupported_image_type"
    assert _reject([_item(_bytes(_img(), "BMP"))]).code == "unsupported_image_type"


def test_declared_mime_must_match_the_content():
    e = _reject([_item(_bytes(_img(), "PNG"), "image/jpeg")])
    assert e.code == "mime_mismatch" and e.index == 0


def test_corrupt_and_truncated_images():
    raw = _bytes(_img())
    assert _reject([_item(raw[: len(raw) // 3])]).code == "invalid_image"
    assert _reject([_item(b"\xff\xd8\xff" + b"\x00" * 300)]).code == "invalid_image"
    assert _reject([_item(b"x" * 10)]).code == "invalid_image"


def test_animated_images_rejected():
    frames = [_img(100, 100, seed=i) for i in range(3)]
    out = io.BytesIO()
    frames[0].save(out, "WEBP", save_all=True, append_images=frames[1:], duration=50)
    assert _reject([_item(out.getvalue())]).code == "animated_image"


def test_too_small_image():
    assert _reject([_item(_bytes(_img(32, 32)))]).code == "image_too_small"


def test_oversized_bytes(monkeypatch):
    monkeypatch.setattr(vi, "MAX_IMAGE_BYTES", 2000)
    assert _reject([_item(_bytes(_img(400, 400)))]).code == "image_too_large"


def test_aggregate_size_limit(monkeypatch):
    monkeypatch.setattr(vi, "MAX_TOTAL_BYTES", 12_000)
    items = [_item(_bytes(_img(300, 300, seed=i), quality=85)) for i in range(4)]
    assert sum(len(base64.b64decode(i["data"])) for i in items) > 12_000
    assert _reject(items).code == "images_too_large"


def test_pixel_and_dimension_limits(monkeypatch):
    raw = _bytes(_img(400, 300))
    monkeypatch.setattr(vi, "MAX_PIXELS", 50_000)
    assert _reject([_item(raw)]).code in ("image_dimensions_too_large", "invalid_image")
    monkeypatch.setattr(vi, "MAX_PIXELS", 24_000_000)
    monkeypatch.setattr(vi, "MAX_DIMENSION", 300)
    assert _reject([_item(raw)]).code == "image_dimensions_too_large"


def test_decompression_bomb_is_rejected_without_decoding(monkeypatch):
    """A tiny file declaring huge dimensions must be refused up front."""
    big = Image.new("L", (6000, 6000), 0)           # compresses to a few KB
    raw = _bytes(big, "PNG")
    assert len(raw) < vi.MAX_IMAGE_BYTES
    monkeypatch.setattr(vi, "MAX_PIXELS", 1_000_000)
    assert _reject([_item(raw)]).code in ("image_dimensions_too_large", "invalid_image")


def test_duplicate_photo_rejected():
    raw = _bytes(_img())
    e = _reject([_item(raw), _item(raw)])
    assert e.code == "duplicate_image" and e.index == 1


def test_error_messages_do_not_echo_input():
    e = _reject([{"data": "SECRET-DATA-!!"}])
    assert "SECRET" not in e.message
