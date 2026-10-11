package com.thenex.nex_music

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.widget.RemoteViews

/** The library widget keeps its existing shortcuts and follows the app theme. */
class MusicWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        render(context, manager, id)
    }

    companion object {
        fun save(context: Context, data: String) {
            context.getSharedPreferences("nex_widgets", Context.MODE_PRIVATE)
                .edit().putString("data", data).apply()
            refresh(context)
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for (id in manager.getAppWidgetIds(ComponentName(context, MusicWidget::class.java))) {
                render(context, manager, id)
            }
            for (id in manager.getAppWidgetIds(ComponentName(context, PlayerWidget::class.java))) {
                PlayerWidget.render(context, manager, id)
            }
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val state = PlayerWidgetState(context)
            val view = RemoteViews(context.packageName, R.layout.music_widget)
            state.bind(context, view, id)
            val picks = listOf("liked", "recent", "latest")
                .firstNotNullOfOrNull { state.data.optJSONArray(it)?.takeIf { rows -> rows.length() > 0 } }
            val titleIds = intArrayOf(R.id.widget_song1, R.id.widget_song2, R.id.widget_song3)
            for (i in titleIds.indices) {
                val song = picks?.optJSONObject(i)
                view.setTextViewText(titleIds[i], song?.optString("title") ?: "Open library")
                view.setTextColor(titleIds[i], state.foreground)
                view.setOnClickPendingIntent(titleIds[i], NexPhone.openAppIntent(
                    context, song?.optString("id")?.let { "play:$it" } ?: "downloads", id * 10 + 4 + i,
                ))
            }
            manager.updateAppWidget(id, view)
        }
    }
}
