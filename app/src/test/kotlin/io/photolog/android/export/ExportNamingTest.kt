package io.photolog.android.export

import io.photolog.android.data.PhotoEntity
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The naming and ordering contract.
 *
 * "按顺序导出图片 + 图片下方文字说明" and "文件名用说明文字" are the two requirements that cannot
 * be checked by looking at the screen: they are about what ends up inside the generated file.
 * These tests pin both down, plus the Chinese-specific failure modes that a device screenshot
 * would never reveal — mojibake inside the ZIP, and a caption truncated in the middle of an
 * emoji.
 */
class ExportNamingTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private fun photo(
        id: Long,
        caption: String = "",
        originalName: String = "IMG_%04d.jpg".format(id),
        mime: String = "image/jpeg",
        sortIndex: Long = id,
        addedAt: Long = id,
        capturedAt: Long = id,
        fileName: String = "g_$id.jpg",
    ) = PhotoEntity(
        id = id,
        caption = caption,
        fileName = fileName,
        originalName = originalName,
        mimeType = mime,
        width = 4000,
        height = 3000,
        sizeBytes = 1024L * id,
        sha256 = "sha$id",
        capturedAt = capturedAt,
        addedAt = addedAt,
        source = "GALLERY",
        sortIndex = sortIndex,
    )

    // --- order and prefix ----------------------------------------------------- //

    @Test
    fun `plan preserves the library order and numbers the files`() {
        val library = listOf(photo(1), photo(2), photo(3))

        val plan = ExportNaming.plan(library, ExportScope.ALL, ExportOptions(numbered = true))

        assertEquals(
            listOf("001_IMG_0001.jpg", "002_IMG_0002.jpg", "003_IMG_0003.jpg"),
            plan.map { it.name },
        )
        assertEquals(listOf(1L, 2L, 3L), plan.map { it.photo.id })
    }

    @Test
    fun `plan can omit the numeric prefix`() {
        val plan = ExportNaming.plan(
            listOf(photo(1), photo(2)),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals(listOf("IMG_0001.jpg", "IMG_0002.jpg"), plan.map { it.name })
    }

    @Test
    fun `recent scope picks the newest but still exports them in library order`() {
        val library = (1L..25L).map { photo(it, addedAt = it, sortIndex = it) }

        val plan = ExportNaming.plan(library, ExportScope.RECENT, ExportOptions())

        // Photos 6..25 are the 20 most recently added.
        assertEquals(20, plan.size)
        assertEquals((6L..25L).toList(), plan.map { it.photo.id })
        // …and they come back out in library order, not in "most recent first" order.
        assertEquals(plan.map { it.photo.sortIndex }.sorted(), plan.map { it.photo.sortIndex })
    }

    @Test
    fun `caption-only scope keeps just the annotated photos`() {
        val library = listOf(
            photo(1, caption = "清晨的雾"),
            photo(2),
            photo(3, caption = "傍晚的云"),
        )

        val plan = ExportNaming.plan(library, ExportScope.WITH_CAPTION, ExportOptions())

        assertEquals(listOf(1L, 3L), plan.map { it.photo.id })
    }

    // --- the caption becomes the file name ------------------------------------ //

    @Test
    fun `a chinese caption becomes the file name`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾"), photo(2, caption = "傍晚的云")),
            ExportScope.ALL,
            ExportOptions(numbered = true),
        )

        assertEquals(listOf("001_清晨的雾.jpg", "002_傍晚的云.jpg"), plan.map { it.name })
    }

    @Test
    fun `full-width punctuation is kept while ascii illegal characters are replaced`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "阳台：第 3 盆｜晴")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("阳台：第 3 盆｜晴.jpg", plan.single().name)
    }

    @Test
    fun `an ascii path separator in a caption cannot create a directory`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "旅行/第一天")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("旅行_第一天.jpg", plan.single().name)
    }

    @Test
    fun `a multi-line caption is flattened onto one line`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "第一行\n第二行\t第三行")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("第一行_第二行_第三行.jpg", plan.single().name)
    }

    @Test
    fun `a long chinese caption is truncated to sixty characters`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "字".repeat(120))),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("字".repeat(60) + ".jpg", plan.single().name)
    }

    @Test
    fun `truncation never splits an emoji`() {
        // 59 CJK characters then an emoji: code unit 60 is the emoji's high surrogate, which
        // `String.take(60)` would cut in half and UTF-8 encoding would turn into a `?`.
        val caption = "字".repeat(59) + "\uD83C\uDF05"

        val plan = ExportNaming.plan(
            listOf(photo(1, caption = caption)),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )
        val base = plan.single().name.removeSuffix(".jpg")

        assertEquals(59, base.length)
        assertTrue("no unpaired surrogate may survive", base.none { it.isHighSurrogate() || it.isLowSurrogate() })
        assertTrue(!base.contains('\uFFFD'))
    }

    @Test
    fun `a blank caption falls back to the original file name`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "   ", originalName = "IMG_0001.jpg")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("IMG_0001.jpg", plan.single().name)
    }

    @Test
    fun `a photo with no original name falls back to the generated one`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, originalName = "", fileName = "g_20261012_093155_456.jpg")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("g_20261012_093155_456.jpg", plan.single().name)
    }

    @Test
    fun `two photos sharing a caption get distinct names`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "随手拍"), photo(2, caption = "随手拍")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals(listOf("随手拍.jpg", "随手拍_2.jpg"), plan.map { it.name })
    }

    @Test
    fun `naming can fall back to the original file name`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾", originalName = "IMG_0001.jpg")),
            ExportScope.ALL,
            ExportOptions(numbered = false, useCaptionAsName = false),
        )

        assertEquals("IMG_0001.jpg", plan.single().name)
    }

    @Test
    fun `a windows device name is escaped`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "CON")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )

        assertEquals("_CON.jpg", plan.single().name)
    }

    @Test
    fun `lossless keeps the original extension and lossy forces jpeg`() {
        val png = listOf(photo(1, originalName = "shot.png", mime = "image/png"))

        val lossless = ExportNaming.plan(png, ExportScope.ALL, ExportOptions(lossless = true))
        val lossy = ExportNaming.plan(png, ExportScope.ALL, ExportOptions(lossless = false))

        assertEquals("001_shot.png", lossless.single().name)
        assertEquals("image/png", lossless.single().mimeType)
        assertEquals("001_shot.jpg", lossy.single().name)
        assertEquals("image/jpeg", lossy.single().mimeType)
    }

    @Test
    fun `a chinese caption does not change the extension, which still comes from the bytes`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "截图.png", mime = "image/jpeg")),
            ExportScope.ALL,
            ExportOptions(numbered = false, lossless = true),
        )

        assertEquals("截图.png.jpg", plan.single().name)
        assertEquals("image/jpeg", plan.single().mimeType)
    }

    // --- the document --------------------------------------------------------- //

    @Test
    fun `markdown puts each caption directly under its own image, in order`() {
        val library = listOf(
            photo(1, caption = "第一张：清晨的雾"),
            photo(2, caption = "第二张：傍晚的云"),
        )
        val plan = ExportNaming.plan(library, ExportScope.ALL, ExportOptions())

        val document = CaptionDocument.build(plan, ExportOptions(), exportedAt = 0L)

        val first = document.indexOf("![001](images/${plan[0].name})")
        val firstCaption = document.indexOf("第一张：清晨的雾")
        val second = document.indexOf("![002](images/${plan[1].name})")
        val secondCaption = document.indexOf("第二张：傍晚的云")

        assertTrue("first image must appear", first >= 0)
        assertTrue("first caption must follow its own image", firstCaption > first)
        assertTrue("second image must follow the first caption", second > firstCaption)
        assertTrue("second caption must follow its own image", secondCaption > second)
    }

    @Test
    fun `the image path in the document matches the exported file name`() {
        val plan = ExportNaming.plan(
            listOf(photo(7, caption = "清晨的雾")),
            ExportScope.ALL,
            ExportOptions(numbered = true),
        )

        val document = CaptionDocument.build(plan, ExportOptions(), exportedAt = 0L)

        assertEquals("001_清晨的雾.jpg", plan.single().name)
        assertTrue(document.contains("![001](images/001_清晨的雾.jpg)"))
    }

    @Test
    fun `html wraps every image and caption in a figure`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "甲"), photo(2, caption = "乙")),
            ExportScope.ALL,
            ExportOptions(),
        )

        val html = CaptionDocument.build(
            plan,
            ExportOptions(captionFormat = CaptionFormat.HTML),
            exportedAt = 0L,
        )

        assertEquals(2, Regex("<figure>").findAll(html).count())
        assertEquals(2, Regex("<figcaption>").findAll(html).count())
        assertTrue(html.contains("images/${plan[0].name}"))
        assertTrue(html.contains("images/${plan[1].name}"))
    }

    @Test
    fun `html escapes text that would otherwise break the page`() {
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "<script>alert(1)</script> & \"quoted\"")),
            ExportScope.ALL,
            ExportOptions(),
        )

        val html = CaptionDocument.build(
            plan,
            ExportOptions(captionFormat = CaptionFormat.HTML),
            exportedAt = 0L,
        )

        assertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        assertTrue(html.contains("&amp;"))
        assertTrue(html.contains("&quot;quoted&quot;"))
        assertTrue(!html.contains("<script>"))
    }

    @Test
    fun `a photo with no caption is marked rather than left blank`() {
        val plan = ExportNaming.plan(listOf(photo(1)), ExportScope.ALL, ExportOptions())

        val markdown = CaptionDocument.build(plan, ExportOptions(), exportedAt = 0L)
        val text = CaptionDocument.build(
            plan,
            ExportOptions(captionFormat = CaptionFormat.TEXT),
            exportedAt = 0L,
        )

        assertTrue(markdown.contains("（无说明）"))
        assertTrue(text.contains("（无说明）"))
    }

    @Test
    fun `the document records whether the export was lossless`() {
        val plan = ExportNaming.plan(listOf(photo(1)), ExportScope.ALL, ExportOptions(lossless = true))

        val lossless = CaptionDocument.build(plan, ExportOptions(lossless = true), exportedAt = 0L)
        val lossy = CaptionDocument.build(
            plan,
            ExportOptions(lossless = false, jpegQuality = 90),
            exportedAt = 0L,
        )

        assertTrue(lossless.contains("无损"))
        assertTrue(lossy.contains("质量 90"))
    }

    @Test
    fun `the plain text document starts with a utf-8 bom`() {
        val plan = ExportNaming.plan(listOf(photo(1, caption = "清晨的雾")), ExportScope.ALL, ExportOptions())

        val bytes = CaptionDocument.build(
            plan,
            ExportOptions(captionFormat = CaptionFormat.TEXT),
            exportedAt = 0L,
        ).toByteArray(Charsets.UTF_8)

        assertArrayEquals(
            byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()),
            bytes.copyOfRange(0, 3),
        )
        assertTrue(String(bytes, Charsets.UTF_8).contains("清晨的雾"))
    }

    @Test
    fun `markdown and html declare their encoding instead of carrying a bom`() {
        val plan = ExportNaming.plan(listOf(photo(1, caption = "清晨的雾")), ExportScope.ALL, ExportOptions())

        val markdown = CaptionDocument.build(plan, ExportOptions(captionFormat = CaptionFormat.MARKDOWN), 0L)
        val html = CaptionDocument.build(plan, ExportOptions(captionFormat = CaptionFormat.HTML), 0L)

        assertTrue(markdown.startsWith("#"))
        assertTrue(html.startsWith("<!DOCTYPE html>"))
        assertTrue(html.contains("<meta charset=\"utf-8\">"))
    }

    // --- the archive ---------------------------------------------------------- //

    @Test
    fun `zip keeps chinese entry names readable and copies the image bytes untouched`() {
        val original = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x11, 0x22, 0x33)
        val source = temporaryFolder.newFile("g_1.jpg").apply { writeBytes(original) }
        val options = ExportOptions(numbered = true, lossless = true)

        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾", fileName = source.name)),
            ExportScope.ALL,
            options,
        )
        val buffer = ByteArrayOutputStream()

        val result = ArchiveWriter.writeZip(plan, buffer, options, { source }, {})

        assertEquals(ExportResult.Success(1, 0, 1), result)

        ZipInputStream(ByteArrayInputStream(buffer.toByteArray())).use { zip ->
            val image = zip.nextEntry
            assertEquals("images/001_清晨的雾.jpg", image.name)
            assertArrayEquals("lossless must be a byte-for-byte copy", original, zip.readBytes())

            val captions = zip.nextEntry
            assertEquals("captions.md", captions.name)
            val document = String(zip.readBytes(), Charsets.UTF_8)
            assertTrue(document.contains("清晨的雾"))
            assertTrue(document.contains("images/001_清晨的雾.jpg"))
        }
    }

    @Test
    fun `zip entry names are flagged as utf-8`() {
        val source = temporaryFolder.newFile("g_1.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val options = ExportOptions(numbered = true)

        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾", fileName = source.name)),
            ExportScope.ALL,
            options,
        )
        val buffer = ByteArrayOutputStream()
        ArchiveWriter.writeZip(plan, buffer, options, { source }, {})

        // Local file header: signature(4) version(2) flags(2) …; EFS (bit 11) is what tells a
        // Windows extractor to read the name as UTF-8 rather than the system code page.
        val raw = buffer.toByteArray()
        val flags = (raw[6].toInt() and 0xFF) or ((raw[7].toInt() and 0xFF) shl 8)
        assertEquals("UTF-8 name flag must be set", 0x0800, flags and 0x0800)
    }

    @Test
    fun `zip skips a photo whose original file is gone`() {
        val present = temporaryFolder.newFile("g_1.jpg").apply { writeBytes(byteArrayOf(1)) }
        val missing = temporaryFolder.newFile("g_2.jpg")
        missing.delete()

        val plan = ExportNaming.plan(
            listOf(
                photo(1, caption = "在的", fileName = present.name),
                photo(2, caption = "没的", fileName = missing.name),
            ),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        )
        val buffer = ByteArrayOutputStream()

        val result = ArchiveWriter.writeZip(plan, buffer, ExportOptions(numbered = false), { entity ->
            if (entity.fileName == present.name) present else missing
        }, {})

        assertEquals(ExportResult.Success(1, 1, 2), result)
    }

    @Test
    fun `the zip can leave the captions document out`() {
        val source = temporaryFolder.newFile("g_1.jpg").apply { writeBytes(byteArrayOf(1)) }
        val options = ExportOptions(numbered = false, includeCaptions = false)
        val plan = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾", fileName = source.name)),
            ExportScope.ALL,
            options,
        )
        val buffer = ByteArrayOutputStream()

        ArchiveWriter.writeZip(plan, buffer, options, { source }, {})

        ZipInputStream(ByteArrayInputStream(buffer.toByteArray())).use { zip ->
            assertEquals("images/清晨的雾.jpg", zip.nextEntry.name)
            assertTrue("no captions file expected", zip.nextEntry == null)
        }
    }

    @Test
    fun `the caption source name is not the same as the fallback name`() {
        val withCaption = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾")),
            ExportScope.ALL,
            ExportOptions(numbered = false),
        ).single().name
        val without = ExportNaming.plan(
            listOf(photo(1, caption = "清晨的雾")),
            ExportScope.ALL,
            ExportOptions(numbered = false, useCaptionAsName = false),
        ).single().name

        assertNotEquals(withCaption, without)
    }
}
