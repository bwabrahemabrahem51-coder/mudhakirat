package com.example

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [added] Guard tests (plain JUnit, no Android needed). They protect against the mistakes that are
 * easy to make in this project: shipping an APK with an old copy of the site, or breaking the cache list.
 * Unit tests run with the working directory = app/, so the paths below are relative to that.
 */
class AssetsSyncTest {
    private val assets = File("src/main/assets")
    private val web = File("../web")

    @Test
    fun webAndAppAssets_areIdentical() {
        for (name in listOf("index.html", "sw.js", "manifest.json")) {
            val a = File(assets, name)
            val w = File(web, name)
            assertTrue("$name missing in app assets", a.exists())
            assertTrue("$name missing in web/", w.exists())
            assertEquals("$name differs between web/ and app assets - copy web/ to assets", w.readText(), a.readText())
        }
    }

    @Test
    fun serviceWorkerShellFiles_allExist() {
        val sw = File(assets, "sw.js").readText()
        val block = Regex("const SHELL = \\[(.*?)\\];", RegexOption.DOT_MATCHES_ALL).find(sw)
        assertTrue("SHELL list not found in sw.js", block != null)
        val files = Regex("'([^']+)'").findAll(block!!.groupValues[1]).map { it.groupValues[1] }.toList()
        assertTrue("SHELL list is empty", files.isNotEmpty())
        for (f in files) {
            if (f == "./") continue
            assertTrue("sw.js caches '$f' but the file does not exist (install would fail)", File(assets, f).exists())
        }
    }

    @Test
    fun manifest_iconsExist() {
        val m = File(assets, "manifest.json").readText()
        assertTrue(m.contains("\"start_url\""))
        val srcs = Regex("\"src\"\\s*:\\s*\"([^\"]+)\"").findAll(m).map { it.groupValues[1] }.toList()
        assertTrue(srcs.isNotEmpty())
        for (s in srcs) assertTrue("manifest icon '$s' is missing", File(assets, s).exists())
    }

    @Test
    fun indexHtml_hasContentSecurityPolicy() {
        val html = File(assets, "index.html").readText()
        assertTrue(html.contains("Content-Security-Policy"))
        assertTrue("CSP must allow the Supabase host", html.contains("gojcpksvjhhulvmyzaxf.supabase.co"))
    }

    @Test
    fun mainActivity_handlesRendererCrash() {
        val src = File("src/main/java/com/example/MainActivity.kt").readText()
        assertTrue(src.contains("onRenderProcessGone"))
    }
}
