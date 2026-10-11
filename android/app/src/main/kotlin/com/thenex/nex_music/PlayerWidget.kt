package com.thenex.nex_music

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Bundle
import android.widget.RemoteViews
import org.json.JSONObject

/** A compact player whose control hit areas expand with the widget width. */
class PlayerWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        render(context, manager, id)
    }

    companion object {
        fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val view = RemoteViews(context.packageName, R.layout.player_widget)
            PlayerWidgetState(context).bind(context, view, id, pill = true)
            manager.updateAppWidget(id, view)
        }
    }
}

/** Both widget providers use the same persisted theme and playback snapshot. */
internal class PlayerWidgetState(context: Context) {
    val data = try {
        JSONObject(context.getSharedPreferences("nex_widgets", Context.MODE_PRIVATE).getString("data", "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }
    private val dark = data.optBoolean("darkMode", false)
    val foreground = Color.parseColor(if (dark) "#FAFAFA" else "#0A0A0A")
    private val muted = Color.parseColor(if (dark) "#A1A1AA" else "#71717A")

    fun bind(context: Context, view: RemoteViews, id: Int, pill: Boolean = false) {
        val current = data.optJSONObject("now")
        val playing = NexPhone.sessionActive && current?.optBoolean("playing") == true
        val background = when {
            pill && dark -> R.drawable.player_widget_bg_dark
            pill -> R.drawable.player_widget_bg_light
            dark -> R.drawable.music_widget_bg
            else -> R.drawable.music_widget_bg_light
        }
        view.setInt(R.id.widget_root, "setBackgroundResource", background)
        view.setTextViewText(R.id.widget_title, current?.optString("title") ?: "nexMusic")
        view.setTextViewText(R.id.widget_artist, current?.optString("subtitle") ?: "Tap to choose music")
        view.setTextColor(R.id.widget_title, foreground)
        view.setTextColor(R.id.widget_artist, muted)
        view.setOnClickPendingIntent(R.id.widget_title, NexPhone.openAppIntent(context, "player", id * 10))
        view.setOnClickPendingIntent(R.id.widget_artist, NexPhone.openAppIntent(context, "player", id * 10))
        val buttons = listOf(
            Triple(R.id.widget_previous, R.drawable.ic_widget_previous, "previous"),
            Triple(R.id.widget_toggle, if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play, "toggle"),
            Triple(R.id.widget_next, R.drawable.ic_widget_next, "next"),
            Triple(R.id.widget_close, R.drawable.ic_widget_close, "stop"),
        )
        for ((index, button) in buttons.withIndex()) {
            val (viewId, drawableId, action) = button
            view.setImageViewIcon(viewId, Icon.createWithResource(context, drawableId).setTint(foreground))
            view.setOnClickPendingIntent(viewId, NexPhone.playerControlIntent(context, action, id * 10 + 1 + index))
        }
        view.setContentDescription(R.id.widget_toggle, if (playing) "Pause" else "Play")
    }
}
