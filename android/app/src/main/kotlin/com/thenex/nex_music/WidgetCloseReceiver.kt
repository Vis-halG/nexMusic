package com.thenex.nex_music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import com.ryanheise.audioservice.MediaButtonReceiver

/** Closing an idle widget must not start a foreground playback service. */
class WidgetCloseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!NexPhone.sessionActive) return
        context.sendBroadcast(Intent(context, MediaButtonReceiver::class.java).apply {
            action = Intent.ACTION_MEDIA_BUTTON
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_STOP))
        })
    }
}
