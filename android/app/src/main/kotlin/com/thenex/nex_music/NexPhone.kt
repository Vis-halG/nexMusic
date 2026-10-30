package com.thenex.nex_music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.KeyEvent
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Notifications and launch actions shared by the activity and the widgets. */
object NexPhone {
    private const val ACTION_EXTRA = "nexmusic_action"
    private const val ACTIVITY_CHANNEL = "activity"
    private const val TRANSFERS_CHANNEL = "transfers"
    private const val ACCENT = 0xFF7C3AED.toInt()

    /**
     * True while this process has a song loaded, so the Now playing widget can
     * send media buttons instead of opening the app.
     */
    @Volatile
    var sessionActive = false

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        // The activity channel id must match push_worker/worker.js.
        manager.createNotificationChannel(
            NotificationChannel(ACTIVITY_CHANNEL, "Activity", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Uploads, edits and deletions by other people"
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(TRANSFERS_CHANNEL, "Uploads and downloads", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of your uploads and offline downloads"
            },
        )
    }

    fun launchAction(intent: Intent?): String? = intent?.getStringExtra(ACTION_EXTRA)
        ?: intent?.data?.takeIf { (it.scheme == "nexmusic" && it.host == "share") || (it.scheme == "https" && it.host == "nexmusic-push.vishalgupta25989.workers.dev" && it.path?.startsWith("/share/") == true) }?.let { "link:$it" }

