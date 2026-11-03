package com.example

import android.app.NotificationChannel
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Posts a notification even when the activity is not running (used by the alarm receiver). */
object Notifier {
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MainActivity.CHANNEL_ID,
                "تنبيهات مذاكرتي",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "إشعارات انتهاء وقت المذاكرة والتذكير اليومي"
                enableVibration(true)
                vibrationPattern = longArrayOf(100, 200, 100, 200)
            }
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private const val QUIET_CHANNEL = "mudhakirati_newday_v2"
    private const val OLD_QUIET_CHANNEL = "mudhakirati_newday"

    /** "New day" notification (soft priority, but with the default notification sound). */
    fun showQuiet(context: Context, title: String, body: String, tag: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(QUIET_CHANNEL, "يوم جديد", NotificationManager.IMPORTANCE_DEFAULT)
                ch.description = "إشعار عند بداية كل يوم جديد"
                ch.setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                val nm = context.getSystemService(NotificationManager::class.java)
                nm?.deleteNotificationChannel(OLD_QUIET_CHANNEL)
                nm?.createNotificationChannel(ch)
            }
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pi = PendingIntent.getActivity(
                context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val n = NotificationCompat.Builder(context, QUIET_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setDefaults(NotificationCompat.DEFAULT_SOUND)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
            NotificationManagerCompat.from(context).notify(tag.hashCode(), n)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    fun show(context: Context, title: String, body: String, tag: String) {
        try {
            ensureChannel(context)
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pi = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val n = NotificationCompat.Builder(context, MainActivity.CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
            NotificationManagerCompat.from(context).notify(tag.hashCode(), n)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
