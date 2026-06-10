"""Image preprocessing utilities for the processing pipeline."""

import io

from PIL import Image

MAX_DIMENSION = 2048


def resize_for_vision(image_bytes: bytes) -> bytes:
    """Resize image to fit within MAX_DIMENSION on longest side.

    Returns the original bytes if already within limits.
    Re-encodes as PNG to maintain lossless quality.
    """
    img = Image.open(io.BytesIO(image_bytes))
    width, height = img.size

    if width <= MAX_DIMENSION and height <= MAX_DIMENSION:
        return image_bytes

    # Calculate new dimensions preserving aspect ratio
    if width > height:
        new_width = MAX_DIMENSION
        new_height = int(height * (MAX_DIMENSION / width))
    else:
        new_height = MAX_DIMENSION
        new_width = int(width * (MAX_DIMENSION / height))

    img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)

    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    return buffer.getvalue()