    /** Opens nexMusic and, when [action] is set, runs it (e.g. `play:<id>`). */
    fun openAppIntent(context: Context, action: String?, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (action != null) {
                putExtra(ACTION_EXTRA, action)
                // Extras alone do not make two PendingIntents different.
                data = Uri.parse("nexmusic://open/${Uri.encode(action)}")
            }
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** A loaded session receives controls without bringing the activity forward. */
    fun playerControlIntent(context: Context, action: String, requestCode: Int): PendingIntent {
        if (action == "stop") {
            return PendingIntent.getBroadcast(context, requestCode,
                Intent(context, WidgetCloseReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        if (!sessionActive) return openAppIntent(context, action, requestCode)
        val keyCode = when (action) {
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        }
        val intent = Intent(context, com.ryanheise.audioservice.MediaButtonReceiver::class.java).apply {
            this.action = Intent.ACTION_MEDIA_BUTTON
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        return PendingIntent.getBroadcast(context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setTransferActive" -> TransferService.setActive(
                context, call.argument<String>("owner") ?: "transfer",
                call.argument<Boolean>("active") == true,
            )
            "openBatterySettings" -> {
                context.startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            "showProgress" -> notify(context, call, TRANSFERS_CHANNEL, ongoing = true)
            "showDone" -> notify(context, call, TRANSFERS_CHANNEL, ongoing = false)
            "showActivity" -> notify(context, call, ACTIVITY_CHANNEL, ongoing = false)
            "cancel" -> manager(context).cancel(call.argument<Int>("id") ?: 0)
            "updateWidgets" -> {
                MusicWidget.save(context,call.argument<String>("data") ?: "{}")
            }
            "setSessionActive" -> {
                val active = call.argument<Boolean>("active") == true
                if (sessionActive != active) {
                    sessionActive = active
                    MusicWidget.refresh(context)
                }
            }
            "releaseUri" -> releaseUri(context, call.argument<String>("uri"))
            "readMediaArtist" -> {
                val filePath = call.argument<String>("path") ?: ""
                artistReader.execute {
                    val reader = MediaMetadataRetriever()
                    val artist = try {
                        reader.setDataSource(filePath)
                        reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)?.trim() ?: ""
                    } catch (_: Exception) {
                        ""
                    } finally {
                        try { reader.release() } catch (_: Exception) { }
                    }
                    mainThread.post { result.success(artist) }
                }
                return
            }
            "copyToCache" -> {
                copyInBackground(context, call.argument<String>("uri"), call.argument<String>("name"), result)
                return
            }
            "copyAudioToCache" -> {
                copyInBackground(context, call.argument<String>("uri"), null, result, resolveName = true)
                return
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("INVALID_PATH", "APK path is empty", null)
                    return
                }
                try {
                    val file = File(path)
                    val authority = "${context.packageName}.fileprovider"
                    val contentUri = androidx.core.content.FileProvider.getUriForFile(context, authority, file)
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(contentUri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_ERROR", e.localizedMessage, null)
                }
                return
            }
            "openUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("INVALID_URL", "URL is empty", null)
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_URL_ERROR", e.localizedMessage, null)
                }
                return
            }
            "getAppVersion" -> {
                try {
                    val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
                    } else {
                        @Suppress("DEPRECATION")
                        context.packageManager.getPackageInfo(context.packageName, 0)
                    }
                    val versionName = packageInfo.versionName ?: ""
                    val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        packageInfo.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        packageInfo.versionCode.toLong()
                    }
                    result.success(mapOf(
                        "versionName" to versionName,
                        "buildNumber" to versionCode,
                        "version" to if (versionCode > 0) "$versionName+$versionCode" else versionName
                    ))
                } catch (e: Exception) {
                    result.error("VERSION_ERROR", e.localizedMessage, null)
                }
                return
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        result.success(null)
    }

    private val mainThread = Handler(Looper.getMainLooper())
    private val artistReader = Executors.newFixedThreadPool(3)

    /**
     * Name, size and URI of a chosen file. Keeps read access so the file can
     * still be uploaded later in the batch, or retried.
     */
    fun describe(context: Context, uri: Uri): Map<String, Any?> {
        try {
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (error: SecurityException) {
            // Some providers only grant access while the app is open.
        }
        var name: String? = null
        var size = -1L
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        return mapOf("uri" to uri.toString(), "name" to (name ?: uri.lastPathSegment ?: "file"), "size" to size)
    }

    /** Copies one chosen file into the cache right before it uploads. */
    private fun copyInBackground(context: Context, uri: String?, name: String?, result: MethodChannel.Result, resolveName: Boolean = false) {
        if (uri == null) {
            result.error("NO_URI", "No file was given.", null)
            return
        }
        Thread {
            try {
                var actualName = if (resolveName) describe(context, Uri.parse(uri))["name"] as? String else name
                if (resolveName && File(actualName ?: "").extension.isEmpty()) {
                    val mime = context.contentResolver.getType(Uri.parse(uri))
                    val extension = mime?.let { android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
                    if (!extension.isNullOrEmpty()) actualName = "${actualName ?: "song"}.$extension"
                }
                val safeName = (actualName ?: "upload").replace(Regex("[\\\\/:*?\"<>|]"), " ").trim().ifEmpty { "upload" }
                val folder = File(context.cacheDir, "nexmusic_uploads/${System.nanoTime()}").apply { mkdirs() }
                val target = File(folder, safeName)
                val input = context.contentResolver.openInputStream(Uri.parse(uri))
                    ?: error("The file could not be opened.")
                input.use { source -> FileOutputStream(target).use { source.copyTo(it, 256 * 1024) } }
                mainThread.post { result.success(target.absolutePath) }
            } catch (error: Exception) {
                mainThread.post { result.error("COPY_FAILED", error.message ?: "The file could not be read.", null) }
            }
        }.start()
    }

    private fun releaseUri(context: Context, uri: String?) {
        if (uri == null) return
        try {
            context.contentResolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (error: SecurityException) {
            // Access was only temporary.
        }
    }

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            Notification.Builder(context)
        }

    private fun notify(context: Context, call: MethodCall, channel: String, ongoing: Boolean) {
        val id = call.argument<Int>("id") ?: return
        val percent = call.argument<Int>("percent") ?: -1
        val notification = builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ACCENT)
            .setContentTitle(call.argument<String>("title"))
            .setContentText(call.argument<String>("text"))
            .setContentIntent(openAppIntent(context, null, 0))
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true)
        if (ongoing) notification.setProgress(100, percent.coerceIn(0, 100), percent < 0)
        try {
            manager(context).notify(id, notification.build())
        } catch (error: SecurityException) {
            // Notifications are turned off for nexMusic.
        }
    }
}
