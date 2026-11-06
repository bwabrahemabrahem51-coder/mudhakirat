package com.example

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** [added] Guards for the account-deletion / report / privacy additions. */
class ModerationFilesTest {
    private val web = File("../web")
    private val sql = File("../supabase/moderation-setup.sql")

    @Test
    fun sql_definesDeleteAndReportFunctions() {
        val s = sql.readText()
        assertTrue(s.contains("function public.delete_my_account"))
        assertTrue(s.contains("function public.report_user"))
        assertTrue("report/delete must not be callable by anon", s.contains("from public, anon"))
    }

    @Test
    fun privacyPage_exists() {
        val f = File(web, "privacy.html")
        assertTrue(f.exists())
        assertTrue(f.readText().contains("@okkj0"))
    }

    @Test
    fun index_callsTheNewFunctions_inBothCopies() {
        for (f in listOf(File(web, "index.html"), File("src/main/assets/index.html"))) {
            val h = f.readText()
            assertTrue(h.contains("delete_my_account"))
            assertTrue(h.contains("report_user"))
        }
    }
}
