package io.photolog.android.data

/**
 * MIME-type helpers, kept in one place.
 *
 * Both the import path and the export path need to answer the same two questions — "what is
 * this file, really?" and "what extension does that mean?" — and answering them differently in
 * the two places is how a lossless export ends up named `.jpg` while containing PNG bytes.
 */

/**
 * The extension to store or export under.
 *
 * Unknown types deliberately fall back to `bin` rather than `jpg`: a wrong extension makes a
 * viewer guess wrong, while an honest `bin` at least survives a round trip back through this
 * app. Only formats that Android can decode are mapped to something else.
 */
fun extensionForMime(mime: String): String = when (mime.trim().lowercase()) {
    "image/jpeg", "image/jpg", "image/pjpeg" -> "jpg"
    "image/png" -> "png"
    "image/webp" -> "webp"
    "image/gif" -> "gif"
    "image/bmp", "image/x-ms-bmp" -> "bmp"
    "image/heic", "image/heif", "image/heic-sequence" -> "heic"
    "image/avif" -> "avif"
    "image/tiff" -> "tiff"
    else -> "bin"
}

/**
 * The best available answer for "what type is this?".
 *
 * Three sources, in decreasing order of trust:
 *
 * 1. `sniffed` — what `BitmapFactory` reported while decoding the header. It read the actual
 *    bytes, so it cannot be wrong about the format.
 * 2. `declared` — the ContentResolver's type. Trustworthy unless it is the wildcard, which
 *    providers hand out when they genuinely do not know.
 * 3. `name` — the display name's extension. A guess, but a much better one than a default.
 *
 * The order matters: a file manager that labels a PNG as `image/jpeg` because of its name is
 * common enough that trusting the declaration over the bytes would mislabel real files.
 */
fun resolveMime(declared: String?, sniffed: String?, name: String?): String {
    if (!sniffed.isNullOrBlank() && sniffed != "image/*") return sniffed
    if (!declared.isNullOrBlank() && declared != "image/*" && declared != "*/*") return declared

    val extension = name?.substringAfterLast('.', "")?.lowercase().orEmpty()
    val fromName = when (extension) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "bmp" -> "image/bmp"
        "heic", "heif" -> "image/heic"
        "avif" -> "image/avif"
        "tif", "tiff" -> "image/tiff"
        else -> null
    }
    return fromName ?: declared ?: "image/jpeg"
}

/** The display name's extension, when it looks like a usable one. */
fun extensionFromName(name: String?): String? {
    val extension = name?.substringAfterLast('.', "")?.lowercase().orEmpty()
    return if (extension.length in 2..5 && extension.all { it.isLetterOrDigit() }) extension else null
}
