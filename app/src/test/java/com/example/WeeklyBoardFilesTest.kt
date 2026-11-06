package com.example

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the public weekly ranking: SQL and page use the same RPC names, and the board never returns the friend code. */
class WeeklyBoardFilesTest {
    private val sql = File("../supabase/weekly-board-setup.sql").readText()
    private val html = File("src/main/assets/index.html").readText()

    @Test
    fun weeklyBoard_sqlAndPageAgree() {
        for (fn in listOf("sync_points", "set_board", "get_global_board", "report_board_user")) {
            assertTrue("$fn missing in SQL", sql.contains("function public.$fn"))
            assertTrue("$fn not called by index.html", html.contains("'$fn'"))
        }
    }

    @Test
    fun globalBoard_neverReturnsFriendCode() {
        val body = sql.substringAfter("function public.get_global_board").substringBefore("report_board_user")
        assertFalse("board must not expose p.code", Regex("p\\.code|'code'").containsMatchIn(body))
    }
}
