package com.example

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards groups/rooms/challenges: SQL and page use the same RPC names, and nothing returns the friend code of a stranger. */
class GroupsFilesTest {
    private val sql = File("../supabase/groups-setup.sql").readText()
    private val html = File("src/main/assets/index.html").readText()

    @Test
    fun groups_sqlAndPageAgree() {
        val fns = listOf(
            "create_group", "join_group", "add_to_group", "leave_group", "delete_group", "kick_member", "set_group_code",
            "get_my_groups", "get_group", "create_room", "join_room", "invite_to_room", "leave_room", "room_state", "get_room",
            "send_gmsg", "get_gmsgs", "report_group_member", "get_group_reports", "resolve_group_report",
            "send_challenge", "respond_challenge", "get_challenges",
            "block_group_member", "get_group_board", "rename_group", "set_member_role"
        )
        for (fn in fns) {
            assertTrue("$fn missing in SQL", sql.contains("function public.$fn"))
            assertTrue("$fn not called by index.html", html.contains("'$fn'"))
        }
    }

    @Test
    fun groups_neverExposeCodesOrUids() {
        for (fn in listOf("get_group", "get_room", "get_gmsgs", "get_my_groups")) {
            val body = sql.substringAfter("function public.$fn(").substringBefore("\$\$;")
            assertFalse("$fn must not return p.code", Regex("p\\.code").containsMatchIn(body))
            assertFalse("$fn must not return a raw uid", Regex("'uid'").containsMatchIn(body))
        }
    }

    @Test
    fun messageQuota_is30() {
        assertTrue(sql.contains("n < 30"))
    }
}
